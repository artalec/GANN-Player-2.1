import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Список треков плейлиста: выделение, drag-n-drop файлов, перетаскивание порядка.
struct TrackList: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if let playlist = model.selectedPlaylist {
                if playlist.tracks.isEmpty {
                    emptyState
                } else {
                    trackListView(playlist)
                }
            } else {
                VStack {
                    Text("Плейлист не выбран")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Приём аудиофайлов, перетащенных из Finder
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
    }

    // MARK: - Панель над списком

    private var topBar: some View {
        HStack(spacing: 10) {
            if let playlist = model.selectedPlaylist {
                RoundedRectangle(cornerRadius: 3)
                    .fill(playlist.color.swiftUIColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.headline)
                    Text("Треков: \(playlist.tracks.count)  ·  Длительность: \(playlistDuration(playlist))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if model.selection.count > 0 {
                Text("\(model.selection.count) выделено")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    model.removeSelectedTracks()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Удалить выделенные")
            }

            Text("клик · ⌘+клик · ⇧+клик для диапазона")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button {
                model.playFirstTrackOfSelectedPlaylist()
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Запустить первый трек")
            .disabled(model.selectedPlaylist?.tracks.isEmpty ?? true)

            Button {
                addTracks()
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            .disabled(model.selectedPlaylist == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Список

    private func trackListView(_ playlist: Playlist) -> some View {
        List(selection: Binding(
            get: { model.selection.selectedIDs },
            set: { model.selection.setSelectedIDs($0) }
        )) {
            ForEach(playlist.tracks, id: \.id) { track in
                TrackRow(
                    track: track,
                    isCurrent: model.audioEngine.currentTrack?.id == track.id,
                    isSelected: model.selection.isSelected(track.id),
                    playlistColor: playlist.color,
                    onClick: { modifiers in
                        handleTrackClick(track.id, modifiers: modifiers, tracks: playlist.tracks)
                    }
                )
                .tag(track.id)
                .overlay(alignment: .top) {
                    if showsDropLine(above: track.id) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .allowsHitTesting(false)
                    }
                }
                .contextMenu {
                    trackContextMenu(track)
                }
                .onDrag {
                    let ids = model.selection.isSelected(track.id) ? Array(model.selection.selectedIDs) : [track.id]
                    model.trackDropTarget = nil
                    model.playlistDropTargetID = nil
                    model.beginDragWatch()
                    model.draggingTrackIDs = ids
                    model.draggingPlaylistID = nil

                    // Провайдеру отдаём сам файл: тогда Finder скопирует трек
                    // целиком, сохранив оригинальное расширение, а не создаст
                    // .textClipping из строки.
                    let provider = NSItemProvider(contentsOf: track.url) ?? NSItemProvider()
                    // Имя файла в Finder: только базовое имя, без расширения. Расширение
                    // Finder добавляет сам по типу файла, поэтому получается Song.mp3,
                    // а не Song.mp3.mp3. Без имени macOS подставляет «MP3Audio».
                    provider.suggestedName = track.url.deletingPathExtension().lastPathComponent
                    // Метка для внутренних перемещений: видна только нашему
                    // процессу и не мешает копированию файла наружу.
                    provider.registerObject("tracks" as NSString, visibility: .ownProcess)
                    return provider
                }
                .onDrop(of: [.plainText, .fileURL],
                        delegate: TrackDropDelegate(
                            targetIndex: playlist.tracks.firstIndex(where: { $0.id == track.id }) ?? 0,
                            targetID: track.id,
                            model: model))
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
            .onDelete { offsets in
                model.removeTracks(at: offsets)
            }
        }
        .listStyle(.inset)
    }

    /// Нужно ли рисовать синюю линию над строкой трека с данным ID.
    private func showsDropLine(above trackID: UUID) -> Bool {
        guard let target: (id: UUID, before: Bool) = model.trackDropTarget else { return false }
        return target.id == trackID && target.before
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("В плейлисте пока нет треков")
                .foregroundStyle(.secondary)
            Text("Перетащите аудиофайлы сюда или нажмите «Добавить»")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Добавить треки") { addTracks() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Выделение

    private func handleTrackClick(_ id: UUID, modifiers: EventModifiers, tracks: [Track]) {
        let orderedIDs = tracks.map(\.id)

        if modifiers.contains(.command) {
            model.selection.toggle(id)
        } else if modifiers.contains(.shift) {
            model.selection.selectRange(to: id, in: orderedIDs)
        } else {
            model.selection.selectSingle(id)
        }
    }

    // MARK: - Контекстное меню

    @ViewBuilder
    private func trackContextMenu(_ track: Track) -> some View {
        Button("Воспроизвести") {
            model.play(track: track)
        }

                Button("🤖 Разделить на стемсы (Вокал / Инструментал)") {
            model.separateStems(for: track)
        }

        Button("Показать в Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([track.url])
        }

        Divider()

        Menu("Переместить в плейлист") {
            ForEach(model.playlistsSorted.filter { $0.id != model.selectedPlaylistID }) { pl in
                Button(pl.name) {
                    let ids = model.selection.isSelected(track.id) ? Array(model.selection.selectedIDs) : [track.id]
                    model.moveTracksToPlaylist(trackIDs: ids, targetPlaylistID: pl.id)
                }
            }
        }

        Divider()

        Menu("Изменить цвет") {
            ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { item in
                Button {
                    if model.selection.isSelected(track.id) && model.selection.count > 1 {
                        model.setColorForSelected(item.element)
                    } else {
                        model.setTrackColor(item.element, for: track.id)
                    }
                } label: {
                    Text(Self.colorEmoji(item.offset))
                }
            }
            Divider()
            Button("Сбросить цвет") {
                if model.selection.isSelected(track.id) && model.selection.count > 1 {
                    model.setColorForSelected(nil)
                } else {
                    model.setTrackColor(nil, for: track.id)
                }
            }
        }

        Button(track.deleteAfterPlay ? "Не удалять после проигрывания" : "Удалять после проигрывания") {
            if model.selection.isSelected(track.id) && model.selection.count > 1 {
                model.toggleDeleteAfterPlayForSelected()
            } else {
                model.toggleDeleteAfterPlay(for: track.id)
            }
        }

        Button("Сбросить обрезку") {
            model.resetTrim(for: track.id)
        }

        Divider()

        Button("Переместить выше") {
            model.moveTrackUp(id: track.id)
        }
        Button("Переместить ниже") {
            model.moveTrackDown(id: track.id)
        }

        Divider()

        Button("Удалить трек", role: .destructive) {
            if model.selection.isSelected(track.id) && model.selection.count > 1 {
                model.removeSelectedTracks()
            } else {
                model.removeTrack(id: track.id)
            }
        }
    }

    // MARK: - Drag and drop файлов

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        // Перетаскивание внутри плеера своим обработчиком не занимается: файлы
        // из Finder обрабатываются только когда ничего не тянется.
        guard model.draggingTrackIDs.isEmpty, model.draggingPlaylistID == nil else { return false }

        let fileType = UTType.fileURL.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(fileType) }
        guard !matching.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            for provider in matching {
                if let data = try? await provider.loadItem(forTypeIdentifier: fileType) as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }

            // Проверку файлов делаем вне главного потока: открытие файла — операция
            // с диском и не должна подвешивать интерфейс.
            let candidates = urls
            let collected = await Task.detached(priority: .userInitiated) { () -> [URL] in
                candidates.filter { AudioFileSupport.canOpen($0) }
            }.value

            if !collected.isEmpty {
                await MainActor.run {
                    model.addTracks(urls: collected)
                }
            }
        }
        return true
    }

    // MARK: - Перетаскивание порядка треков

    /// Цветной кружок (эмодзи) для пункта меню, в порядке RGBAColor.palette.
    static func colorEmoji(_ index: Int) -> String {
        let circles = ["🔵", "🔴", "🟢", "🟠", "🟣", "💧", "💗", "⚫", "🟡", "🟤"]
        return circles[index % circles.count]
    }

    /// Кружок цвета для пункта меню (не template, чтобы macOS не сделал его серым).
    static func colorDotImage(_ color: RGBAColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func addTracks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.title = "Выберите аудиофайлы"
        if panel.runModal() == .OK {
            model.addTracks(urls: panel.urls)
        }
    }

    /// Суммарная длительность плейлиста с учётом trim-точек.
    private func playlistDuration(_ playlist: Playlist) -> String {
        let total = playlist.tracks.reduce(0.0) { $0 + $1.effectiveDuration }
        return total.timecode
    }
}

// MARK: - Строка трека

private struct TrackRow: View {

    let track: Track
    let isCurrent: Bool
    let isSelected: Bool
    let playlistColor: RGBAColor
    let onClick: (EventModifiers) -> Void

    @EnvironmentObject private var model: AppModel
    @State private var isHovering = false

    private var effectiveColor: RGBAColor {
        track.color ?? playlistColor
    }

    /// Файл трека отсутствует (следит модель, поэтому значок обновляется сразу).
    private var isMissing: Bool {
        model.isMissing(track.id)
    }

    private var rowIconName: String {
        if isMissing { return "exclamationmark.triangle.fill" }
        return isCurrent ? "speaker.wave.2.fill" : "music.note"
    }

    private var rowIconColor: Color {
        if isMissing { return Color.red }
        return isCurrent ? effectiveColor.swiftUIColor : Color.secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            // Файл исчез с диска — вместо ноты показываем предупреждение.
            Image(systemName: rowIconName)
                .foregroundStyle(rowIconColor)
                .frame(width: 16)
                .help(isMissing ? "Файл не найден: \(track.path)" : track.name)

            RoundedRectangle(cornerRadius: 2)
                .fill(effectiveColor.swiftUIColor)
                .frame(width: 3, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(isMissing ? Color.red : Color.secondary)

                    if track.deleteAfterPlay {
                        Text("• удалить после проигрывания")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                    }

                    if track.trimStart > 0 || track.trimEnd != nil {
                        Text("• обрезка")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.cyan)
                    }
                }
                .lineLimit(1)
            }

            Spacer()

            Text(track.effectiveDuration.timecode)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.play(track: track)
        }
        .onTapGesture(count: 1) {
            onClick(currentModifiers())
        }
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return effectiveColor.swiftUIColor.opacity(0.25)
        }
        return isHovering ? Color.secondary.opacity(0.08) : Color.clear
    }

    private var detail: String {
        !isMissing ? track.url.deletingLastPathComponent().lastPathComponent : "файл не найден"
    }


    /// NSEvent.ModifierFlags и SwiftUI EventModifiers — разные типы,
    /// поэтому переносим флаги вручную.
    private func currentModifiers() -> EventModifiers {
        let flags = NSEvent.modifierFlags
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

/// Перестановка треков перетаскиванием: трек вставляется перед строкой, на которую бросили.
struct TrackDropDelegate: DropDelegate {
    let targetIndex: Int
    let targetID: UUID
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        !model.draggingTrackIDs.isEmpty
    }

    /// Трек вставляется ПЕРЕД строкой, над которой отпущен. Линия рисуется
    /// над строкой — ровно там, где окажется трек.
    func dropEntered(info: DropInfo) {
        showIndicator()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        showIndicator()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.trackDropTarget?.id == targetID {
            model.trackDropTarget = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        // Сбрасываем состояние при любом исходе: и при переносе, и при отказе.
        defer { model.endDragging() }
        let ids = model.draggingTrackIDs
        guard !ids.isEmpty, !ids.contains(targetID) else { return false }
        model.moveTracks(ids: ids, to: targetIndex)
        return true
    }

    private func showIndicator() {
        // Перетаскивание уже завершено — линию не показываем. Без этой проверки
        // dropUpdated, приходящий после performDrop при перестройке списка,
        // зажигал бы линию заново.
        guard !model.draggingTrackIDs.isEmpty else {
            model.trackDropTarget = nil
            return
        }
        // Не показываем линию, если строка — сам перетаскиваемый трек: переносить некуда.
        guard !model.draggingTrackIDs.contains(targetID) else {
            model.trackDropTarget = nil
            return
        }
        // Запись только при изменении, чтобы не перерисовывать список на каждом кадре.
        if model.trackDropTarget?.id != targetID || model.trackDropTarget?.before != true {
            model.trackDropTarget = (targetID, true)
        }
    }
}

// MARK: - Поддержка аудиоформатов

/// Проверка форматов вынесена из View: внутри `View` методы неявно привязаны к
/// главному актору, а открытие файла должно выполняться в фоновом потоке.
enum AudioFileSupport {

    /// Расширения, которые macOS умеет декодировать (AVFoundation + системные кодеки).
    static let audioExtensions: Set<String> = [
        "mp3", "wav", "wave", "m4a", "m4b", "m4r", "aac", "adts", "flac",
        "aif", "aiff", "aifc", "caf", "alac", "au", "snd", "mp2", "mp1",
        "ac3", "eac3", "amr", "mp4", "m4v", "mov", "3gp", "3g2", "sd2", "opus"
    ]

    /// Знакомое расширение принимается сразу, незнакомое проверяется открытием файла.
    nonisolated static func canOpen(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return true }
        return AudioEngine.canOpen(url)
    }
}
