import Foundation
import TransCore

/// When the translation stage runs relative to transcription.
enum TranslationTiming: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Transcribe the whole media batch first, then translate all SRTs.
    case afterTranscription
    /// Translate each finished file while the next file is still transcribing.
    case duringTranscription

    var id: String { rawValue }

    var title: String {
        switch self {
        case .afterTranscription: return L.tr("translation.timing.after")
        case .duringTranscription: return L.tr("translation.timing.during")
        }
    }

    var detail: String {
        switch self {
        case .afterTranscription: return L.tr("translation.timing.after.detail")
        case .duringTranscription: return L.tr("translation.timing.during.detail")
        }
    }
}

/// How a translated subtitle is written next to the transcript.
enum TranslationOutputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Target line first, source line below it — AITrans' classic layout.
    case bilingual
    /// Target language only.
    case targetOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bilingual: return L.tr("translation.output.bilingual")
        case .targetOnly: return L.tr("translation.output.target_only")
        }
    }
}

/// Translation half of the pipeline. Persisted as JSON in UserDefaults so new
/// fields can be added without migrating individual keys.
struct TranslationSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool = false
    var backend: Engine = .api
    var targetLanguage: Language = .zh
    var polish: Bool = true
    var outputMode: TranslationOutputMode = .bilingual
    var timing: TranslationTiming = .afterTranscription
    var ollamaModel: String = "qwen2.5"
    var apiWorkers: Int = 20
    var apiRetries: Int = 2
    var ollamaWorkers: Int = 2
    var ollamaRetries: Int = 1

    init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, backend, targetLanguage, polish, outputMode, timing, ollamaModel
        case apiWorkers, apiRetries, ollamaWorkers, ollamaRetries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        backend = try values.decodeIfPresent(Engine.self, forKey: .backend) ?? .api
        targetLanguage = try values.decodeIfPresent(Language.self, forKey: .targetLanguage) ?? .zh
        polish = try values.decodeIfPresent(Bool.self, forKey: .polish) ?? true
        outputMode = try values.decodeIfPresent(TranslationOutputMode.self, forKey: .outputMode) ?? .bilingual
        timing = try values.decodeIfPresent(TranslationTiming.self, forKey: .timing) ?? .afterTranscription
        ollamaModel = try values.decodeIfPresent(String.self, forKey: .ollamaModel) ?? "qwen2.5"
        apiWorkers = try values.decodeIfPresent(Int.self, forKey: .apiWorkers) ?? 20
        apiRetries = try values.decodeIfPresent(Int.self, forKey: .apiRetries) ?? 2
        ollamaWorkers = try values.decodeIfPresent(Int.self, forKey: .ollamaWorkers) ?? 2
        ollamaRetries = try values.decodeIfPresent(Int.self, forKey: .ollamaRetries) ?? 1
        sanitize()
    }

    mutating func sanitize() {
        apiWorkers = min(64, max(1, apiWorkers))
        apiRetries = min(5, max(0, apiRetries))
        ollamaWorkers = min(64, max(1, ollamaWorkers))
        ollamaRetries = min(5, max(0, ollamaRetries))
        if ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ollamaModel = "qwen2.5"
        }
    }

    var workers: Int {
        backend == .api ? apiWorkers : ollamaWorkers
    }

    var retries: Int {
        backend == .api ? apiRetries : ollamaRetries
    }
}

/// Everything a run needs to talk to the translation model. Built once when
/// the batch starts and frozen for the whole run.
struct TranslationContext: Sendable {
    let settings: TranslationSettings
    let client: any ChatCompleting
    let providerName: String
    let modelName: String

    var summary: String {
        switch settings.backend {
        case .api:
            return L.tr("translation.summary.api", providerName, modelName, settings.targetLanguage.displayName)
        case .ollama:
            return L.tr("translation.summary.ollama", modelName, settings.targetLanguage.displayName)
        }
    }
}

enum TranslationError: LocalizedError {
    case noProvider
    case missingAPIKey(String)
    case emptySubtitle(String)
    case noCues(String)
    case allCuesFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProvider:
            return L.tr("translation.error.no_provider")
        case let .missingAPIKey(name):
            return L.tr("translation.error.missing_key", name)
        case let .emptySubtitle(name):
            return L.tr("translation.error.empty_subtitle", name)
        case let .noCues(name):
            return L.tr("translation.error.no_cues", name)
        case let .allCuesFailed(name):
            return L.tr("translation.error.all_cues_failed", name)
        }
    }
}

/// Result of translating one SRT file.
struct SRTTranslationOutcome: Sendable {
    let sourceURL: URL
    let outputURL: URL
    let translatedCount: Int
    let errorCount: Int
    let cueCount: Int
}

/// Translates one whisper-produced SRT into a bilingual or target-only SRT.
struct SRTTranslationService {
    let translator: Translator

    init(client: any ChatCompleting) {
        self.translator = Translator(client: client)
    }

    func translateFile(
        source: URL,
        language: Language,
        outputMode: TranslationOutputMode,
        polish: Bool,
        workers: Int,
        polishWorkers: Int = Spec.defaultPolishWorkers,
        outputDirectory: URL? = nil,
        pauseGate: PauseGate? = nil,
        onProgress: (@Sendable (CueProgress) -> Void)? = nil
    ) async throws -> SRTTranslationOutcome {
        let text = try TextDecoding.decode(contentsOf: source)
        let blocks = SRT.splitBlocks(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.emptySubtitle(source.lastPathComponent)
        }
        let cueCount = blocks.filter(\.isValid).count
        guard cueCount > 0 else {
            throw TranslationError.noCues(source.lastPathComponent)
        }

        let translated = try await translator.translate(
            blocks: blocks,
            language: language,
            workers: workers,
            pauseGate: pauseGate,
            onProgress: onProgress
        )

        var translations = translated.translations
        if polish {
            let polished = try await translator.polish(
                blocks: blocks,
                translations: translations,
                batchSize: Spec.defaultPolishBatchSize,
                workers: polishWorkers,
                pauseGate: pauseGate,
                onProgress: onProgress
            )
            translations = polished.translations
        }

        let successCount = translations.compactMap { $0 }.count
        guard successCount > 0 else {
            throw TranslationError.allCuesFailed(source.lastPathComponent)
        }

        let assembled = Self.assemble(blocks, translations: translations, mode: outputMode)
        let outputURL = Self.outputURL(for: source, language: language, outputDirectory: outputDirectory)
        try assembled.write(to: outputURL, atomically: true, encoding: .utf8)

        return SRTTranslationOutcome(
            sourceURL: source,
            outputURL: outputURL,
            translatedCount: translations.compactMap { $0 }.count,
            errorCount: translated.errorCount,
            cueCount: cueCount
        )
    }

    static func outputURL(for source: URL, language: Language, outputDirectory: URL? = nil) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let directory = outputDirectory ?? source.deletingLastPathComponent()
        return directory.appendingPathComponent("\(stem).\(language.rawValue).srt")
    }

    /// Bilingual keeps the source line under the translation (AITrans layout);
    /// target-only drops it. Invalid blocks always survive verbatim.
    static func assemble(_ blocks: [SRTBlock], translations: [String?], mode: TranslationOutputMode) -> String {
        var output: [String] = []
        output.reserveCapacity(blocks.count)
        for (offset, block) in blocks.enumerated() {
            guard block.isValid, offset < translations.count, let translated = translations[offset] else {
                output.append(block.raw)
                continue
            }
            let cleanTranslation = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanOriginal = block.original.trimmingCharacters(in: .whitespacesAndNewlines)
            switch mode {
            case .bilingual:
                output.append("\(block.index)\n\(block.timeline)\n\(cleanTranslation)\n\(cleanOriginal)")
            case .targetOnly:
                output.append("\(block.index)\n\(block.timeline)\n\(cleanTranslation)")
            }
        }
        return output.joined(separator: Spec.blockSeparator)
    }
}
