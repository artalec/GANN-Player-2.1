import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Левая колонка: список плейлистов с изменением порядка перетаскиванием.
struct PlaylistSidebar: View {

    @EnvironmentObject private var model: AppModel

    @State private var isAdding = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @State private var coloring: Playlist?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        // Стрелка в центре правой границы области плейлистов: скрывает список.
        .overlay(alignment: .trailing) {
            SidebarToggleButton(
                systemName: "chevron.left",
                help: "Скрыть список плейлистов",
                action: { model.toggleSidebar() }
            )
            .offset(x: 8)
        }
        .sheet(isPresented: $isAdding) { addSheet }
        .sheet(item: $renaming) { playlist in renameSheet(playlist) }
        .sheet(item: $coloring) { playlist in colorSheet(playlist) }
    }

    // MARK: - Секции

    private var header: some View {
        HStack {
            Text("Плейлисты")
                .font(.headline)
            Spacer()
            Button {
                newName = ""
                isAdding = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Создать плейлист")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Сторона линии для строки плейлиста: если перетаскиваемый плейлист
    /// находится выше целевого — он встанет под строкой (линия снизу), иначе — над ней.
    private func playlistIndicatorAlignment(for playlist: Playlist) -> Alignment {
        let sorted = model.playlistsSorted
        guard let dragged = model.draggingPlaylistID,
              let from = sorted.firstIndex(where: { $0.id == dragged }),
              let to = sorted.firstIndex(where: { $0.id == playlist.id }) else {
            return .top
        }
        return from < to ? .bottom : .top
    }

    /// Видна ли линия над/под строкой плейлиста.
    private func showsPlaylistDropLine(for playlist: Playlist) -> Bool {
        let targetID: UUID? = model.playlistDropTargetID
        return targetID == playlist.id
    }

    /// Сторона линии для строки плейлиста (верх или низ).
    private func indicatorSide(for playlist: Playlist) -> Alignment {
        playlistIndicatorAlignment(for: playlist)
    }

    /// Играет ли сейчас трек из данного плейлиста.
    private func isPlaying(in playlist: Playlist) -> Bool {
        guard let current: Track = model.audioEngine.currentTrack else { return false }
        return playlist.tracks.contains(where: { (track: Track) -> Bool in track.id == current.id })
    }

    private var list: some View {
        List(selection: $model.selectedPlaylistID) {
            ForEach(model.playlistsSorted) { playlist in
                PlaylistRow(
                    playlist: playlist,
                    isSelected: playlist.id == model.selectedPlaylistID,
                    isPlayingHere: isPlaying(in: playlist),
                    onRename: {
                        renameText = playlist.name
                        renaming = playlist
                    },
                    onRecolor: { coloring = playlist },
                    onMoveUp: { model.movePlaylistUp(id: playlist.id) },
                    onMoveDown: { model.movePlaylistDown(id: playlist.id) },
                    onDelete: { model.deletePlaylist(id: playlist.id) }
                )
                .tag(playlist.id)
                .overlay(alignment: indicatorSide(for: playlist)) {
                    if showsPlaylistDropLine(for: playlist) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedPlaylistID = playlist.id
                    model.selection.clear()
                }
                .onDrag {
                    model.trackDropTarget = nil
                    model.playlistDropTargetID = nil
                    model.beginDragWatch()
                    model.draggingPlaylistID = playlist.id
                    model.draggingTrackIDs = []
                    return NSItemProvider(object: "playlist" as NSString)
                }
                .onDrop(of: [.plainText, .fileURL],
                        delegate: PlaylistDropDelegate(target: playlist, model: model))
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            }
        }
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                importPlaylist()
            } label: {
                Label("Загрузить", systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Button {
                exportPlaylist()
            } label: {
                Label("Сохранить", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedPlaylist == nil)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Модальные окна

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новый плейлист").font(.headline)
            TextField("Название", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Отмена") { isAdding = false }
                    .keyboardShortcut(.cancelAction)
                Button("Создать") {
                    model.addPlaylist(named: newName)
                    isAdding = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func renameSheet(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Переименовать плейлист").font(.headline)
            TextField("Название", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Отмена") { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    model.renamePlaylist(id: playlist.id, to: renameText)
                    renaming = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func colorSheet(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Цвет плейлиста").font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 10), count: 5), spacing: 10) {
                ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { item in
                    Circle()
                        .fill(item.element.swiftUIColor)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().stroke(
                                Color.primary.opacity(item.element == playlist.color ? 0.9 : 0.12),
                                lineWidth: item.element == playlist.color ? 2 : 1
                            )
                        )
                        .onTapGesture {
                            model.setColor(item.element, for: playlist.id)
                            coloring = nil
                        }
                }
            }

            HStack {
                Spacer()
                Button("Закрыть") { coloring = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Диалоги файлов

    private func exportPlaylist() {
        guard let playlist = model.selectedPlaylist else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(playlist.name).djplaylist.json"
        panel.allowedContentTypes = [.json]
        panel.title = "Сохранить плейлист"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportSelectedPlaylist(to: url)
        }
    }

    private func importPlaylist() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.title = "Загрузить плейлист"
        if panel.runModal() == .OK, let url = panel.url {
            model.importPlaylist(from: url)
        }
    }
}

// MARK: - Строка плейлиста

// MARK: - Перетаскивание плейлистов и треков на плейлист

/// На строке плейлиста: перетаскивание плейлиста меняет порядок,
/// перетаскивание треков переносит их в этот плейлист.
struct PlaylistDropDelegate: DropDelegate {
    let target: Playlist
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        model.draggingPlaylistID != nil || !model.draggingTrackIDs.isEmpty
    }

    /// Плейлист встаёт НА место строки, на которую брошен. Индикатор показываем
    /// со стороны, куда он сдвинется: при движении вниз — под строкой, вверх — над ней.
    func dropEntered(info: DropInfo) {
        showIndicator()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        showIndicator()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.playlistDropTargetID == target.id {
            model.playlistDropTargetID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        // Сбрасываем состояние при любом исходе: и при переносе, и при отказе.
        defer { model.endDragging() }
        if let dragged = model.draggingPlaylistID {
            model.movePlaylist(id: dragged, onto: target.id)
            return true
        }
        let ids = model.draggingTrackIDs
        guard !ids.isEmpty, target.id != model.selectedPlaylistID else { return false }
        model.moveTracksToPlaylist(trackIDs: ids, targetPlaylistID: target.id)
        return true
    }

    /// Для перетаскивания плейлистов: отмечаем строку, над которой курсор.
    /// Сторону линии (над/под) вычисляем в PlaylistRow по направлению сдвига.
    private func showIndicator() {
        // Тянут именно плейлист. Проверка на nil нужна, чтобы обновление списка
        // после переноса не вернуло линию обратно.
        guard let dragged = model.draggingPlaylistID else {
            model.playlistDropTargetID = nil
            return
        }
        guard dragged != target.id else {
            model.playlistDropTargetID = nil
            return
        }
        if model.playlistDropTargetID != target.id {
            model.playlistDropTargetID = target.id
        }
    }
}

private struct PlaylistRow: View {

    let playlist: Playlist
    let isSelected: Bool
    let isPlayingHere: Bool
    let onRename: () -> Void
    let onRecolor: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(playlist.color.swiftUIColor)
                .frame(width: 4, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    if isPlayingHere {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(playlist.color.swiftUIColor)
                    }
                }

                HStack(spacing: 4) {
                    Text("\(playlist.tracks.count) трек(ов)")
                    if playlist.loopEnabled {
                        Image(systemName: "repeat").font(.system(size: 8))
                    }
                    if playlist.autoplayEnabled {
                        Image(systemName: "arrow.forward.to.line").font(.system(size: 8))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if isHovering {
                Menu {
                    Button("Переименовать", action: onRename)
                    Button("Изменить цвет", action: onRecolor)
                    Divider()
                    Button("Переместить выше", action: onMoveUp)
                    Button("Переместить ниже", action: onMoveDown)
                    Divider()
                    Button("Удалить", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? playlist.color.swiftUIColor.opacity(0.22) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}
