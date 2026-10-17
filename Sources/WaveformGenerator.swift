import Foundation
import AVFoundation
import Accelerate

/// Считает пики для отрисовки waveform и отдаёт длительность файла.
/// Работает в фоне, вызывается через async/await.
///
/// Три вещи, от которых зависит скорость и стабильность:
///  1. расчёты идут на одной последовательной очереди — параллельные чтения
///     нескольких файлов только конкурируют за диск;
///  2. устаревший запрос прерывается на ближайшем блоке: если пользователь уже
///     выбрал другой трек, дочитывать предыдущий файл незачем;
///  3. пик считается по блоку через vDSP, а не по каждому кадру.
enum WaveformGenerator {

    struct WaveformData {
        var peaks: [Float] = []
        var duration: TimeInterval = 0
        /// true, если расчёт прерван как устаревший (результат неполный).
        var isCancelled = false
    }

    static let targetPeakCount = 900

    /// Последовательная очередь: одновременно считается не больше одного файла.
    private static let queue = DispatchQueue(label: "WaveformGenerator.queue", qos: .utility)

    /// ID запроса, который нужен прямо сейчас. Всё остальное считается устаревшим.
    private static let lock = NSLock()
    private static var currentRequestID: UUID?

    /// Объявляет запрос актуальным, отменяя предыдущие.
    static func makeCurrent(_ requestID: UUID) {
        lock.lock()
        currentRequestID = requestID
        lock.unlock()
    }

    private static func isStale(_ requestID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentRequestID != requestID
    }

    /// Полный расчёт пиков. `requestID` — кто запросил; при смене запроса
    /// расчёт прекращается и возвращается пустой результат.
    static func load(for track: Track, requestID: UUID) async -> WaveformData {
        makeCurrent(requestID)
        let path = track.path
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: compute(path: path, requestID: requestID))
            }
        }
    }

    /// Только длительность. Заголовок файла читается без разбора всех сэмплов,
    /// поэтому для сотни добавленных файлов это мгновенно.
    static func duration(of track: Track) async -> TimeInterval {
        let path = track.path
        return await withCheckedContinuation { continuation in
            queue.async {
                let url = URL(fileURLWithPath: path)
                guard let file = try? AVAudioFile(forReading: url) else {
                    continuation.resume(returning: 0)
                    return
                }
                let rate = file.processingFormat.sampleRate
                guard file.length > 0, rate > 0 else {
                    continuation.resume(returning: 0)
                    return
                }
                continuation.resume(returning: Double(file.length) / rate)
            }
        }
    }

    /// Сколько кадров максимум декодируем. Для часового файла это примерно
    /// три минуты звука вместо часа, поэтому время расчёта перестаёт зависеть
    /// от длительности трека.
    private static let maxFramesToDecode: Int64 = 8_000_000
    /// На сколько окон разбивается файл при выборочном чтении.
    private static let sampleWindowCount = 128

    private static func compute(path: String, requestID: UUID) -> WaveformData {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            return WaveformData()
        }

        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, format.sampleRate > 0, format.channelCount > 0 else {
            return WaveformData()
        }

        let duration = Double(totalFrames) / format.sampleRate

        // Короткий файл читается целиком: это и быстро, и точно.
        // Длинный — выборочно, окнами по всей длине.
        if totalFrames <= maxFramesToDecode {
            return readFully(file: file, format: format,
                             totalFrames: totalFrames, duration: duration,
                             requestID: requestID)
        }
        return readSampled(file: file, format: format,
                           totalFrames: totalFrames, duration: duration,
                           requestID: requestID)
    }

    /// Точный расчёт: файл читается последовательно целиком (для коротких треков).
    private static func readFully(file: AVAudioFile,
                                  format: AVAudioFormat,
                                  totalFrames: AVAudioFramePosition,
                                  duration: TimeInterval,
                                  requestID: UUID) -> WaveformData {
        let framesPerPeak = max(1, Int(totalFrames) / targetPeakCount)
        let bufferSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
            return WaveformData(peaks: [], duration: duration)
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(targetPeakCount + 2)

        var framesInCurrentPeak = 0
        var currentPeak: Float = 0
        var remaining = totalFrames

        while remaining > 0 {
            if isStale(requestID) { return WaveformData(isCancelled: true) }

            let toRead = AVAudioFrameCount(min(Int64(bufferSize), remaining))
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                break
            }

            let framesRead = Int(buffer.frameLength)
            if framesRead == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            accumulate(channels: channels,
                       channelCount: Int(format.channelCount),
                       frames: framesRead,
                       framesPerPeak: framesPerPeak,
                       peaks: &peaks,
                       framesInCurrentPeak: &framesInCurrentPeak,
                       currentPeak: &currentPeak)

            remaining -= Int64(framesRead)
        }

        if framesInCurrentPeak > 0 {
            peaks.append(currentPeak)
        }

        return WaveformData(peaks: normalised(peaks), duration: duration)
    }

    /// Быстрый расчёт для длинных файлов: читаются окна, равномерно
    /// распределённые по всему треку. Форма волны сохраняется, а время
    /// работы ограничено независимо от длительности.
    private static func readSampled(file: AVAudioFile,
                                    format: AVAudioFormat,
                                    totalFrames: AVAudioFramePosition,
                                    duration: TimeInterval,
                                    requestID: UUID) -> WaveformData {
        let windowFrames = AVAudioFrameCount(maxFramesToDecode / Int64(sampleWindowCount))
        let stride = totalFrames / Int64(sampleWindowCount)

        // Каждое окно даёт свою долю пиков — в сумме около targetPeakCount.
        let peaksPerWindow = max(1, targetPeakCount / sampleWindowCount)
        let framesPerPeak = max(1, Int(windowFrames) / peaksPerWindow)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return WaveformData(peaks: [], duration: duration)
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(targetPeakCount + sampleWindowCount)

        for window in 0..<sampleWindowCount {
            if isStale(requestID) { return WaveformData(isCancelled: true) }

            let position = Int64(window) * stride
            if position >= totalFrames { break }

            file.framePosition = position
            let toRead = AVAudioFrameCount(min(Int64(windowFrames), totalFrames - position))

            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                break
            }

            let framesRead = Int(buffer.frameLength)
            if framesRead == 0 { continue }
            guard let channels = buffer.floatChannelData else { break }

            var framesInCurrentPeak = 0
            var currentPeak: Float = 0
            accumulate(channels: channels,
                       channelCount: Int(format.channelCount),
                       frames: framesRead,
                       framesPerPeak: framesPerPeak,
                       peaks: &peaks,
                       framesInCurrentPeak: &framesInCurrentPeak,
                       currentPeak: &currentPeak)
            if framesInCurrentPeak > 0 {
                peaks.append(currentPeak)
            }
        }

        return WaveformData(peaks: normalised(peaks), duration: duration)
    }

    /// Считает пики по прочитанному блоку. Пик берётся через vDSP по целому
    /// отрезку, а не по каждому кадру.
    private static func accumulate(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                                   channelCount: Int,
                                   frames: Int,
                                   framesPerPeak: Int,
                                   peaks: inout [Float],
                                   framesInCurrentPeak: inout Int,
                                   currentPeak: inout Float) {
        var offset = 0
        while offset < frames {
            let take = min(framesPerPeak - framesInCurrentPeak, frames - offset)
            var blockPeak: Float = 0

            for channel in 0..<channelCount {
                var channelPeak: Float = 0
                vDSP_maxmgv(channels[channel] + offset, 1, &channelPeak, vDSP_Length(take))
                blockPeak = max(blockPeak, channelPeak)
            }

            currentPeak = max(currentPeak, blockPeak)
            framesInCurrentPeak += take
            offset += take

            if framesInCurrentPeak >= framesPerPeak {
                peaks.append(currentPeak)
                currentPeak = 0
                framesInCurrentPeak = 0
            }
        }
    }

    /// Нормализация: тихие треки должны читаться на графике так же, как громкие.
    private static func normalised(_ peaks: [Float]) -> [Float] {
        guard let maxPeak = peaks.max(), maxPeak > 0.0001 else { return peaks }
        var result = peaks
        var scale = 1 / maxPeak
        vDSP_vsmul(result, 1, &scale, &result, 1, vDSP_Length(result.count))
        for index in result.indices where result[index] > 1 {
            result[index] = 1
        }
        return result
    }
}
