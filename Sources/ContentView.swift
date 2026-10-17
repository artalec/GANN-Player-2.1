import SwiftUI
import AppKit

/// Главное окно.
///
/// Раскладка:
///   слева  — список плейлистов
///   справа — waveform с маркерами обрезки, панель управления, список треков
struct ContentView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            if model.isSidebarVisible {
                PlaylistSidebar()
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 340)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Когда список плейлистов скрыт, этот блок остаётся единственным
            // в HSplitView и занимает всё окно.
            VStack(spacing: 0) {
                WaveformPanel()
                Divider()
                TrackList()
            }
            .frame(minWidth: 620)
            // Кнопка возврата списка: у левого края окна, по центру высоты.
            .overlay(alignment: .leading) {
                if !model.isSidebarVisible {
                    SidebarToggleButton(
                        systemName: "chevron.right",
                        help: "Показать список плейлистов",
                        action: { model.toggleSidebar() }
                    )
                }
            }
        }
        .frame(minWidth: 880, minHeight: 640)
        .animation(.easeInOut(duration: 0.2), value: model.isSidebarVisible)
    }
}

/// Кнопка скрытия и показа списка плейлистов: стрелка на границе области.
struct SidebarToggleButton: View {

    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 42)
                // RoundedRectangle, а не UnevenRoundedRectangle: последний появился
                // только в macOS 14, а проект собирается под macOS 13.
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(radius: 1)
                )
                .opacity(isHovering ? 1.0 : 0.75)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Верхняя часть: информация, waveform, управление

private struct WaveformPanel: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                trackInfo
                Spacer(minLength: 8)
                effectControls
            }

            WaveformView(
                peaks: model.displayedWaveform,
                currentTime: progressTime,
                duration: displayedDuration,
                accent: displayedAccent,
                trimStart: displayedTrimStart,
                trimEnd: displayedTrimEnd,
                onSeek: { time, shouldPlay in
                    model.seekDisplayed(to: time, thenPlay: shouldPlay)
                },
                onTrimChange: { start, end in
                    guard let track = model.displayedTrack else { return }
                    model.setTrim(for: track.id, start: start, end: end)
                }
            )
            .frame(height: 96)

            transportBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Данные для waveform

    private var displayedTrack: Track? { model.displayedTrack }

    private var displayedDuration: TimeInterval {
        displayedTrack?.duration ?? 0
    }

    private var displayedTrimStart: TimeInterval {
        displayedTrack?.trimStart ?? 0
    }

    private var displayedTrimEnd: TimeInterval {
        guard let track = displayedTrack else { return 0 }
        return track.trimEnd ?? track.duration
    }

    private var displayedAccent: RGBAColor {
        displayedTrack?.color ?? model.selectedPlaylist?.color ?? RGBAColor(red: 0.2, green: 0.55, blue: 1.0)
    }

    /// Время для курсора: если играет этот трек — реальное, если это выбранный,
    /// но не играющий трек — сохранённая точка старта, иначе 0.
    private var progressTime: TimeInterval {
        guard let track = displayedTrack else { return 0 }
        if model.audioEngine.currentTrack?.id == track.id {
            return model.audioEngine.currentTime
        }
        return model.pendingStart(for: track.id)
    }

    // MARK: Информация о треке

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let track = displayedTrack {
                Text(track.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(model.audioEngine.currentTrack?.id == track.id
                         ? model.audioEngine.currentTime.timecode
                         : track.trimStart.timecode)
                    Text("/")
                    Text(track.effectiveDuration.timecode)

                    if model.audioEngine.isTransitioning {
                        Text("· переход…").foregroundStyle(Color.orange)
                    }
                    if track.trimStart > 0 || track.trimEnd != nil {
                        Text("· Start \(track.trimStart.timecode)  End \((track.trimEnd ?? track.duration).timecode)")
                            .foregroundStyle(Color.cyan)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            } else {
                Text("Ничего не выбрано")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Выберите трек в списке")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 80, maxWidth: 340, alignment: .leading)
    }

    // MARK: Эффекты

    private var effectControls: some View {
        HStack(alignment: .top, spacing: 12) {
            // Focus Fade — слева от Crossfade.
            effectBlock(
                title: "Focus Fade",
                isOn: Binding(
                    get: { model.state.settings.focusFadeEnabled },
                    set: { value in model.updateSettings { $0.focusFadeEnabled = value } }
                ),
                help: "Плавно останавливает воспроизведение при переходе в другую программу и плавно возобновляет его при возвращении к плееру"
            ) {
                sliderRow(label: "время",
                          value: model.state.settings.focusFadeDuration,
                          range: 0.2...10,
                          enabled: model.state.settings.focusFadeEnabled) { value in
                    model.updateSettings { $0.focusFadeDuration = value }
                }
            }

            Divider().frame(height: 44)

            effectBlock(
                title: "Crossfade",
                isOn: Binding(
                    get: { model.state.settings.crossfadeEnabled },
                    set: { value in model.updateSettings { $0.crossfadeEnabled = value } }
                ),
                help: "Плавный переход между треками"
            ) {
                sliderRow(label: "переход",
                          value: model.state.settings.crossfadeDuration,
                          range: 0.5...15,
                          enabled: model.state.settings.crossfadeEnabled) { value in
                    model.updateSettings { $0.crossfadeDuration = value }
                }
            }

            Divider().frame(height: 44)

            effectBlock(
                title: "High-cut",
                isOn: Binding(
                    get: { model.state.settings.highCutEnabled },
                    set: { value in model.updateSettings { $0.highCutEnabled = value } }
                ),
                help: "Плавно уводит верхи у играющего трека, затем запускает следующий"
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    sliderRow(label: "эффект",
                              value: model.state.settings.highCutDuration,
                              range: 0.3...10,
                              enabled: model.state.settings.highCutEnabled) { value in
                        model.updateSettings { $0.highCutDuration = value }
                    }

                    sliderRow(label: "пауза",
                              value: model.state.settings.highCutPauseAfter,
                              range: 0...10,
                              enabled: model.state.settings.highCutEnabled) { value in
                        model.updateSettings { $0.highCutPauseAfter = value }
                    }
                }
            }
        }
        // Блоки не сжимаются и не переносятся: размер задан внутри effectBlock.
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    /// Строка регулятора. Размеры фиксированы, текст не переносится:
    /// блоки эффектов должны выглядеть одинаково при любом размере окна.
    private func sliderRow(label: String,
                           value: Double,
                           range: ClosedRange<Double>,
                           enabled: Bool,
                           onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 40, alignment: .leading)

            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
                .frame(width: 62)
                .controlSize(.mini)
                .disabled(!enabled)

            Text(String(format: "%.1f", value))
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 25, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Один блок эффекта: заголовок и регуляторы. Ширина фиксирована, поэтому
    /// при сжатии окна блок не сжимается и название не пропадает.
    private func effectBlock<Content: View>(title: String,
                                            isOn: Binding<Bool>,
                                            help: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help(help)

            content()
        }
        .frame(width: 138, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Панель управления и громкость

    private var transportBar: some View {
        HStack(spacing: 14) {
            // Предыдущий / Играть-пауза / Следующий / Стоп
            HStack(spacing: 8) {
                Button {
                    model.playPrevious()
                } label: {
                    Image(systemName: "backward.fill")
                        .frame(width: 22)
                }
                .help("Предыдущий трек")

                Button {
                    playSelectedOrResume()
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 26)
                }
                .help("Воспроизвести выделенный или возобновить (Пробел)")

                Button {
                    model.audioEngine.pause()
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 26)
                }
                .help("Пауза")
                .disabled(!model.audioEngine.isPlaying)

                Button {
                    model.playNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 22)
                }
                .help("Следующий трек")

                Button {
                    model.audioEngine.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 22)
                }
                .help("Стоп (Esc)")
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 22)

            // Зацикливание трека и плейлиста
            Toggle(isOn: Binding(
                get: { model.state.settings.loopTrackEnabled },
                set: { value in model.updateSettings { $0.loopTrackEnabled = value } }
            )) {
                Image(systemName: "repeat.1")
            }
            .toggleStyle(.button)
            .help("Зациклить текущий трек")

            Toggle(isOn: Binding(
                get: { model.selectedPlaylist?.loopEnabled ?? false },
                set: { model.setLoopPlaylist($0) }
            )) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Зациклить плейлист")

            Toggle(isOn: Binding(
                get: { model.selectedPlaylist?.autoplayEnabled ?? false },
                set: { model.setAutoplay($0) }
            )) {
                Image(systemName: "arrow.forward.to.line")
            }
            .toggleStyle(.button)
            .help("Автоматически переходить к следующему треку")

            Divider().frame(height: 22)

            // Громкость
            HStack(spacing: 6) {
                Image(systemName: volumeIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Slider(value: Binding(
                    get: { model.state.settings.volume },
                    set: { model.setVolume($0) }
                ), in: 0...1)
                .frame(width: 110)
                .controlSize(.small)

                Text("\(Int(model.state.settings.volume * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }

            Spacer()
        }
    }

    /// Запускает выделенный трек, иначе возобновляет текущий или запускает первый.
    private func playSelectedOrResume() {
        if let playlist = model.selectedPlaylist, !model.selection.isEmpty,
           let first = model.selection.selectedTracks(from: playlist.tracks).first {
            model.play(track: first)
            return
        }
        if model.audioEngine.currentTrack != nil {
            model.audioEngine.resume()
        } else {
            model.playFirstTrackOfSelectedPlaylist()
        }
    }

    private var volumeIcon: String {
        let v = model.state.settings.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.4 { return "speaker.fill" }
        if v < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
