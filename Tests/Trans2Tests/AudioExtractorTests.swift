import AVFoundation
import Foundation
import Testing
@testable import Trans2

@Suite
struct AudioExtractorTests {
    @Test
    func wavHeaderDescribesPCMFormat() {
        let header = AudioExtractor.wavHeader(dataByteCount: 3200)
        #expect(header.count == 44)
        #expect(String(decoding: header[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: header[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: header[36..<40], as: UTF8.self) == "data")

        func uint32(at offset: Int) -> UInt32 {
            header[offset..<(offset + 4)].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func uint16(at offset: Int) -> UInt16 {
            header[offset..<(offset + 2)].reversed().reduce(0) { ($0 << 8) | UInt16($1) }
        }

        #expect(uint32(at: 4) == 36 + 3200)
        #expect(uint16(at: 20) == 1)          // PCM
        #expect(uint16(at: 22) == 1)          // mono
        #expect(uint32(at: 24) == 16_000)     // sample rate
        #expect(uint32(at: 28) == 32_000)     // byte rate
        #expect(uint16(at: 32) == 2)          // block align
        #expect(uint16(at: 34) == 16)         // bits
        #expect(uint32(at: 40) == 3200)
    }

    @Test
    func extractsSixteenKilohertzMonoPCM() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trans2-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 2 seconds of 44.1 kHz stereo PCM, converted to AAC so the extractor
        // has to demux and resample like it does for real media.
        let sourceWAV = directory.appending(path: "source.wav")
        try Self.writeTone(to: sourceWAV, sampleRate: 44_100, channels: 2, seconds: 2)
        let sourceAAC = directory.appending(path: "source.m4a")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", sourceWAV.path, sourceAAC.path]
        try convert.run()
        convert.waitUntilExit()
        #expect(convert.terminationStatus == 0)

        let output = directory.appending(path: "out.wav")
        var progress: [Double] = []
        try await AudioExtractor().extract(input: sourceAAC, output: output) { fraction in
            progress.append(fraction)
        }

        let data = try Data(contentsOf: output)
        #expect(data.count > 44)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        let dataSize = data[40..<44].reversed().reduce(0) { ($0 << 8) | Int($1) }
        #expect(dataSize == data.count - 44)

        let sampleRate = data[24..<28].reversed().reduce(0) { ($0 << 8) | Int($1) }
        let channels = data[22..<24].reversed().reduce(0) { ($0 << 8) | Int($1) }
        let bits = data[34..<36].reversed().reduce(0) { ($0 << 8) | Int($1) }
        #expect(sampleRate == 16_000)
        #expect(channels == 1)
        #expect(bits == 16)

        // ~2s of audio at 16 kHz mono 16-bit, allowing for AAC priming.
        let seconds = Double(dataSize) / 32_000
        #expect(seconds > 1.8 && seconds < 2.4)
        #expect(progress.contains { $0 > 0 && $0 < 1 })
        #expect(progress.last == 1)
    }

    @Test
    func missingAudioTrackThrows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trans2-noaudio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = directory.appending(path: "empty.txt")
        try "not audio".write(to: empty, atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            try await AudioExtractor().extract(input: empty, output: directory.appending(path: "o.wav"))
        }
    }

    private static func writeTone(to url: URL, sampleRate: Int, channels: Int, seconds: Double) throws {
        let frameCount = Int(Double(sampleRate) * seconds)
        var samples = Data(capacity: frameCount * channels * 2)
        for frame in 0..<frameCount {
            let value = sin(2 * .pi * 440 * Double(frame) / Double(sampleRate)) * 0.25
            let int16 = Int16(value * Double(Int16.max))
            for _ in 0..<channels {
                var little = int16.littleEndian
                Swift.withUnsafeBytes(of: &little) { samples.append(contentsOf: $0) }
            }
        }

        var header = Data()
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + samples.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * channels * 2))
        append16(UInt16(channels * 2))
        append16(16)
        header.append(contentsOf: Array("data".utf8))
        append32(UInt32(samples.count))

        try (header + samples).write(to: url)
    }
}

extension AudioExtractorTests {
    /// Manual benchmark: TRANS2_AUDIO_BENCH=/path/to/media swift test --filter audioExtractionBenchmark
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANS2_AUDIO_BENCH"] != nil))
    func audioExtractionBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TRANS2_AUDIO_BENCH"])
        let input = URL(fileURLWithPath: path)
        let output = FileManager.default.temporaryDirectory.appending(path: "bench-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }

        let started = Date()
        var lastReport = Date()
        try await AudioExtractor().extract(input: input, output: output) { fraction in
            let now = Date()
            if now.timeIntervalSince(lastReport) > 15 || fraction >= 1 {
                lastReport = now
                print(String(format: "[bench] %.0f%% after %.1fs", fraction * 100, now.timeIntervalSince(started)))
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        print(String(format: "[bench] done: %d bytes in %.1fs", size ?? 0, elapsed))
    }
}
