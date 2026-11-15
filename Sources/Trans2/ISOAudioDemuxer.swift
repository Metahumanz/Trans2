import Foundation

enum ISOAudioError: LocalizedError {
    case notISOContainer
    case noAudioTrack
    case unsupportedCodec(String)
    case unsupportedLayout(String)
    case decodeFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .notISOContainer: return L.tr("audio.error.not_iso")
        case .noAudioTrack: return L.tr("audio.error.no_track", "")
        case let .unsupportedCodec(codec): return L.tr("audio.error.codec", codec)
        case let .unsupportedLayout(reason): return L.tr("audio.error.layout", reason)
        case let .decodeFailed(reason): return L.tr("audio.error.decode", reason)
        case let .readFailed(reason): return L.tr("audio.error.read", reason)
        }
    }
}

/// Audio track description read from an ISO base media file (mp4 / m4v / mov / m4a).
struct ISOAudioTrack: Sendable {
    let codec: String
    let sampleRate: Int
    let channels: Int
    let audioSpecificConfig: Data
    /// Byte size of every access unit, in decode order.
    let sampleSizes: [Int]
    /// Absolute file offset of every chunk.
    let chunkOffsets: [Int64]
    /// Access units per chunk (parallel to `chunkOffsets`).
    let chunkSampleCounts: [Int]
    /// Byte length of every chunk (parallel to `chunkOffsets`).
    let chunkLengths: [Int]

    var totalAudioBytes: Int {
        sampleSizes.reduce(0, +)
    }

    var totalSamples: Int {
        sampleSizes.count
    }

    /// ADTS header fields derived from the AudioSpecificConfig.
    struct ADTSParameters: Sendable {
        let profile: UInt8
        let sampleRateIndex: UInt8
        let channelConfig: UInt8
    }

    func adtsParameters() throws -> ADTSParameters {
        guard audioSpecificConfig.count >= 2 else {
            throw ISOAudioError.unsupportedLayout("missing AudioSpecificConfig")
        }
        let b0 = audioSpecificConfig[audioSpecificConfig.startIndex]
        let b1 = audioSpecificConfig[audioSpecificConfig.startIndex + 1]
        let objectType = (b0 >> 3) & 0x1F
        let sampleRateIndex = UInt8(((b0 & 0x07) << 1) | ((b1 >> 7) & 0x01))
        let channelConfig = (b1 >> 3) & 0x0F

        guard (1...4).contains(objectType) else {
            // HE-AAC (SBR/PS) needs an explicit extension; let AVFoundation handle it.
            throw ISOAudioError.unsupportedLayout("AAC object type \(objectType)")
        }
        guard sampleRateIndex != 15 else {
            throw ISOAudioError.unsupportedLayout("explicit sample rate")
        }
        guard channelConfig != 0 else {
            throw ISOAudioError.unsupportedLayout("channel configuration 0")
        }
        return ADTSParameters(
            profile: objectType - 1,
            sampleRateIndex: sampleRateIndex,
            channelConfig: channelConfig
        )
    }
}

/// Reads only the audio access units of an ISO base media file.
///
/// Files that interleave audio in large runs can be read selectively, which is
/// what makes a 4.8 GB video cost 120 MB of I/O instead of 4.8 GB. Files that
/// interleave tiny audio chunks every few KB (fine-grained muxing) are cheaper
/// to stream sequentially, so the plan is chosen from the actual layout.
enum ISOAudioDemuxer {
    /// Per-read cost assumptions used only to pick a strategy; they are logged
    /// so a surprising choice is visible in the diagnostics.
    private static let assumedReadLatency: Double = 0.004
    private static let assumedThroughput: Double = 12 * 1_048_576
    private static let sequentialWindow: Int64 = 8 * 1_048_576
    private static let coalesceGap: Int64 = 64 * 1024

    enum Plan: Sendable {
        case selective(ranges: [(offset: Int64, end: Int64)], bytes: Int)
        case sequential
    }

    struct Result: Sendable {
        let plan: String
        let bytesRead: Int
        let audioBytes: Int
        let frames: Int
    }

    // MARK: - Parsing

    static func readTrack(from url: URL) throws -> ISOAudioTrack {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        try handle.seek(toFileOffset: 0)

        guard let moov = try locateBox(named: "moov", in: handle, fileSize: fileSize) else {
            throw ISOAudioError.notISOContainer
        }
        let moovData = try read(handle, offset: moov.payloadStart, length: moov.payloadLength)
        return try parseMoov(moovData)
    }

    private struct BoxLocation {
        let payloadStart: Int64
        let payloadLength: Int64
    }

    private static func locateBox(
        named name: String,
        in handle: FileHandle,
        fileSize: Int64
    ) throws -> BoxLocation? {
        var position: Int64 = 0
        while position + 8 <= fileSize {
            let header = try read(handle, offset: position, length: 16)
            guard header.count >= 8 else { return nil }
            var size = Int64(header.be32(0))
            let type = header.ascii(4, 4)
            var headerLength: Int64 = 8
            if size == 1 {
                guard header.count >= 16 else { return nil }
                size = Int64(bitPattern: header.be64(8))
                headerLength = 16
            } else if size == 0 {
                size = fileSize - position
            }
            guard size >= headerLength else { return nil }
            if type == name {
                return BoxLocation(
                    payloadStart: position + headerLength,
                    payloadLength: size - headerLength
                )
            }
            position += size
        }
        return nil
    }

    private static func read(_ handle: FileHandle, offset: Int64, length: Int64) throws -> Data {
        guard length > 0 else { return Data() }
        do {
            try handle.seek(toFileOffset: UInt64(offset))
            return handle.readData(ofLength: Int(length))
        } catch {
            throw ISOAudioError.readFailed(error.localizedDescription)
        }
    }

    private struct Box {
        let type: String
        let payload: Range<Int>
    }

    private static func boxes(in data: Data, range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound {
            let size = Int(data.be32(position))
            guard size >= 8 else { break }
            let type = data.ascii(position + 4, 4) ?? ""
            var headerLength = 8
            var total = size
            if size == 1 {
                guard position + 16 <= range.upperBound else { break }
                total = Int(data.be64(position + 8))
                headerLength = 16
            } else if size == 0 {
                total = range.upperBound - position
            }
            guard total >= headerLength, position + total <= range.upperBound else { break }
            result.append(Box(type: type, payload: (position + headerLength)..<(position + total)))
            position += total
        }
        return result
    }

    private static func parseMoov(_ data: Data) throws -> ISOAudioTrack {
        let root = 0..<data.count
        for trak in boxes(in: data, range: root) where trak.type == "trak" {
            guard let mdia = boxes(in: data, range: trak.payload).first(where: { $0.type == "mdia" }),
                  let hdlr = boxes(in: data, range: mdia.payload).first(where: { $0.type == "hdlr" }),
                  let minf = boxes(in: data, range: mdia.payload).first(where: { $0.type == "minf" }),
                  let stbl = boxes(in: data, range: minf.payload).first(where: { $0.type == "stbl" })
            else { continue }

            // hdlr: version/flags(4) + pre_defined(4) + handler_type(4)
            let handlerStart = hdlr.payload.lowerBound + 8
            guard handlerStart + 4 <= hdlr.payload.upperBound,
                  data.ascii(handlerStart, 4) == "soun"
            else { continue }

            return try parseTrack(data: data, stbl: stbl.payload)
        }
        throw ISOAudioError.noAudioTrack
    }

    private static func parseTrack(data: Data, stbl: Range<Int>) throws -> ISOAudioTrack {
        let children = boxes(in: data, range: stbl)
        func child(_ type: String) -> Box? { children.first { $0.type == type } }

        guard let stsd = child("stsd") else {
            throw ISOAudioError.unsupportedLayout("missing stsd")
        }
        let entry = try parseSampleEntry(data: data, stsd: stsd.payload)

        guard let stsz = child("stsz") else {
            throw ISOAudioError.unsupportedLayout("missing stsz")
        }
        var cursor = stsz.payload.lowerBound + 4
        let uniformSize = Int(data.be32(cursor))
        let sampleCount = Int(data.be32(cursor + 4))
        cursor += 8
        var sampleSizes: [Int] = []
        sampleSizes.reserveCapacity(sampleCount)
        if uniformSize == 0 {
            guard cursor + sampleCount * 4 <= stsz.payload.upperBound else {
                throw ISOAudioError.unsupportedLayout("truncated stsz")
            }
            for index in 0..<sampleCount {
                sampleSizes.append(Int(data.be32(cursor + index * 4)))
            }
        } else {
            sampleSizes = Array(repeating: uniformSize, count: sampleCount)
        }

        guard let stsc = child("stsc") else {
            throw ISOAudioError.unsupportedLayout("missing stsc")
        }
        cursor = stsc.payload.lowerBound + 4
        let stscCount = Int(data.be32(cursor))
        cursor += 4
        var stscEntries: [(firstChunk: Int, samplesPerChunk: Int)] = []
        for index in 0..<stscCount {
            let base = cursor + index * 12
            guard base + 12 <= stsc.payload.upperBound else {
                throw ISOAudioError.unsupportedLayout("truncated stsc")
            }
            stscEntries.append((
                firstChunk: Int(data.be32(base)),
                samplesPerChunk: Int(data.be32(base + 4))
            ))
        }

        var chunkOffsets: [Int64] = []
        if let stco = child("stco") {
            cursor = stco.payload.lowerBound + 4
            let count = Int(data.be32(cursor))
            cursor += 4
            guard cursor + count * 4 <= stco.payload.upperBound else {
                throw ISOAudioError.unsupportedLayout("truncated stco")
            }
            for index in 0..<count {
                chunkOffsets.append(Int64(data.be32(cursor + index * 4)))
            }
        } else if let co64 = child("co64") {
            cursor = co64.payload.lowerBound + 4
            let count = Int(data.be32(cursor))
            cursor += 4
            guard cursor + count * 8 <= co64.payload.upperBound else {
                throw ISOAudioError.unsupportedLayout("truncated co64")
            }
            for index in 0..<count {
                chunkOffsets.append(Int64(bitPattern: data.be64(cursor + index * 8)))
            }
        } else {
            throw ISOAudioError.unsupportedLayout("missing stco/co64")
        }

        // Map chunks to their sample counts, then to byte lengths.
        var chunkSampleCounts: [Int] = []
        chunkSampleCounts.reserveCapacity(chunkOffsets.count)
        var chunkLengths: [Int] = []
        chunkLengths.reserveCapacity(chunkOffsets.count)
        var sampleCursor = 0
        var entryIndex = 0
        for chunk in 1...max(chunkOffsets.count, 1) {
            guard chunkOffsets.count > 0 else { break }
            while entryIndex + 1 < stscEntries.count,
                  stscEntries[entryIndex + 1].firstChunk <= chunk {
                entryIndex += 1
            }
            let perChunk = entryIndex < stscEntries.count ? stscEntries[entryIndex].samplesPerChunk : 1
            var bytes = 0
            for _ in 0..<perChunk {
                guard sampleCursor < sampleSizes.count else { break }
                bytes += sampleSizes[sampleCursor]
                sampleCursor += 1
            }
            chunkSampleCounts.append(perChunk)
            chunkLengths.append(bytes)
            if chunk >= chunkOffsets.count { break }
        }

        return ISOAudioTrack(
            codec: entry.codec,
            sampleRate: entry.sampleRate,
            channels: entry.channels,
            audioSpecificConfig: entry.audioSpecificConfig,
            sampleSizes: sampleSizes,
            chunkOffsets: chunkOffsets,
            chunkSampleCounts: chunkSampleCounts,
            chunkLengths: chunkLengths
        )
    }

    private struct SampleEntry {
        let codec: String
        let sampleRate: Int
        let channels: Int
        let audioSpecificConfig: Data
    }

    private static func parseSampleEntry(data: Data, stsd payload: Range<Int>) throws -> SampleEntry {
        // version/flags(4) + entry_count(4) + first entry
        let start = payload.lowerBound + 8
        guard start + 8 <= payload.upperBound else {
            throw ISOAudioError.unsupportedLayout("empty stsd")
        }
        let entrySize = Int(data.be32(start))
        let codec = data.ascii(start + 4, 4) ?? ""
        guard entrySize >= 16, start + entrySize <= payload.upperBound else {
            throw ISOAudioError.unsupportedLayout("bad stsd entry")
        }
        guard codec == "mp4a" else {
            throw ISOAudioError.unsupportedCodec(codec)
        }

        // AudioSampleEntry payload: reserved(6) + dri(2) + version(2) +
        // revision(2) + vendor(4) + channels(2) + sampleSize(2) +
        // compressionID(2) + packetSize(2) + sampleRate(4), then child boxes.
        var base = start + 8 + 8
        let version = Int(data.be16(base))
        if version == 1 {
            base += 16
        } else if version == 2 {
            throw ISOAudioError.unsupportedLayout("sample entry version 2")
        }
        guard base + 20 <= start + entrySize else {
            throw ISOAudioError.unsupportedLayout("truncated sample entry")
        }
        let channels = Int(data.be16(base + 8))
        let sampleRate = Int(data.be32(base + 16) >> 16)
        let childStart = base + 20

        var asc = Data()
        for box in boxes(in: data, range: childStart..<(start + entrySize)) where box.type == "esds" {
            if let parsed = try? parseESDS(data: data, payload: box.payload) {
                asc = parsed
                break
            }
        }
        guard !asc.isEmpty else {
            throw ISOAudioError.unsupportedLayout("missing esds")
        }
        return SampleEntry(
            codec: codec,
            sampleRate: sampleRate,
            channels: channels,
            audioSpecificConfig: asc
        )
    }

    /// Extracts DecoderSpecificInfo (the AAC AudioSpecificConfig) from esds.
    private static func parseESDS(data: Data, payload: Range<Int>) throws -> Data {
        var cursor = payload.lowerBound + 4 // full box version/flags
        func descriptor() throws -> (tag: Int, body: Range<Int>) {
            guard cursor < payload.upperBound else {
                throw ISOAudioError.unsupportedLayout("truncated esds")
            }
            let tag = Int(data[cursor])
            cursor += 1
            var length = 0
            for _ in 0..<4 {
                guard cursor < payload.upperBound else {
                    throw ISOAudioError.unsupportedLayout("truncated esds length")
                }
                let byte = Int(data[cursor])
                cursor += 1
                length = (length << 7) | (byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            let end = min(cursor + length, payload.upperBound)
            let body = cursor..<end
            cursor = end
            return (tag, body)
        }

        let es = try descriptor()
        guard es.tag == 0x03 else {
            throw ISOAudioError.unsupportedLayout("unexpected esds tag")
        }
        cursor = es.body.lowerBound + 2 // ES_ID
        guard cursor < es.body.upperBound else {
            throw ISOAudioError.unsupportedLayout("truncated esds")
        }
        let flags = Int(data[cursor])
        cursor += 1
        if flags & 0x80 != 0 { cursor += 2 }
        if flags & 0x40 != 0 {
            guard cursor < es.body.upperBound else {
                throw ISOAudioError.unsupportedLayout("truncated esds url")
            }
            cursor += 1 + Int(data[cursor])
        }
        if flags & 0x20 != 0 { cursor += 2 }

        let decoderConfig = try descriptor()
        guard decoderConfig.tag == 0x04 else {
            throw ISOAudioError.unsupportedLayout("missing decoder config")
        }
        cursor = decoderConfig.body.lowerBound + 13
        let dsi = try descriptor()
        guard dsi.tag == 0x05, !dsi.body.isEmpty else {
            throw ISOAudioError.unsupportedLayout("missing decoder specific info")
        }
        return data.subdata(in: dsi.body)
    }

    // MARK: - Planning

    static func plan(for track: ISOAudioTrack, fileSize: Int64) -> Plan {
        var ranges: [(offset: Int64, end: Int64)] = []
        var index = 0
        while index < track.chunkOffsets.count {
            var start = track.chunkOffsets[index]
            var end = start + Int64(track.chunkLengths[index])
            var next = index + 1
            while next < track.chunkOffsets.count,
                  track.chunkOffsets[next] - end <= coalesceGap {
                end = max(end, track.chunkOffsets[next] + Int64(track.chunkLengths[next]))
                next += 1
            }
            ranges.append((start, end))
            index = next
        }

        let selectiveBytes = ranges.reduce(Int64(0)) { $0 + ($1.end - $1.offset) }
        let selectiveCost = Double(ranges.count) * assumedReadLatency
            + Double(selectiveBytes) / assumedThroughput
        let sequentialCost = Double(fileSize) / assumedThroughput

        // Selective reading only wins when it avoids most of the file; the
        // margin also absorbs a slower-than-assumed link.
        if selectiveBytes < fileSize * 6 / 10, selectiveCost < sequentialCost * 0.8 {
            return .selective(ranges: ranges, bytes: Int(selectiveBytes))
        }
        return .sequential
    }

    // MARK: - Extraction

    /// Writes every audio access unit as an ADTS frame, so `afconvert` can turn
    /// it into a 16 kHz mono WAV locally.
    static func extract(
        track: ISOAudioTrack,
        from url: URL,
        to adtsURL: URL,
        plan: Plan,
        onProgress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> Result {
        let params = try track.adtsParameters()
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try? FileManager.default.removeItem(at: adtsURL)
        guard FileManager.default.createFile(atPath: adtsURL.path, contents: nil) else {
            throw ISOAudioError.readFailed("cannot create \(adtsURL.lastPathComponent)")
        }
        let output = try FileHandle(forWritingTo: adtsURL)
        defer { try? output.close() }

        var bytesRead = 0
        var framesWritten = 0
        var sampleCursor = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)

        func appendFrame(_ frame: Data, frameLength: Int) {
            var header = adtsHeader(
                frameLength: frameLength,
                profile: params.profile,
                sampleRateIndex: params.sampleRateIndex,
                channelConfig: params.channelConfig
            )
            header.append(frame)
            buffer.append(header)
            framesWritten += 1
            if buffer.count >= (1 << 20) {
                try? output.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        switch plan {
        case let .selective(ranges, _):
            for range in ranges {
                try Task.checkCancellation()
                let data = try read(handle, offset: range.offset, length: range.end - range.offset)
                bytesRead += data.count
                var chunkIndex = indexOfChunk(atOrAfter: range.offset, in: track)
                while chunkIndex < track.chunkOffsets.count,
                      track.chunkOffsets[chunkIndex] < range.end {
                    let offset = track.chunkOffsets[chunkIndex]
                    let length = track.chunkLengths[chunkIndex]
                    let relative = Int(offset - range.offset)
                    if relative >= 0, relative + length <= data.count {
                        let chunkData = data.subdata(in: relative..<(relative + length))
                        appendChunkSamples(
                            chunkData,
                            chunkIndex: chunkIndex,
                            track: track,
                            sampleCursor: &sampleCursor,
                            append: appendFrame
                        )
                    }
                    chunkIndex += 1
                }
                let total = max(track.totalAudioBytes, 1)
                await onProgress?(min(Double(bytesRead) / Double(total), 0.999))
            }
        case .sequential:
            var windowStart: Int64 = -1
            var window = Data()
            for chunkIndex in track.chunkOffsets.indices {
                try Task.checkCancellation()
                let offset = track.chunkOffsets[chunkIndex]
                let length = track.chunkLengths[chunkIndex]
                let end = offset + Int64(length)
                if windowStart < 0 || offset < windowStart || end > windowStart + Int64(window.count) {
                    let readLength = max(sequentialWindow, Int64(length))
                    window = try read(handle, offset: offset, length: readLength)
                    windowStart = offset
                    bytesRead += window.count
                }
                let relative = Int(offset - windowStart)
                if relative >= 0, relative + length <= window.count {
                    let chunkData = window.subdata(in: relative..<(relative + length))
                    appendChunkSamples(
                        chunkData,
                        chunkIndex: chunkIndex,
                        track: track,
                        sampleCursor: &sampleCursor,
                        append: appendFrame
                    )
                }
                if chunkIndex % 2048 == 0 {
                    let total = max(Double(fileSize), 1)
                    await onProgress?(min(Double(bytesRead) / total, 0.999))
                }
            }
        }

        try output.write(contentsOf: buffer)
        try output.synchronize()
        await onProgress?(1)

        let planName: String
        switch plan {
        case .selective: planName = "selective"
        case .sequential: planName = "sequential"
        }
        return Result(
            plan: planName,
            bytesRead: bytesRead,
            audioBytes: track.totalAudioBytes,
            frames: framesWritten
        )
    }

    private static func indexOfChunk(atOrAfter offset: Int64, in track: ISOAudioTrack) -> Int {
        var low = 0
        var high = track.chunkOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if track.chunkOffsets[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func appendChunkSamples(
        _ chunkData: Data,
        chunkIndex: Int,
        track: ISOAudioTrack,
        sampleCursor: inout Int,
        append: (Data, Int) -> Void
    ) {
        let count = track.chunkSampleCounts[chunkIndex]
        var position = 0
        for _ in 0..<count {
            guard sampleCursor < track.sampleSizes.count else { return }
            let size = track.sampleSizes[sampleCursor]
            guard position + size <= chunkData.count else { return }
            let frame = chunkData.subdata(in: position..<(position + size))
            position += size
            sampleCursor += 1
            append(frame, frame.count)
        }
    }

    /// 7-byte ADTS header without CRC (MPEG-4, one raw data block per frame).
    static func adtsHeader(
        frameLength: Int,
        profile: UInt8,
        sampleRateIndex: UInt8,
        channelConfig: UInt8
    ) -> Data {
        let length = frameLength + 7
        var header = Data(capacity: 7)
        header.append(0xFF)
        header.append(0xF1)
        header.append((profile << 6) | ((sampleRateIndex & 0x0F) << 2) | ((channelConfig >> 2) & 0x01))
        header.append(((channelConfig & 0x03) << 6) | UInt8((length >> 11) & 0x03))
        header.append(UInt8((length >> 3) & 0xFF))
        header.append(UInt8((length & 0x07) << 5) | 0x1F)
        header.append(0xFC)
        return header
    }
}

// MARK: - Byte helpers

private extension Data {
    func be16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return (UInt16(self[startIndex + offset]) << 8) | UInt16(self[startIndex + offset + 1])
    }

    func be32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (UInt32(self[startIndex + offset]) << 24)
            | (UInt32(self[startIndex + offset + 1]) << 16)
            | (UInt32(self[startIndex + offset + 2]) << 8)
            | UInt32(self[startIndex + offset + 3])
    }

    func be64(_ offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(self[startIndex + offset + index])
        }
        return value
    }

    func ascii(_ offset: Int, _ length: Int) -> String? {
        guard offset + length <= count else { return nil }
        let bytes = self[(startIndex + offset)..<(startIndex + offset + length)]
        return String(bytes: bytes, encoding: .isoLatin1)
    }
}
