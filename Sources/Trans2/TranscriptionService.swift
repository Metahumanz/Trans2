import Foundation

struct BatchTranscriptionInput: Sendable {
    let inputURL: URL
    let outputDirectory: URL
}

struct TranscriptionService {
    private let audioPreprocessorPath = "/usr/bin/afconvert"

    func transcribeBatch(
        inputs: [BatchTranscriptionInput],
        whisperCLIPath: String,
        modelPath: String,
        formats: Set<OutputFormat>,
        sourceLanguage: String,
        translatesToEnglish: Bool,
        usesTextContext: Bool = false,
        vadSettings: VADSettings = .default,
        onInputStageChange: @escaping @Sendable (Int, TranscriptionStage) async -> Void,
        onInputAudioProgress: (@Sendable (Int, Double) async -> Void)? = nil,
        onStageChange: @escaping @Sendable (TranscriptionStage) async -> Void,
        onLog: @escaping @Sendable (String) async -> Void,
        onTranscriptionProgress: @escaping @Sendable (Double) async -> Void,
        onSegment: (@Sendable (TranscriptSegment) async -> Void)? = nil
    ) async throws -> [TranscriptionReport] {
        guard !inputs.isEmpty else { return [] }

        let startedAt = Date()
        let runLog = try? TranscriptionRunLog()
        if let runLog {
            await onLog(L.tr("log.diagnostic_file", runLog.url.path))
        } else {
            await onLog(L.tr("log.diagnostic_unavailable"))
        }
        await onLog(L.tr("transcription.start_audio_prep"))
        for directory in Set(inputs.map(\.outputDirectory)) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }

        let wavURLs = inputs.map { OutputPaths.temporaryWAVURL(for: $0.inputURL) }
        defer {
            for wavURL in wavURLs {
                try? FileManager.default.removeItem(at: wavURL)
            }
        }

        var audioPreparationCommands: [String] = []
        audioPreparationCommands.reserveCapacity(inputs.count)
        let audioPreparationStartedAt = Date()
        for (index, input) in inputs.enumerated() {
            await onInputStageChange(index, .preparing)
            await onLog(L.tr("transcription.prepare_file", input.inputURL.path))
            await onInputStageChange(index, .extractingAudio)

            let fileStartedAt = Date()
            let command = try await prepareAudio(
                input: input.inputURL,
                wavURL: wavURLs[index],
                runLog: runLog,
                onProgress: { fraction in
                    await onInputAudioProgress?(index, fraction)
                },
                onLog: onLog
            )
            audioPreparationCommands.append(command)
            await onLog(L.tr(
                "transcription.audio_prep_file_finished",
                input.inputURL.lastPathComponent,
                Date().timeIntervalSince(fileStartedAt)
            ))
        }
        await onLog(L.tr("transcription.audio_prep_finished", Date().timeIntervalSince(audioPreparationStartedAt)))

        let outputPrefixes = await Self.uniqueOutputPrefixes(for: inputs, formats: formats) { name in
            await onLog(L.tr("log.output_renamed", name))
        }
        let whisperArguments = WhisperInvocation.arguments(
            modelPath: modelPath,
            wavPaths: wavURLs.map(\.path),
            outputPrefixes: outputPrefixes.map(\.path),
            formats: formats,
            sourceLanguage: sourceLanguage,
            translatesToEnglish: translatesToEnglish,
            usesTextContext: usesTextContext,
            vadSettings: vadSettings
        )

        await onStageChange(.transcribing)
        await onLog(L.tr("transcription.start_whisper"))
        let whisperStartedAt = Date()
        let whisperResult = try await TranscriptionRunLog.run(
            executable: whisperCLIPath,
            arguments: whisperArguments,
            log: runLog,
            onOutput: { stream, line in
                if stream == .stdout, let segment = LiveSegmentParser.parse(line) {
                    await onSegment?(segment)
                }
                guard let filtered = CommandLogFilter.filteredLine(
                    for: stream,
                    tool: .whisper,
                    line: line
                ) else {
                    return
                }
                await onLog("[whisper \(stream.label)] \(filtered)")
                if let progress = parseWhisperProgress(from: line) {
                    await onTranscriptionProgress(progress)
                }
            }
        )
        await onLog(L.tr("transcription.whisper_finished", Date().timeIntervalSince(whisperStartedAt)))
        await onStageChange(.finished)

        var reports: [TranscriptionReport] = []
        reports.reserveCapacity(inputs.count)
        for index in inputs.indices {
            let outputFiles = OutputPaths.outputFiles(prefix: outputPrefixes[index], formats: formats)
            reports.append(TranscriptionReport(
                audioPreparationCommand: audioPreparationCommands[index],
                whisperCommand: whisperResult.command,
                outputFiles: outputFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
            ))
        }
        await onLog(L.tr("transcription.batch_total_time", Date().timeIntervalSince(startedAt)))

        return reports
    }

    static func uniqueOutputPrefixes(
        for inputs: [BatchTranscriptionInput],
        formats: Set<OutputFormat>,
        onBump: @escaping @Sendable (String) async -> Void
    ) async -> [URL] {
        var takenPrefixes: Set<String> = []
        var prefixes: [URL] = []
        prefixes.reserveCapacity(inputs.count)
        for input in inputs {
            let basePrefix = OutputPaths.outputPrefixURL(for: input.inputURL, outputDirectory: input.outputDirectory)
            let prefix = OutputPaths.uniqueOutputPrefix(
                for: input.inputURL,
                outputDirectory: input.outputDirectory,
                formats: formats,
                takenPrefixes: takenPrefixes
            )
            if prefix.lastPathComponent != basePrefix.lastPathComponent {
                await onBump(prefix.lastPathComponent)
            }
            takenPrefixes.insert(prefix.path)
            prefixes.append(prefix)
        }
        return prefixes
    }

    /// AVFoundation streams the interleaved file sequentially and reports
    /// progress; afconvert stays as a fallback for containers it rejects.
    private func prepareAudio(
        input: URL,
        wavURL: URL,
        runLog: TranscriptionRunLog?,
        onProgress: @escaping @Sendable (Double) async -> Void,
        onLog: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let isNetworkVolume = (try? input.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
        if isNetworkVolume {
            await onLog(L.tr("transcription.network_volume", input.deletingLastPathComponent().path))
        }

        do {
            try await AudioExtractor().extract(input: input, output: wavURL, onProgress: onProgress)
            let description = "AVFoundation extract \(input.path) -> \(wavURL.path)"
            await runLog?.append("\(Date().ISO8601Format()) command: \(description)")
            return description
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await onLog(L.tr("transcription.av_fallback", error.localizedDescription))
        }

        let arguments = [
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            input.path,
            wavURL.path,
        ]
        let result = try await TranscriptionRunLog.run(
            executable: audioPreprocessorPath,
            arguments: arguments,
            log: runLog,
            onOutput: { stream, line in
                guard let filtered = CommandLogFilter.filteredLine(for: stream, tool: .audioPreprocessor, line: line) else {
                    return
                }
                await onLog("[afconvert \(stream.label)] \(filtered)")
            }
        )
        await onProgress(1)
        return result.command
    }

    private func parseWhisperProgress(from line: String) -> Double? {
        guard let range = line.range(of: #"progress =\s*([0-9]{1,3})%"#, options: .regularExpression) else {
            return nil
        }

        let match = String(line[range])
        let percentText = match
            .replacingOccurrences(of: "progress =", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let percent = Double(percentText) else {
            return nil
        }

        return min(max(percent / 100.0, 0), 1)
    }
}
