import Foundation
import Testing
@testable import Trans2

@Suite
struct ISOAudioDemuxerTests {
    @Test
    func adtsHeaderEncodesLengthAndParameters() {
        let header = [UInt8](ISOAudioDemuxer.adtsHeader(
            frameLength: 500,
            profile: 1,
            sampleRateIndex: 4,
            channelConfig: 2
        ))
        #expect(header.count == 7)
        #expect(header[0] == 0xFF)
        #expect(header[1] == 0xF1)
        // profile 1, sfi 4, channel config 2 -> 0b01_0100_0_0
        #expect(header[2] == 0x50)
        // frame length 507 = 0b0_0001_1111_1011
        #expect(header[3] == 0x80)   // channel config low bits + length[12:11]
        #expect(header[4] == 0x3F)   // length[10:3]
        #expect(header[5] == 0x7F)   // length[2:0] + buffer fullness marker
        #expect(header[6] == 0xFC)
    }

    @Test
    func readsAudioTrackFromGeneratedM4A() async throws {
        let (directory, m4a) = try makeAudioOnlyM4A(seconds: 3)
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = try ISOAudioDemuxer.readTrack(from: m4a)
        #expect(track.codec == "mp4a")
        #expect(track.sampleRate > 0)
        #expect(track.channels > 0)
        #expect(!track.audioSpecificConfig.isEmpty)
        #expect(track.totalSamples > 0)
        #expect(track.chunkOffsets.count > 0)
        #expect(track.chunkLengths.count == track.chunkOffsets.count)
        #expect(track.chunkLengths.reduce(0, +) == track.totalAudioBytes)

        let params = try track.adtsParameters()
        #expect(params.profile <= 3)
        #expect(params.sampleRateIndex != 15)
    }

    @Test
    func extractsADTSAndDecodesToMatchingDuration() async throws {
        let (directory, m4a) = try makeAudioOnlyM4A(seconds: 4)
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = try ISOAudioDemuxer.readTrack(from: m4a)
        let plan = ISOAudioDemuxer.plan(for: track, fileSize: Int64(fileSize(m4a)))
        let adts = directory.appending(path: "out.aac")

        var progress: [Double] = []
        let result = try await ISOAudioDemuxer.extract(
            track: track,
            from: m4a,
            to: adts,
            plan: plan
        ) { fraction in
            progress.append(fraction)
        }

        #expect(result.frames == track.totalSamples)
        #expect(result.audioBytes == track.totalAudioBytes)
        #expect(fileSize(adts) > track.totalAudioBytes)
        #expect(progress.last == 1)

        let wav = directory.appending(path: "out.wav")
        let decode = Process()
        decode.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        decode.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", adts.path, wav.path]
        try decode.run()
        decode.waitUntilExit()
        #expect(decode.terminationStatus == 0)

        let seconds = Double(fileSize(wav) - 44) / 32_000
        #expect(seconds > 3.5 && seconds < 4.6)
    }

    @Test
    func selectiveAndSequentialProduceTheSameAudio() async throws {
        let (directory, m4a) = try makeAudioOnlyM4A(seconds: 3)
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = try ISOAudioDemuxer.readTrack(from: m4a)

        // Force both plans over the same file and compare the ADTS payloads.
        var ranges: [(offset: Int64, end: Int64)] = []
        var index = 0
        while index < track.chunkOffsets.count {
            let start = track.chunkOffsets[index]
            var end = start + Int64(track.chunkLengths[index])
            var next = index + 1
            while next < track.chunkOffsets.count, track.chunkOffsets[next] == end {
                end += Int64(track.chunkLengths[next])
                next += 1
            }
            ranges.append((start, end))
            index = next
        }

        let selectiveFile = directory.appending(path: "selective.aac")
        let sequentialFile = directory.appending(path: "sequential.aac")
        let selective = try await ISOAudioDemuxer.extract(
            track: track,
            from: m4a,
            to: selectiveFile,
            plan: .selective(ranges: ranges, bytes: track.totalAudioBytes)
        )
        let sequential = try await ISOAudioDemuxer.extract(
            track: track,
            from: m4a,
            to: sequentialFile,
            plan: .sequential
        )

        #expect(selective.frames == sequential.frames)
        #expect(selective.frames == track.totalSamples)
        #expect(try Data(contentsOf: selectiveFile) == Data(contentsOf: sequentialFile))
        #expect(selective.bytesRead <= track.totalAudioBytes + 4096)
    }

    @Test
    func rejectsNonISOContainer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trans2-notiso-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try ISOAudioDemuxer.readTrack(from: file)
        }
    }

    @Test
    func planPrefersSelectiveForSparseChunksAndSequentialForDense() {
        // Sparse: 10 chunks of 100 KB spread across a 1 GB file.
        let sparseOffsets = (0..<10).map { Int64($0) * 100_000_000 }
        let sparse = ISOAudioTrack(
            codec: "mp4a",
            sampleRate: 44_100,
            channels: 2,
            audioSpecificConfig: Data([0x12, 0x10]),
            sampleSizes: Array(repeating: 100_000, count: 10),
            chunkOffsets: sparseOffsets,
            chunkSampleCounts: Array(repeating: 1, count: 10),
            chunkLengths: Array(repeating: 100_000, count: 10)
        )
        if case .selective = ISOAudioDemuxer.plan(for: sparse, fileSize: 1_000_000_000) {} else {
            Issue.record("sparse layout should read selectively")
        }

        // Dense: 20k tiny chunks every ~20 KB over a 400 MB file.
        let count = 20_000
        let dense = ISOAudioTrack(
            codec: "mp4a",
            sampleRate: 44_100,
            channels: 2,
            audioSpecificConfig: Data([0x12, 0x10]),
            sampleSizes: Array(repeating: 500, count: count),
            chunkOffsets: (0..<count).map { Int64($0) * 20_000 },
            chunkSampleCounts: Array(repeating: 1, count: count),
            chunkLengths: Array(repeating: 500, count: count)
        )
        if case .sequential = ISOAudioDemuxer.plan(for: dense, fileSize: 400_000_000) {} else {
            Issue.record("dense layout should stream sequentially")
        }
    }

    // MARK: helpers

    private func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }

    private func makeAudioOnlyM4A(seconds: Double) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trans2-iso-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let wav = directory.appending(path: "source.wav")
        let sampleRate = 44_100
        let channels = 2
        let frames = Int(Double(sampleRate) * seconds)
        var samples = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = sin(2 * .pi * 440 * Double(frame) / Double(sampleRate)) * 0.2
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
        try (header + samples).write(to: wav)

        let m4a = directory.appending(path: "source.m4a")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", wav.path, m4a.path]
        try convert.run()
        convert.waitUntilExit()
        guard convert.terminationStatus == 0 else {
            throw ISOAudioError.readFailed("afconvert failed")
        }
        return (directory, m4a)
    }
}

extension ISOAudioDemuxerTests {
    /// Manual benchmark:
    /// TRANS2_DEMUX_BENCH=/path/to/media swift test --filter demuxBenchmark
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANS2_DEMUX_BENCH"] != nil))
    func demuxBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TRANS2_DEMUX_BENCH"])
        let input = URL(fileURLWithPath: path)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trans2-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let parseStarted = Date()
        let track = try ISOAudioDemuxer.readTrack(from: input)
        let plan = ISOAudioDemuxer.plan(for: track, fileSize: Int64(fileSize(input)))
        print(String(
            format: "[demux] parsed in %.2fs: samples=%d audio=%.1fMB chunks=%d plan=%@",
            Date().timeIntervalSince(parseStarted),
            track.totalSamples,
            Double(track.totalAudioBytes) / 1_048_576,
            track.chunkOffsets.count,
            "\(plan)"
        ))

        let adts = directory.appending(path: "out.aac")
        let started = Date()
        let result = try await ISOAudioDemuxer.extract(track: track, from: input, to: adts, plan: plan)
        let extractSeconds = Date().timeIntervalSince(started)

        let wav = directory.appending(path: "out.wav")
        let decodeStarted = Date()
        let decode = Process()
        decode.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        decode.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", adts.path, wav.path]
        try decode.run()
        decode.waitUntilExit()
        let decodeSeconds = Date().timeIntervalSince(decodeStarted)

        let seconds = Double(max(0, fileSize(wav) - 44)) / 32_000
        print(String(
            format: "[demux] plan=%@ read=%.1fMB extract=%.1fs decode=%.1fs total=%.1fs wav=%.1fs exit=%d",
            result.plan,
            Double(result.bytesRead) / 1_048_576,
            extractSeconds,
            decodeSeconds,
            extractSeconds + decodeSeconds,
            seconds,
            decode.terminationStatus
        ))
    }
}
