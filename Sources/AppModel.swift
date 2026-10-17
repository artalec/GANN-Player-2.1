import Foundation
import SwiftUI
import Combine
import AppKit

/// Единая модель приложения: состояние (плейлисты, настройки), аудиодвижок и выделение.
final class AppModel: ObservableObject {

    static let shared = AppModel()

    @Published var state: AppState
    @Published var selectedPlaylistID: UUID?

    /// Текущее перетаскивание внутри приложения (треки или плейлист).
    @Published var draggingTrackIDs: [UUID] = []
    @Published var draggingPlaylistID: UUID?

    /// Куда сейчас наведён перетаскиваемый элемент — для индикатора вставки.
    /// Для треков: ID строки и сторона (true = линия над строкой).
    @Published var trackDropTarget: (id: UUID, before: Bool)?
    /// Для плейлистов: ID строки, над которой стоит курсор.
    @Published var playlistDropTargetID: UUID?

    /// Показан ли список плейлистов слева.
    @Published var isSidebarVisible = true

    /// Треки, файлы которых исчезли с диска. Обновляется в фоне, чтобы в списке
    /// вместо ноты показывался значок предупреждения.
    @Published private(set) var missingTrackIDs: Set<UUID> = []

    /// Таймер наблюдения за отпусканием кнопки мыши (см. beginDragWatch).
    private var dragWatchTimer: Timer?

    /// Таймер проверки наличия файлов треков.
    private var fileCheckTimer: Timer?

    /// Единая точка сброса состояния перетаскивания. Вызывается после любого
    /// завершения перетаскивания (успешного, отменённого или мимо списка), чтобы
    /// синяя линия не оставалась на экране.
    func endDragging() {
        trackDropTarget = nil
        playlistDropTargetID = nil
        draggingTrackIDs = []
        draggingPlaylistID = nil
    }

    /// Наблюдение за перетаскиванием. Во время системного drag-сеанса локальные
    /// мониторы NSEvent не получают отпускание мыши, поэтому опрашиваем реальное
    /// состояние кнопок. Как только кнопка отпущена, линия гаснет — куда бы
    /// ни бросили элемент: в список, мимо него или на себя.
    func beginDragWatch() {
        guard dragWatchTimer == nil else { return }

        // Важно: во время перетаскивания run loop работает в режиме
        // eventTracking. Таймер, созданный в обычном режиме, там не срабатывает,
        // поэтому добавляем его в общие режимы.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkDragReleased()
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatchTimer = timer
    }

    private func checkDragReleased() {
        // Кнопка ещё нажата — перетаскивание идёт.
        if NSEvent.pressedMouseButtons & 1 != 0 { return }

        // Кнопка отпущена: гасим линию сразу, не дожидаясь performDrop.
        // Если он придёт следом, список просто перестроится уже без неё.
        dragWatchTimer?.invalidate()
        dragWatchTimer = nil
        endDragging()
    }

    /// Пики波形 для трека, показанного на waveform (даже если он не играет).
    @Published var displayedWaveform: [Float] = []

    /// Стартовая позиция для трека, выбранного, но ещё не играющего: точка,
    /// отмеченная на waveform. Применяется при запуске этого трека.
    @Published var pendingStartPositions: [UUID: TimeInterval] = [:]

    /// Focus Fade поставил воспроизведение на паузу автоматически. Нужно, чтобы
    /// при возвращении возобновить только эту паузу и не тронуть ручную.
    private var focusFadeDidPause = false

    /// Пики по ID трека. Единственный источник истины для waveform: пики из
    /// аудиодвижка сюда больше не подмешиваются, иначе при быстром переключении
    /// треков на графике оказывался waveform предыдущего.
    private var waveformCache: [UUID: [Float]] = [:]
    /// Для какого трека сейчас показаны пики. Позволяет не сравнивать массивы на каждом шаге.
    private var displayedWaveformOwner: UUID?
    /// Длительности, полученные вместе с пиками — файл повторно не читается.
    private var durationCache: [UUID: TimeInterval] = [:]
    /// Идёт ли сейчас расчёт пиков для трека.
    private var waveformLoading: Set<UUID> = []
    /// ID последнего запроса: по нему отсекаются устаревшие результаты.
    private var waveformRequestID = UUID()

    let audioEngine = AudioEngine()
    let selection = SelectionManager()

    private let storage = StorageManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var autosaveWorkItem: DispatchWorkItem?
    
    /// Подавляет автопереход, когда трек остановлен пользователем вручную.
    private init() {
        let loaded = storage.load()
        self.state = loaded
        self.selectedPlaylistID = loaded.selectedPlaylistID ?? loaded.playlists.first?.id

        audioEngine.settings = loaded.settings

        audioEngine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        selection.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        $state
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAutosave() }
            .store(in: &cancellables)

        $selectedPlaylistID
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAutosave() }
            .store(in: &cancellables)

        audioEngine.applyVolume()

        audioEngine.onTrackFinished = { [weak self] in
            self?.handleTrackFinished()
        }

        // Waveform должен показываться и для выделенного, но не играющего трека,
        // поэтому перезагружаем пики при смене выделения и плейлиста.
        selection.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshDisplayedWaveform() }
            }
            .store(in: &cancellables)

        $selectedPlaylistID
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshDisplayedWaveform() }
            }
            .store(in: &cancellables)

        // Раньше подписка шла на objectWillChange движка, который срабатывает
        // 20 раз в секунду (currentTime меняется каждый тик). Теперь реагируем
        // только на смену текущего трека.
        audioEngine.$currentTrack
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshDisplayedWaveform() }
            }
            .store(in: &cancellables)

        // Focus Fade: уход в другую программу и возвращение к плееру.
        NotificationCenter.default
            .publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.handleAppDidResignActive() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.handleAppDidBecomeActive() }
            .store(in: &cancellables)

        // Файлы треков могут исчезнуть из Finder в любой момент. Проверяем их
        // при запуске и далее по таймеру, чтобы значок в списке не устаревал.
        refreshMissingTracks()
        fileCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshMissingTracks()
        }
    }

    // MARK: - Проверка наличия файлов

    /// Сверяет треки с диском. Сама проверка идёт в фоне, результат
    /// применяется только при изменениях — иначе список перерисовывался бы зря.
    func refreshMissingTracks() {
        var paths: [(UUID, String)] = []
        for playlist in state.playlists {
            for track in playlist.tracks {
                paths.append((track.id, track.path))
            }
        }
        guard !paths.isEmpty else {
            if !missingTrackIDs.isEmpty { missingTrackIDs = [] }
            return
        }

        // Обход файлов — в статической функции без захвата self; результат
        // применяется на главном потоке. Так предупреждение о захвате self
        // в параллельном коде (Swift 6) не возникает.
        Task { [weak self] in
            let result = await Self.missingFiles(paths: paths)
            guard let self else { return }
            if self.missingTrackIDs != result {
                self.missingTrackIDs = result
            }
        }
    }

    /// Проверяет файлы в фоне и возвращает ID отсутствующих.
    private static func missingFiles(paths: [(UUID, String)]) async -> Set<UUID> {
        await Task.detached(priority: .utility) {
            var missing: Set<UUID> = []
            for (id, path) in paths where !FileManager.default.fileExists(atPath: path) {
                missing.insert(id)
            }
            return missing
        }.value
    }

    /// Файл трека отсутствует на диске.
    func isMissing(_ trackID: UUID) -> Bool {
        missingTrackIDs.contains(trackID)
    }

    /// Скрыть или показать список плейлистов.
    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    // MARK: - Focus Fade

    /// Плеер перестал быть активным: плавно останавливаем воспроизведение.
    private func handleAppDidResignActive() {
        guard state.settings.focusFadeEnabled else { return }
        guard audioEngine.isPlaying, !audioEngine.isTransitioning else { return }
        focusFadeDidPause = audioEngine.fadeOutPause(duration: state.settings.focusFadeDuration)
    }

    /// Возвращение к плееру. Возобновляем только ту паузу, которую поставил
    /// Focus Fade: если трек поставили на паузу вручную, воспроизведение
    /// не возобновляется.
    private func handleAppDidBecomeActive() {
        // Файлы могли измениться, пока плеер был в фоне.
        refreshMissingTracks()

        guard focusFadeDidPause else { return }
        focusFadeDidPause = false
        audioEngine.fadeInResume(duration: state.settings.focusFadeDuration)
    }

    // MARK: - Waveform выбранного трека

    /// Показывает waveform для текущего displayedTrack.
    ///
    /// Работает только с кэшем: диск не трогается, если пики уже посчитаны.
    /// Повторный вызов для того же трека ничего не пересчитывает, поэтому
    /// частые обновления (тик воспроизведения, смена выделения) почти бесплатны.
    func refreshDisplayedWaveform() {
        guard let track = displayedTrack else {
            displayedWaveform = []
            displayedWaveformOwner = nil
            return
        }

        let id = track.id

        // Пики уже есть — показываем сразу, без единой операции с диском.
        if let cached = waveformCache[id] {
            // Пики уже показаны для этого трека — ничего не делаем и не сравниваем массивы.
            if displayedWaveformOwner == id { return }
            displayedWaveform = cached
            displayedWaveformOwner = id
            return
        }

        // Уже считаются — ждём результат, второй расчёт не запускаем.
        if waveformLoading.contains(id) { return }

        waveformLoading.insert(id)
        waveformRequestID = UUID()
        let requestID = waveformRequestID

        Task { @MainActor [weak self] in
            let result = await WaveformGenerator.load(for: track, requestID: requestID)
            guard let self else { return }
            self.waveformLoading.remove(id)

            // Результат отменён как устаревший — не применяем.
            guard !result.isCancelled else { return }

            if !result.peaks.isEmpty {
                self.waveformCache[id] = result.peaks
            }
            if result.duration > 0 {
                self.durationCache[id] = result.duration
                self.updateDuration(for: id, duration: result.duration)
            }

            // Показываем только если этот трек всё ещё выбран и расчёт актуален.
            if self.displayedTrack?.id == id, self.waveformRequestID == requestID {
                self.displayedWaveform = result.peaks
                self.displayedWaveformOwner = id
            }
        }
    }

    // MARK: - Текущий плейлист

    var playlistsSorted: [Playlist] {
        state.playlists.sorted { $0.order < $1.order }
    }

    var selectedPlaylist: Playlist? {
        guard let id = selectedPlaylistID else { return nil }
        return state.playlists.first { $0.id == id }
    }

    var selectedPlaylistIndex: Int? {
        guard let id = selectedPlaylistID else { return nil }
        return state.playlists.firstIndex { $0.id == id }
    }

    func findTrack(_ id: UUID) -> Track? {
        for playlist in state.playlists {
            if let track = playlist.tracks.first(where: { $0.id == id }) { return track }
        }
        return nil
    }

    private func playlistContaining(trackID: UUID) -> Int? {
        state.playlists.firstIndex { $0.tracks.contains { $0.id == trackID } }
    }

    // MARK: - Трек, отображаемый на waveform

    /// Первый выделенный трек; если ничего не выделено — играющий.
    var displayedTrack: Track? {
        if let playlist = selectedPlaylist, !selection.isEmpty {
            return selection.selectedTracks(from: playlist.tracks).first
        }
        if let id = audioEngine.currentTrack?.id, let playing = findTrack(id) {
            return playing
        }
        return nil
    }

    // MARK: - Плейлисты

    func addPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Плейлист \(state.playlists.count + 1)" : trimmed
        let nextOrder = (state.playlists.map(\.order).max() ?? -1) + 1
        let color = RGBAColor.palette[state.playlists.count % RGBAColor.palette.count]
        let playlist = Playlist(name: title, color: color, order: nextOrder)
        state.playlists.append(playlist)
        selectedPlaylistID = playlist.id
        selection.clear()
        save()
    }

    func renamePlaylist(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        state.playlists[index].name = trimmed
        save()
    }

    func setColor(_ color: RGBAColor, for id: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        state.playlists[index].color = color
        save()
    }

    func deletePlaylist(id: UUID) {
        audioEngine.stop()
        state.playlists.removeAll { $0.id == id }
        if state.playlists.isEmpty {
            state.playlists = [Playlist(name: "Плейлист 1", order: 0)]
        }
        reindexPlaylists()
        if selectedPlaylistID == id {
            selectedPlaylistID = playlistsSorted.first?.id
        }
        selection.clear()
        save()
    }

    /// Сдвиг плейлиста на позицию выше (гарантированный способ без drag-n-drop).
    func movePlaylistUp(id: UUID) {
        var sorted = playlistsSorted
        guard let i = sorted.firstIndex(where: { $0.id == id }), i > 0 else { return }
        sorted.swapAt(i, i - 1)
        applyPlaylistOrder(sorted)
    }

    /// Сдвиг плейлиста на позицию ниже.
    func movePlaylistDown(id: UUID) {
        var sorted = playlistsSorted
        guard let i = sorted.firstIndex(where: { $0.id == id }), i < sorted.count - 1 else { return }
        sorted.swapAt(i, i + 1)
        applyPlaylistOrder(sorted)
    }

    private func applyPlaylistOrder(_ sorted: [Playlist]) {
        for (index, playlist) in sorted.enumerated() {
            if let i = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
                state.playlists[i].order = index
            }
        }
        save()
    }

    /// Перетаскивание плейлиста: ставит плейлист `id` на позицию плейлиста `targetID`.
    func movePlaylist(id: UUID, onto targetID: UUID) {
        var sorted = playlistsSorted
        guard let from = sorted.firstIndex(where: { $0.id == id }),
              let to = sorted.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        let item = sorted.remove(at: from)
        sorted.insert(item, at: to)
        applyPlaylistOrder(sorted)
    }

    func movePlaylists(from source: IndexSet, to destination: Int) {
        var sorted = playlistsSorted
        sorted.move(fromOffsets: source, toOffset: destination)
        for (index, playlist) in sorted.enumerated() {
            if let i = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
                state.playlists[i].order = index
            }
        }
        save()
    }

    private func reindexPlaylists() {
        let sorted = playlistsSorted
        for (index, playlist) in sorted.enumerated() {
            if let i = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
                state.playlists[i].order = index
            }
        }
    }

    // MARK: - Настройки плейлиста

    func setLoopPlaylist(_ enabled: Bool) {
        guard let index = selectedPlaylistIndex else { return }
        state.playlists[index].loopEnabled = enabled
        save()
    }

    func setAutoplay(_ enabled: Bool) {
        guard let index = selectedPlaylistIndex else { return }
        state.playlists[index].autoplayEnabled = enabled
        save()
    }

    // MARK: - Треки

    func moveTracksToPlaylist(trackIDs: [UUID], targetPlaylistID: UUID) {
        guard let targetIndex = state.playlists.firstIndex(where: { $0.id == targetPlaylistID }) else { return }
        var movedTracks: [Track] = []

        for id in trackIDs {
            for pIndex in state.playlists.indices {
                if let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }) {
                    let track = state.playlists[pIndex].tracks.remove(at: tIndex)
                    movedTracks.append(track)
                    break
                }
            }
        }

        guard !movedTracks.isEmpty else { return }
        let existingTargetPaths = Set(state.playlists[targetIndex].tracks.map(\.path))
        let uniqueMoved = movedTracks.filter { !existingTargetPaths.contains($0.path) }
        state.playlists[targetIndex].tracks.append(contentsOf: uniqueMoved)
        selection.clear()
        save()
    }

    func addTracks(urls: [URL]) {
        guard let playlistID = selectedPlaylistID,
              let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }

        let existingPaths = Set(state.playlists[index].tracks.map(\.path))
        var added: [Track] = []

        for url in urls {
            let standardized = url.standardizedFileURL
            guard !existingPaths.contains(standardized.path) else { continue }
            added.append(Track(url: standardized))
        }

        guard !added.isEmpty else { return }
        state.playlists[index].tracks.append(contentsOf: added)
        save()

        // Длительность берётся из заголовка файла — без разбора сэмплов.
        // Пики посчитаются позже, когда трек выберут.
        Task { @MainActor [weak self] in
            for track in added {
                let duration = await WaveformGenerator.duration(of: track)
                self?.updateDuration(for: track.id, duration: duration)
            }
        }
    }

    private func updateDuration(for trackID: UUID, duration: TimeInterval) {
        guard duration > 0 else { return }
        for pIndex in state.playlists.indices {
            if let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) {
                state.playlists[pIndex].tracks[tIndex].duration = duration
                scheduleAutosave()
                return
            }
        }
    }

    func removeTracks(at offsets: IndexSet) {
        guard let index = selectedPlaylistIndex else { return }
        let removing = offsets.map { state.playlists[index].tracks[$0] }
        removeTracks(ids: removing.map(\.id))
    }

    func removeTrack(id: UUID) {
        removeTracks(ids: [id])
    }

    func removeSelectedTracks() {
        removeTracks(ids: Array(selection.selectedIDs))
    }

    func removeTracks(ids: [UUID]) {
        for id in ids {
            pendingStartPositions[id] = nil
            missingTrackIDs.remove(id)
            waveformCache[id] = nil
            durationCache[id] = nil
            waveformLoading.remove(id)
        }
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        
        if let current = audioEngine.currentTrack, idSet.contains(current.id) {
            audioEngine.stop()
        }
        
        for pIndex in state.playlists.indices {
            state.playlists[pIndex].tracks.removeAll { idSet.contains($0.id) }
        }
        
        selection.clear()
        save()
    }

    func moveTracks(from source: IndexSet, to destination: Int) {
        guard let index = selectedPlaylistIndex else { return }
        state.playlists[index].tracks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Сдвиг трека на одну позицию вверх.
    func moveTrackUp(id: UUID) {
        guard let pIndex = playlistContaining(trackID: id),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }),
              tIndex > 0 else { return }
        state.playlists[pIndex].tracks.swapAt(tIndex, tIndex - 1)
        save()
    }

    /// Сдвиг трека на одну позицию вниз.
    func moveTrackDown(id: UUID) {
        guard let pIndex = playlistContaining(trackID: id),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }),
              tIndex < state.playlists[pIndex].tracks.count - 1 else { return }
        state.playlists[pIndex].tracks.swapAt(tIndex, tIndex + 1)
        save()
    }

    /// Перемещение выделенных треков на позицию (для drag-n-drop).
    func moveTracks(ids: [UUID], to destinationIndex: Int) {
        // Перенос завершён — линия индикатора больше не нужна.
        trackDropTarget = nil
        playlistDropTargetID = nil

        guard let index = selectedPlaylistIndex, !ids.isEmpty else { return }
        let moving = Set(ids)
        var tracks = state.playlists[index].tracks
        
        let movingTracks = tracks.filter { moving.contains($0.id) }
        guard !movingTracks.isEmpty else { return }
        
        tracks.removeAll { moving.contains($0.id) }
        
        // Пересчитываем индекс вставки после удаления
        let removedBefore = state.playlists[index].tracks
            .prefix(max(0, min(destinationIndex, state.playlists[index].tracks.count)))
            .filter { moving.contains($0.id) }
            .count
        let insertAt = max(0, min(destinationIndex - removedBefore, tracks.count))
        
        tracks.insert(contentsOf: movingTracks, at: insertAt)
        state.playlists[index].tracks = tracks
        save()
    }

    // MARK: - Атрибуты треков

    func setTrackColor(_ color: RGBAColor?, for trackID: UUID) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        state.playlists[pIndex].tracks[tIndex].color = color
        syncEngineTrack(trackID)
        save()
    }

    func setColorForSelected(_ color: RGBAColor?) {
        for id in selection.selectedIDs {
            guard let pIndex = playlistContaining(trackID: id),
                  let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }) else { continue }
            state.playlists[pIndex].tracks[tIndex].color = color
        }
        save()
    }

    func toggleDeleteAfterPlay(for trackID: UUID) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        state.playlists[pIndex].tracks[tIndex].deleteAfterPlay.toggle()
        syncEngineTrack(trackID)
        save()
    }

    func toggleDeleteAfterPlayForSelected() {
        let ids = selection.selectedIDs
        guard !ids.isEmpty else { return }
        // Если хотя бы у одного выключено — включаем у всех, иначе выключаем.
        let anyOff = ids.contains { id in
            findTrack(id)?.deleteAfterPlay == false
        }
        for id in ids {
            guard let pIndex = playlistContaining(trackID: id),
                  let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }) else { continue }
            state.playlists[pIndex].tracks[tIndex].deleteAfterPlay = anyOff
        }
        save()
    }

    // MARK: - Audio Trim

    /// Устанавливает точки обрезки. Значения в секундах от начала файла.
    func setTrim(for trackID: UUID, start: TimeInterval?, end: TimeInterval?) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        var track = state.playlists[pIndex].tracks[tIndex]
        let total = track.duration
        
        if let start {
            track.trimStart = max(0, min(start, total > 0 ? total - 0.1 : start))
        }
        if let end {
            let clamped = max(0, min(end, total > 0 ? total : end))
            // Если точка совпадает с концом файла — храним nil (значит "до конца")
            if total > 0 && abs(clamped - total) < 0.05 {
                track.trimEnd = nil
            } else {
                track.trimEnd = clamped
            }
        }
        
        // Не даём точкам пересечься
        if let end = track.trimEnd, track.trimStart >= end {
            track.trimStart = max(0, end - 0.1)
        }
        
        state.playlists[pIndex].tracks[tIndex] = track
        syncEngineTrack(trackID)
        scheduleAutosave()
    }

    func resetTrim(for trackID: UUID) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        state.playlists[pIndex].tracks[tIndex].trimStart = 0
        state.playlists[pIndex].tracks[tIndex].trimEnd = nil
        syncEngineTrack(trackID)
        save()
    }

    private func syncEngineTrack(_ trackID: UUID) {
        guard audioEngine.currentTrack?.id == trackID, let track = findTrack(trackID) else { return }
        audioEngine.syncCurrentTrack(track)
    }

    // MARK: - Воспроизведение

    func play(track: Track) {
        let start: TimeInterval

        if let pending = pendingStartPositions[track.id] {
            // Точка, выбранная на waveform до запуска трека.
            start = pending
        } else if audioEngine.currentTrack?.id == track.id, !audioEngine.isPlaying {
            // Трек уже загружен в движок на паузе — начинаем с той же позиции.
            start = audioEngine.currentTime
        } else {
            start = 0
        }

        pendingStartPositions[track.id] = nil
        audioEngine.play(track: track, from: start)
    }

    func playFirstTrackOfSelectedPlaylist() {
        guard let playlist = selectedPlaylist, let first = playlist.tracks.first else { return }
        play(track: first)
    }

    func togglePlayPause() {
        // Если играет именно выделенный трек — ставим на паузу
        if audioEngine.isPlaying,
           let currentID = audioEngine.currentTrack?.id,
           selection.isSelected(currentID) {
            audioEngine.pause()
            return
        }

        // Если выделен другой трек — запускаем его
        if let playlist = selectedPlaylist, !selection.isEmpty,
           let first = selection.selectedTracks(from: playlist.tracks).first {
            play(track: first)
            return
        }

        // Иначе: пауза / продолжить / первый трек плейлиста
        if audioEngine.isPlaying {
            audioEngine.pause()
        } else if audioEngine.currentTrack != nil {
            audioEngine.resume()
        } else {
            playFirstTrackOfSelectedPlaylist()
        }
    }

    /// Переход к следующему треку плейлиста (по кругу, если включено зацикливание).
    func playNext() {
        guard let playlist = selectedPlaylist, !playlist.tracks.isEmpty else { return }
        guard let currentID = audioEngine.currentTrack?.id,
              let currentIndex = playlist.tracks.firstIndex(where: { $0.id == currentID }) else {
            playFirstTrackOfSelectedPlaylist()
            return
        }
        let nextIndex = currentIndex + 1
        if nextIndex < playlist.tracks.count {
            play(track: playlist.tracks[nextIndex])
        } else if playlist.loopEnabled {
            play(track: playlist.tracks[0])
        } else {
            audioEngine.stop()
        }
    }

    /// Переход к предыдущему треку.
    func playPrevious() {
        guard let playlist = selectedPlaylist, !playlist.tracks.isEmpty else { return }
        guard let currentID = audioEngine.currentTrack?.id,
              let currentIndex = playlist.tracks.firstIndex(where: { $0.id == currentID }) else {
            playFirstTrackOfSelectedPlaylist()
            return
        }
        let previousIndex = currentIndex - 1
        if previousIndex >= 0 {
            play(track: playlist.tracks[previousIndex])
        } else if playlist.loopEnabled {
            play(track: playlist.tracks[playlist.tracks.count - 1])
        } else {
            // На первом треке — начинаем его заново
            audioEngine.seek(to: 0)
        }
    }

    // MARK: - Завершение трека

    private func handleTrackFinished() {
        guard let finished = audioEngine.currentTrack else { return }
        let finishedID = finished.id
        
        // 1. Зацикливание трека — играем его же сначала.
        if state.settings.loopTrackEnabled {
            let resumed: Track
            if let pIndex = playlistContaining(trackID: finishedID),
               let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == finishedID }) {
                resumed = state.playlists[pIndex].tracks[tIndex]
            } else {
                resumed = finished
            }
            audioEngine.play(track: resumed)
            return
        }
        
        guard let playlist = selectedPlaylist,
              let index = playlist.tracks.firstIndex(where: { $0.id == finishedID }) else {
            audioEngine.stop()
            return
        }
        
        // 2. Удаление после полного проигрывания.
        if playlist.tracks[index].deleteAfterPlay {
            removeTracks(ids: [finishedID])
            // После удаления список сдвинулся: играем трек, который встал на это место
            if let nextPlaylist = selectedPlaylist, index < nextPlaylist.tracks.count {
                play(track: nextPlaylist.tracks[index])
            } else if let nextPlaylist = selectedPlaylist, nextPlaylist.loopEnabled,
                      let first = nextPlaylist.tracks.first {
                play(track: first)
            } else {
                audioEngine.stop()
            }
            return
        }
        
        // 3. Автопереход на следующий трек.
        guard playlist.autoplayEnabled else {
            audioEngine.stop()
            return
        }
        
        let nextIndex = index + 1
        if nextIndex < playlist.tracks.count {
            play(track: playlist.tracks[nextIndex])
        } else if playlist.loopEnabled, let first = playlist.tracks.first {
            play(track: first)
        } else {
            audioEngine.stop()
        }
    }

    // MARK: - Перемотка

    /// Перематывает трек, показанный на waveform.
    ///
    /// Если показан играющий трек — обычная перемотка.
    /// Если показан другой (выделенный, но не играющий) трек — запоминаем точку
    /// старта и НЕ трогаем текущее воспроизведение: играющий трек продолжает
    /// звучать, а выбранная точка применится, когда запустят этот трек.
    func seekDisplayed(to time: TimeInterval, thenPlay: Bool) {
        guard let track = displayedTrack else { return }
        let clamped = max(0, min(time, max(0, track.effectiveDuration)))

        if audioEngine.currentTrack?.id == track.id {
            audioEngine.seek(to: clamped)
            if thenPlay && !audioEngine.isPlaying {
                audioEngine.resume()
            }
            return
        }

        pendingStartPositions[track.id] = clamped

        // Протягивание по waveform запускает выбранный трек с этой точки,
        // но только когда ничего не играет. Во время воспроизведения точка
        // лишь запоминается — прерывать играющий трек нельзя.
        if thenPlay && !audioEngine.isPlaying {
            play(track: track)
        }
    }

    /// Точка старта, сохранённая для трека (0, если не задана).
    func pendingStart(for trackID: UUID) -> TimeInterval {
        pendingStartPositions[trackID] ?? 0
    }

    // MARK: - Настройки

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        transform(&state.settings)
        audioEngine.settings = state.settings
        audioEngine.applyVolume()
        scheduleAutosave()
    }

    func setVolume(_ value: Double) {
        updateSettings { $0.volume = max(0, min(value, 1)) }
    }

    // MARK: - Сохранение

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        autosaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    func save() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        state.selectedPlaylistID = selectedPlaylistID
        storage.save(state)
    }

    // MARK: - Экспорт / импорт

    func exportSelectedPlaylist(to url: URL) {
        guard let playlist = selectedPlaylist else { return }
        do { try storage.export(playlist, to: url) }
        catch { NSLog("DJPlayer: экспорт не удался — \(error.localizedDescription)") }
    }

    func importPlaylist(from url: URL) {
        do {
            var playlist = try storage.`import`(from: url)
            playlist.order = (state.playlists.map(\.order).max() ?? -1) + 1
            state.playlists.append(playlist)
            selectedPlaylistID = playlist.id
            save()
        } catch {
            NSLog("DJPlayer: импорт не удался — \(error.localizedDescription)")
        }
    }
}
