import AVFoundation
import Foundation

enum AudioExtractionError: LocalizedError {
    case noAudioTrack(String)
    case readerFailed(String)
    case sampleBufferUnavailable

    var errorDescription: String? {
        switch self {
        case let .noAudioTrack(name):
            return L.tr("audio.error.no_track", name)
        case let .readerFailed(reason):
            return L.tr("audio.error.reader_failed", reason)
        case .sampleBufferUnavailable:
            return L.tr("audio.error.sample_buffer")
        }
    }
}

/// Extracts a 16 kHz mono 16-bit PCM WAV for whisper.cpp.
///
/// Uses AVFoundation instead of `afconvert` because afconvert issues many small
/// random reads: on a network volume that collapses to a few MB/s, while the
/// AVAssetReader streams the interleaved file sequentially at link speed.
/// It also yields real progress, which afconvert cannot report.
struct AudioExtractor {
    static let sampleRate: Double = 16_000
    static let channelCount: Int = 1
    static let bitsPerSample: Int = 16

    /// - Parameter onProgress: processed fraction in `0...1` (audio time based).
    func extract(
        input: URL,
        output: URL,
        onProgress: (@Sendable (Double) async -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioExtractionError.noAudioTrack(input.lastPathComponent)
        }

        let duration = try? await asset.load(.duration)
        let totalSeconds = duration.map(CMTimeGetSeconds) ?? 0
        let hasDuration = totalSeconds.isFinite && totalSeconds > 0

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channelCount,
            AVLinearPCMBitDepthKey: Self.bitsPerSample,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outputSettings = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        outputSettings.alwaysCopiesSampleData = false
        guard reader.canAdd(outputSettings) else {
            throw AudioExtractionError.readerFailed("cannot add track output")
        }
        reader.add(outputSettings)
        guard reader.startReading() else {
            throw AudioExtractionError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: output)
        guard fileManager.createFile(atPath: output.path, contents: nil) else {
            throw AudioExtractionError.readerFailed("cannot create \(output.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        // Placeholder header, rewritten with the real sizes when the stream ends.
        try handle.write(contentsOf: Self.wavHeader(dataByteCount: 0))
        var dataByteCount = 0
        var processedSeconds = 0.0

        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sampleBuffer = outputSettings.copyNextSampleBuffer() else { break }
                if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    let length = CMBlockBufferGetDataLength(block)
                    if length > 0 {
                        var data = Data(count: length)
                        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
                            guard let base = raw.baseAddress else { return -1 }
                            return CMBlockBufferCopyDataBytes(
                                block,
                                atOffset: 0,
                                dataLength: length,
                                destination: base
                            )
                        }
                        guard status == kCMBlockBufferNoErr else {
                            throw AudioExtractionError.sampleBufferUnavailable
                        }
                        try handle.write(contentsOf: data)
                        dataByteCount += length
                        processedSeconds += Double(length) / (Self.sampleRate * 2)
                        if hasDuration {
                            let fraction = min(processedSeconds / totalSeconds, 0.999)
                            await onProgress?(fraction)
                        }
                    }
                }
                CMSampleBufferInvalidate(sampleBuffer)
            }
        } catch {
            reader.cancelReading()
            try? handle.close()
            try? fileManager.removeItem(at: output)
            throw error
        }

        guard reader.status == .completed || reader.status == .reading else {
            let reason = reader.error?.localizedDescription ?? "reader status \(reader.status.rawValue)"
            try? fileManager.removeItem(at: output)
            throw AudioExtractionError.readerFailed(reason)
        }
        guard dataByteCount > 0 else {
            try? fileManager.removeItem(at: output)
            throw AudioExtractionError.readerFailed("no audio data")
        }

        // Rewrite the placeholder header in place, then trim to the real size.
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.wavHeader(dataByteCount: dataByteCount))
        try handle.truncate(atOffset: UInt64(44 + dataByteCount))
        try handle.synchronize()
        await onProgress?(1)
    }

    /// Canonical 44-byte RIFF/WAVE header for 16 kHz mono 16-bit PCM.
    static func wavHeader(dataByteCount: Int) -> Data {
        let channels = UInt16(channelCount)
        let sampleRate = UInt32(Self.sampleRate)
        let bits = UInt16(bitsPerSample)
        let blockAlign = UInt16(channelCount * bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(max(0, dataByteCount))

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: le32(36 &+ dataSize))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(contentsOf: le32(16))
        header.append(contentsOf: le16(1))            // PCM
        header.append(contentsOf: le16(channels))
        header.append(contentsOf: le32(sampleRate))
        header.append(contentsOf: le32(byteRate))
        header.append(contentsOf: le16(blockAlign))
        header.append(contentsOf: le16(bits))
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: le32(dataSize))
        return header
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ]
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
        ]
    }
}
