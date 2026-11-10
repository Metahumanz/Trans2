import Foundation
import Testing
import TransCore
@testable import Trans2

/// Drives the real AppModel pipeline (queue → whisper → translation → result)
/// without the UI. Opt in with `TRANS2_E2E=1`; needs the local mock server on
/// 127.0.0.1:8765 and a whisper model on disk.
@Suite(.serialized)
@MainActor
struct AppModelPipelineTests {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANS2_E2E"] == "1"))
    func queueRunsTranscriptionThenTranslationAndPublishesPreview() async throws {
        let whisperCLI = environment["TRANS2_E2E_WHISPER"]
            ?? "\(NSHomeDirectory())/Library/Application Support/WhisperMac/custom-runtime/bin/whisper-cli"
        let modelPath = environment["TRANS2_E2E_MODEL"]
            ?? "\(NSHomeDirectory())/Library/Application Support/WhisperMac/runtime/Models/ggml-large-v3-turbo.bin"
        let apiBase = environment["TRANS2_E2E_API"] ?? "http://127.0.0.1:8765/v1"

        let root = FileManager.default.temporaryDirectory
            .appending(path: "trans2-appmodel-\(UUID().uuidString)", directoryHint: .isDirectory)
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "trans2-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var translation = TranslationSettings()
        translation.isEnabled = true
        translation.backend = .api
        translation.targetLanguage = .zh
        translation.polish = false
        translation.outputMode = .bilingual
        defaults.set(whisperCLI, forKey: "whisperCLIPath")
        defaults.set(modelPath, forKey: "modelPath")
        defaults.set(root.path, forKey: "outputDirectoryPath")
        defaults.set(["srt"], forKey: "outputFormats")
        defaults.set(try JSONEncoder().encode(translation), forKey: "translationSettings")

        let secrets = MemorySecretStore()
        let store = ProviderStore(secrets: secrets)
        _ = try store.upsert(
            Provider(
                id: "mock",
                name: "Mock",
                baseURL: apiBase,
                model: "mock",
                apiKey: "test-key",
                requiresKey: true
            ),
            activate: true
        )
        try store.save(to: support.appending(path: "providers.json"))

        let model = AppModel(
            completionNotifier: CompletionNotifier(isEligibleForNotifications: { false }),
            defaults: defaults,
            providerStore: store,
            supportDirectory: support
        )
        #expect(model.activeProviderID == "mock")
        #expect(model.translationModelName == "mock")
        #expect(model.canStart == false) // empty queue

        let audio = root.appending(path: "speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "--data-format=LEI16@16000", "Hello world. This is a test of the transcription and translation pipeline."]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        model.addMediaURLs([audio])
        await model.waitForMediaScan()
        #expect(model.inputFiles.count == 1)
        #expect(model.canStart)

        model.startTranscription()
        for _ in 0..<240 {
            if !model.isRunning, model.lastOutcome != nil { break }
            try await Task.sleep(for: .seconds(1))
        }

        guard case let .succeeded(_, outputs)? = model.lastOutcome else {
            Issue.record("run did not succeed: \(String(describing: model.lastOutcome)); logs=\(model.logsText)")
            return
        }
        let translated = try #require(outputs.first { $0.lastPathComponent.hasSuffix(".zh.srt") })
        let text = try String(contentsOf: translated, encoding: .utf8)
        #expect(text.contains("你好"))
        #expect(text.lowercased().contains("hello"))
        #expect(model.previewFiles.contains { $0.url == translated })
        #expect(model.lastTranslationCount >= 1)
        #expect(model.lastTranslationFailureCount == 0)
    }
}

extension AppModelPipelineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANS2_E2E"] == "1"))
    func subtitleOnlyQueueSkipsWhisperAndWritesToOutputDirectory() async throws {
        let apiBase = ProcessInfo.processInfo.environment["TRANS2_E2E_API"] ?? "http://127.0.0.1:8765/v1"
        let root = FileManager.default.temporaryDirectory
            .appending(path: "trans2-srt-\(UUID().uuidString)", directoryHint: .isDirectory)
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let output = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "trans2-srt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var translation = TranslationSettings()
        translation.isEnabled = true
        translation.backend = .api
        translation.targetLanguage = .zh
        translation.polish = false
        translation.outputMode = .bilingual
        defaults.set(output.path, forKey: "outputDirectoryPath")
        defaults.set(try JSONEncoder().encode(translation), forKey: "translationSettings")

        let store = ProviderStore(secrets: MemorySecretStore())
        _ = try store.upsert(
            Provider(id: "mock", name: "Mock", baseURL: apiBase, model: "mock", apiKey: "k"),
            activate: true
        )
        try store.save(to: support.appending(path: "providers.json"))

        let model = AppModel(
            completionNotifier: CompletionNotifier(isEligibleForNotifications: { false }),
            defaults: defaults,
            providerStore: store,
            supportDirectory: support
        )

        let source = root.appending(path: "existing.srt")
        try """
        1
        00:00:01,000 --> 00:00:02,000
        Existing subtitle

        """.write(to: source, atomically: true, encoding: .utf8)

        model.addMediaURLs([source])
        await model.waitForMediaScan()
        #expect(model.inputFiles.count == 1)
        #expect(model.canStart) // no whisper CLI/model required

        model.startTranscription()
        for _ in 0..<120 {
            if !model.isRunning, model.lastOutcome != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        guard case .succeeded = model.lastOutcome else {
            Issue.record("SRT-only run failed: \(String(describing: model.lastOutcome)); \(model.logsText)")
            return
        }
        let translated = output.appending(path: "existing.zh.srt")
        #expect(FileManager.default.fileExists(atPath: translated.path))
        let text = try String(contentsOf: translated, encoding: .utf8)
        #expect(text.contains("译：Existing subtitle"))
        #expect(text.contains("Existing subtitle"))
    }
}
