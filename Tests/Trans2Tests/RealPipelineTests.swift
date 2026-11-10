import Foundation
import Testing
import TransCore
@testable import Trans2

/// Opt-in end-to-end check: real `afconvert` + bundled whisper-cli + the
/// translation stage against a local OpenAI-compatible mock. Enable with
/// `TRANS2_E2E=1 swift test --filter RealPipelineTests`.
@Suite(.serialized)
struct RealPipelineTests {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANS2_E2E"] == "1"))
    func whisperProducesSRTAndTranslationProducesBilingualFile() async throws {
        let whisperCLI = environment["TRANS2_E2E_WHISPER"]
            ?? "\(NSHomeDirectory())/Library/Application Support/WhisperMac/custom-runtime/bin/whisper-cli"
        let modelPath = environment["TRANS2_E2E_MODEL"]
            ?? "\(NSHomeDirectory())/Library/Application Support/WhisperMac/runtime/Models/ggml-large-v3-turbo.bin"
        let apiBase = environment["TRANS2_E2E_API"] ?? "http://127.0.0.1:8765/v1"

        #expect(FileManager.default.isExecutableFile(atPath: whisperCLI))
        #expect(FileManager.default.fileExists(atPath: modelPath))

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trans2-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 1. Generate real speech so afconvert + whisper-cli do actual work.
        let audio = directory.appending(path: "speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", audio.path,
            "--data-format=LEI16@16000",
            "Hello world. This is a test of the transcription and translation pipeline.",
        ]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        // 2. Transcribe exactly the way AppModel does.
        let input = BatchTranscriptionInput(inputURL: audio, outputDirectory: directory)
        let reports = try await TranscriptionService().transcribeBatch(
            inputs: [input],
            whisperCLIPath: whisperCLI,
            modelPath: modelPath,
            formats: [.srt],
            sourceLanguage: "en",
            translatesToEnglish: false,
            usesTextContext: false,
            vadSettings: .default,
            onInputStageChange: { _, _ in },
            onStageChange: { _ in },
            onLog: { _ in },
            onTranscriptionProgress: { _ in }
        )

        let srt = try #require(
            reports.first?.outputFiles.first { $0.pathExtension.lowercased() == "srt" }
        )
        let transcript = try String(contentsOf: srt, encoding: .utf8)
        #expect(transcript.lowercased().contains("hello"))

        // 3. Translate through the real HTTP client and the shared service.
        let client = ChatClient(
            baseURL: apiBase,
            apiKey: "test-key",
            model: "mock",
            policy: RetryPolicy(retries: 0)
        )
        let outcome = try await SRTTranslationService(client: client).translateFile(
            source: srt,
            language: .zh,
            outputMode: .bilingual,
            polish: false,
            workers: 2
        )

        let bilingual = try String(contentsOf: outcome.outputURL, encoding: .utf8)
        #expect(outcome.outputURL.lastPathComponent.hasSuffix(".zh.srt"))
        #expect(bilingual.contains("你好"))
        #expect(bilingual.lowercased().contains("hello"))
        #expect(outcome.cueCount >= 1)
    }
}
