import Foundation
import Testing
import TransCore
@testable import Trans2

private struct PrefixTranslator: ChatCompleting {
    func complete(messages: [ChatMessage]) async throws -> String {
        let text = messages.last?.content ?? ""
        return "译：" + text
    }
}

@Suite
struct TranslationPipelineTests {
    private let sampleSRT = """
    1
    00:00:01,000 --> 00:00:02,000
    Hello

    2
    00:00:03,000 --> 00:00:04,000
    World
    """

    @Test
    func bilingualAssemblyKeepsSourceUnderTranslation() {
        let blocks = SRT.splitBlocks(sampleSRT)
        let text = SRTTranslationService.assemble(
            blocks,
            translations: ["你好", "世界"],
            mode: .bilingual
        )
        #expect(text.contains("你好\nHello"))
        #expect(text.contains("世界\nWorld"))
    }

    @Test
    func targetOnlyAssemblyDropsSource() {
        let blocks = SRT.splitBlocks(sampleSRT)
        let text = SRTTranslationService.assemble(
            blocks,
            translations: ["你好", "世界"],
            mode: .targetOnly
        )
        #expect(text.contains("你好"))
        #expect(!text.contains("Hello"))
    }

    @Test
    func missingTranslationFallsBackToRawBlock() {
        let blocks = SRT.splitBlocks(sampleSRT)
        let text = SRTTranslationService.assemble(
            blocks,
            translations: [nil, "世界"],
            mode: .targetOnly
        )
        #expect(text.contains("Hello"))
        #expect(text.contains("世界"))
    }

    @Test
    func translatedOutputSitsNextToSourceWithLanguageCode() {
        let source = URL(fileURLWithPath: "/tmp/movie.srt")
        #expect(
            SRTTranslationService.outputURL(for: source, language: .zh).path
                == "/tmp/movie.zh.srt"
        )
        #expect(
            SRTTranslationService.outputURL(for: source, language: .ja).path
                == "/tmp/movie.ja.srt"
        )
    }

    @Test
    func serviceWritesBilingualFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trans2-translation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "clip.srt")
        try sampleSRT.write(to: source, atomically: true, encoding: .utf8)

        let service = SRTTranslationService(client: PrefixTranslator())
        let outcome = try await service.translateFile(
            source: source,
            language: .zh,
            outputMode: .bilingual,
            polish: false,
            workers: 2
        )

        #expect(outcome.outputURL.lastPathComponent == "clip.zh.srt")
        #expect(outcome.cueCount == 2)
        let text = try String(contentsOf: outcome.outputURL, encoding: .utf8)
        #expect(text.contains("译：Hello"))
        #expect(text.contains("译：World"))
        #expect(text.contains("Hello"))
    }

    @Test
    func settingsDecodeOldBlobWithDefaults() throws {
        let data = Data(#"{"isEnabled":true,"backend":"ollama"}"#.utf8)
        let decoded = try JSONDecoder().decode(TranslationSettings.self, from: data)
        #expect(decoded.isEnabled)
        #expect(decoded.backend == .ollama)
        #expect(decoded.targetLanguage == .zh)
        #expect(decoded.outputMode == .bilingual)
        #expect(decoded.ollamaModel == "qwen2.5")
    }

    @Test
    func settingsClampWorkerAndRetryRanges() {
        var settings = TranslationSettings()
        settings.apiWorkers = 0
        settings.apiRetries = 99
        settings.ollamaModel = "   "
        settings.sanitize()
        #expect(settings.apiWorkers == 1)
        #expect(settings.apiRetries == 5)
        #expect(settings.ollamaModel == "qwen2.5")
    }
}

@Test
func settingsDecodeTranslationTiming() throws {
    let data = Data(#"{"isEnabled":true,"timing":"duringTranscription"}"#.utf8)
    let decoded = try JSONDecoder().decode(TranslationSettings.self, from: data)
    #expect(decoded.timing == .duringTranscription)
}
