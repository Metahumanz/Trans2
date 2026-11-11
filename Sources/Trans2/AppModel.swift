import AppKit
import Combine
import Foundation
import TransCore

@MainActor
final class AppModel: ObservableObject {
    @Published var inputFiles: [URL]
    @Published var appLanguage: AppLanguage {
        didSet {
            L.setAppLanguage(appLanguage)
            refreshLocalizedContent()
        }
    }
    @Published var outputDirectoryPath: String {
        didSet { store(outputDirectoryPath, forKey: Keys.outputDirectoryPath) }
    }
    @Published var whisperCLIPath: String {
        didSet {
            store(whisperCLIPath, forKey: Keys.whisperCLIPath)
            refreshVADCLICapability()
        }
    }
    @Published var modelPath: String {
        didSet { store(modelPath, forKey: Keys.modelPath) }
    }
    @Published var accelerationMode: AccelerationMode {
        didSet { store(accelerationMode.rawValue, forKey: Keys.accelerationMode) }
    }
    @Published var outputFormats: Set<OutputFormat> {
        didSet { store(Array(outputFormats).map(\.rawValue).sorted(), forKey: Keys.outputFormats) }
    }
    @Published var sourceLanguage: String {
        didSet { store(sourceLanguage, forKey: Keys.sourceLanguage) }
    }
    @Published var translatesToEnglish: Bool {
        didSet { store(translatesToEnglish, forKey: Keys.translatesToEnglish) }
    }
    @Published var usesTextContext: Bool {
        didSet { store(usesTextContext, forKey: Keys.usesTextContext) }
    }
    @Published var vadSettings: VADSettings {
        didSet {
            if let data = try? JSONEncoder().encode(vadSettings) {
                defaults.set(data, forKey: Keys.vadSettings)
            }
            if vadSettings.isEnabled { refreshVADCLICapability() }
        }
    }
    @Published var huggingFaceDownloadSource: HuggingFaceDownloadSource {
        didSet { store(huggingFaceDownloadSource.rawValue, forKey: Keys.huggingFaceDownloadSource) }
    }
    @Published var customHuggingFaceEndpoint: String {
        didSet {
            if HuggingFaceEndpoint.sanitizedBaseURL(from: customHuggingFaceEndpoint) != nil {
                defaults.set(customHuggingFaceEndpoint, forKey: Keys.customHuggingFaceEndpoint)
            }
        }
    }
    /// Translation half of the pipeline. Stored as one JSON blob so future
    /// fields decode with defaults instead of invalidating the whole setting.
    @Published var translationSettings: TranslationSettings {
        didSet {
            if let data = try? JSONEncoder().encode(translationSettings) {
                defaults.set(data, forKey: Keys.translationSettings)
            }
        }
    }
    @Published var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }
    @Published var githubUpdateToken: String {
        didSet { persistUpdateToken() }
    }
    @Published private(set) var updateInfo: UpdateInfo?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var updateStatusText = ""
    @Published private(set) var downloadedUpdate: URL?
    @Published private(set) var providers: [Provider] = []
    @Published private(set) var activeProviderID: String?
    @Published private(set) var lastTranslationCount = 0
    @Published private(set) var lastTranslationFailureCount = 0
    @Published private(set) var pipelinedTranslatedFiles = 0
    @Published private(set) var lastRunTranslationWasEnabled = false
    @Published private(set) var lastRunTranslationTarget: Language = .zh
    @Published var logs: [String]
    @Published var isRunning = false
    @Published var isCancelling = false
    @Published var statusText = ""
    @Published var overallProgress = 0.0
    @Published var currentFileProgress = 0.0
    @Published var currentFileName = ""
    @Published var currentStageDescription = ""
    @Published var currentTranscriptionProgress = 0.0
    @Published var isDownloadingRuntime = false
    @Published private(set) var isScanningMedia = false
    @Published private(set) var mediaAdditionFeedback = ""
    @Published private(set) var vadCLICapability: WhisperCLICapability = .unchecked
    @Published private(set) var isDownloadingVADModel = false
    @Published var isRuntimeDownloadPromptPresented = false
    @Published var downloadedBytes: Int64 = 0
    @Published var downloadTotalBytes: Int64?
    @Published private(set) var previewFiles: [TranscriptPreviewFile] = []
    @Published private(set) var selectedPreviewFileID: URL?
    @Published private(set) var previewSegments: [TranscriptSegment] = []
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var liveSegments: [TranscriptSegment] = []
    @Published private(set) var historyEntries: [HistoryEntry] = []

    // P0.1 presentation state: terminal outcome and in-flight stage of the
    // batch, so results survive `isRunning` ending and the UI never has to
    // parse localized status text to learn where the run stands.
    @Published private(set) var activePhase: ActiveRunPhase?
    @Published private(set) var activeSnapshot: AppConfigurationSnapshot?
    @Published private(set) var runEffectiveMode: AccelerationMode?
    @Published private(set) var runCoreMLStatus: CoreMLRuntimeStatus = .notRequested
    @Published private(set) var lastOutcome: TaskOutcome?
    @Published private(set) var lastRunOutputFiles: [URL] = []
    @Published var selectedResultFileID: URL?

    private let defaults: UserDefaults
    private let providerStore: ProviderStore
    private let updateSecrets: FileSecretStore
    private let supportDirectory: URL
    private let vadModelSearchRoots: [URL]?
    private let huggingFaceEnvironment: [String: String]
    private var hasPresentedInitialRuntimePrompt = false
    private var transcriptionTask: Task<Void, Never>?
    private var runtimeDownloadTask: Task<Void, Never>?
    private var vadDownloadTask: Task<Void, Never>?
    private var vadCLICheckTask: Task<Void, Never>?
    private var previewLoadGeneration = 0
    private var mediaScanTask: Task<Void, Never>?
    private lazy var historyStore = TranscriptionHistoryStore()
    private let completionNotifier: CompletionNotifier
    private let mediaURLExpander: @Sendable ([URL]) async -> [URL]
    private let vadModelInstaller: @Sendable (
        URL,
        (@Sendable (RuntimeInstallerEvent) async -> Void)?
    ) async throws -> String
    private var keepAwakeToken: KeepAwakeToken?

    init(
        completionNotifier: CompletionNotifier? = nil,
        defaults: UserDefaults = .standard,
        providerStore: ProviderStore? = nil,
        supportDirectory: URL = AppPaths.supportDirectory,
        vadModelSearchRoots: [URL]? = nil,
        huggingFaceEnvironment: [String: String]? = nil,
        mediaURLExpander: @escaping @Sendable ([URL]) async -> [URL] = { urls in
            await PanelHelper.expandedMediaURLs(from: urls)
        },
        vadModelInstaller: @escaping @Sendable (
            URL,
            (@Sendable (RuntimeInstallerEvent) async -> Void)?
        ) async throws -> String = { baseURL, onEvent in
            try await RuntimeInstaller.installVADModel(baseURL: baseURL, onEvent: onEvent)
        }
    ) {
        self.completionNotifier = completionNotifier ?? CompletionNotifier()
        self.defaults = defaults
        self.supportDirectory = supportDirectory
        self.updateSecrets = FileSecretStore(path: supportDirectory.appending(path: "secrets.json"))
        self.providerStore = providerStore
            ?? ProviderStore(secrets: FileSecretStore(path: supportDirectory.appending(path: "secrets.json")))
        self.vadModelSearchRoots = vadModelSearchRoots
        self.huggingFaceEnvironment = huggingFaceEnvironment ?? ProcessInfo.processInfo.environment
        self.mediaURLExpander = mediaURLExpander
        self.vadModelInstaller = vadModelInstaller
        let guessed = PathResolver.guessDefaults()
        let storedWhisperCLIPath = defaults.string(forKey: Keys.whisperCLIPath) ?? ""
        let resolvedWhisperCLIPath = PathResolver.resolveWhisperCLIPath(storedWhisperCLIPath)
        let initialWhisperCLIPath = resolvedWhisperCLIPath.isEmpty
            ? (storedWhisperCLIPath.isEmpty ? guessed.whisperCLIPath : storedWhisperCLIPath)
            : resolvedWhisperCLIPath
        let storedModelPath = defaults.string(forKey: Keys.modelPath) ?? ""
        let resolvedModelPath = PathResolver.resolveModelPath(storedModelPath, whisperCLIPath: initialWhisperCLIPath)
        let initialModelPath = resolvedModelPath.isEmpty
            ? (storedModelPath.isEmpty ? guessed.modelPath : storedModelPath)
            : resolvedModelPath
        let storedFormats = defaults.array(forKey: Keys.outputFormats) as? [String]
        let storedTranslationSettings = defaults.data(forKey: Keys.translationSettings)
        let storedAccelerationMode = defaults.string(forKey: Keys.accelerationMode)
        var selectedFormats = Set((storedFormats ?? []).compactMap(OutputFormat.init(rawValue:)))
        if selectedFormats.isEmpty {
            selectedFormats = [.txt, .srt]
        }
        let storedSourceLanguage = defaults.string(forKey: Keys.sourceLanguage) ?? WhisperLanguage.autoCode
        let storedVADSettings = defaults.data(forKey: Keys.vadSettings)
            .flatMap { try? JSONDecoder().decode(VADSettings.self, from: $0) } ?? .default
        let storedHFSource = defaults.string(forKey: Keys.huggingFaceDownloadSource)
            .flatMap(HuggingFaceDownloadSource.init(rawValue:))
        let legacyHFEndpoint = defaults.string(forKey: HuggingFaceEndpoint.storedValueDefaultsKey)
        let initialHFSource: HuggingFaceDownloadSource = {
            if let storedHFSource { return storedHFSource }
            guard let legacyHFEndpoint else { return .official }
            guard let normalized = HuggingFaceEndpoint.sanitizedBaseURL(from: legacyHFEndpoint) else { return .custom }
            if normalized == HuggingFaceEndpoint.hfMirrorBaseURL { return .hfMirror }
            if normalized == HuggingFaceEndpoint.defaultBaseURL { return .official }
            return .custom
        }()
        let initialCustomHFEndpoint = defaults.string(forKey: Keys.customHuggingFaceEndpoint)
            ?? (initialHFSource == .custom ? legacyHFEndpoint : nil)
            ?? ""
        let initialSourceLanguage = WhisperLanguage.isSupported(storedSourceLanguage)
            ? storedSourceLanguage
            : WhisperLanguage.autoCode

        inputFiles = []
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        githubUpdateToken = (try? updateSecrets.secret(for: Self.updateTokenKey)) ?? ""
        appLanguage = AppLanguage(storedValue: defaults.string(forKey: Keys.appLanguage))
        outputDirectoryPath = defaults.string(forKey: Keys.outputDirectoryPath) ?? ""
        whisperCLIPath = initialWhisperCLIPath
        modelPath = initialModelPath
        accelerationMode = AccelerationMode(rawValue: storedAccelerationMode ?? "") ?? .gpuAndANE
        outputFormats = selectedFormats
        sourceLanguage = initialSourceLanguage
        translatesToEnglish = defaults.bool(forKey: Keys.translatesToEnglish)
        usesTextContext = defaults.bool(forKey: Keys.usesTextContext)
        vadSettings = storedVADSettings
        translationSettings = storedTranslationSettings
            .flatMap { try? JSONDecoder().decode(TranslationSettings.self, from: $0) } ?? TranslationSettings()
        huggingFaceDownloadSource = initialHFSource
        customHuggingFaceEndpoint = initialCustomHFEndpoint
        if storedHFSource == nil {
            defaults.set(initialHFSource.rawValue, forKey: Keys.huggingFaceDownloadSource)
        }

        logs = [
            L.tr("log.default_model"),
            L.tr("log.audio_preprocessor_switched"),
            L.tr("log.coreml_auto"),
        ]

        // Resolution stays a runtime overlay: UserDefaults only ever holds what
        // the user explicitly picked, so a launch-time guess is never silently
        // persisted over the stored setting.

        loadHistoryFromStore()
        refreshVADCLICapability()
        loadProviderState()

        // First launch: only switch translation on when we actually have a
        // provider (typically imported from AITrans). Without one, a fresh
        // install must still be able to transcribe.
        if storedTranslationSettings == nil, !providers.isEmpty {
            translationSettings.isEnabled = true
        }

        if autoCheckUpdates {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.autoCheckUpdates else { return }
                self.checkForUpdates(manual: false)
            }
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["TRANS2_DEBUG_CHECK_UPDATES"] == "1" {
            checkForUpdates()
        }
        #endif

        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["TRANS2_DEBUG_TRANSLATION_TIMING"],
           let timing = TranslationTiming(rawValue: raw) {
            translationSettings.timing = timing
        }
        #endif
    }

    var logsText: String {
        logs.joined(separator: "\n")
    }

    var canStart: Bool {
        startDisabledReason == nil && !isScanningMedia
    }

    /// CLI / model are blockers; a missing Core ML encoder is only an
    /// optional-capability hint (GPU fallback), never a start blocker.
    var blockingRuntimeComponents: Set<RuntimeComponent> {
        // A subtitle-only queue never invokes whisper, so a missing model or
        // CLI must not block it (or paint a scary setup screen).
        if !inputFiles.isEmpty && inputMediaFiles.isEmpty { return [] }
        return missingRuntimeComponents.subtracting([.coreMLEncoder])
    }

    var hasResolvableWhisperCLI: Bool {
        !resolvedWhisperCLIPath.isEmpty
    }

    var hasResolvableModel: Bool {
        !resolvedModelPath.isEmpty
    }

    var mainContentState: MainContentState {
        TaskPresentation.mainContent(
            isRunning: isRunning,
            isCancelling: isCancelling,
            isDownloadingRuntime: isDownloadingRuntime || isDownloadingVADModel,
            activePhase: activePhase,
            lastOutcome: lastOutcome,
            inputCount: inputFiles.count,
            blockingRuntimeComponents: blockingRuntimeComponents,
            vadModelMissing: vadSettings.isEnabled && resolvedVADModelPath.isEmpty,
            vadModelPath: VADModelResolver.downloadedModelURL.path
        )
    }

    var startDisabledReason: StartDisabledReason? {
        TaskPresentation.startDisabledReason(
            isRunning: isRunning,
            isDownloadingRuntime: isDownloadingRuntime || isDownloadingVADModel,
            inputCount: inputFiles.count,
            hasWhisperCLI: hasResolvableWhisperCLI,
            hasModel: hasResolvableModel,
            outputFormatCount: outputFormats.count,
            vadEnabled: vadSettings.isEnabled,
            hasVADModel: !resolvedVADModelPath.isEmpty,
            vadCLICapability: vadCLICapability,
            translationEnabled: translationSettings.isEnabled,
            hasTranslationProvider: translationSettings.backend == .ollama || activeProvider != nil,
            translationModelReady: translationModelName.isEmpty == false,
            hasMediaInputs: !inputMediaFiles.isEmpty
        )
    }

    // MARK: - Updates

    private static let updateTokenKey = "github-update"

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var updateToken: String? {
        let trimmed = githubUpdateToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistUpdateToken() {
        do {
            if let token = updateToken {
                try updateSecrets.setSecret(token, for: Self.updateTokenKey)
            } else {
                try updateSecrets.deleteSecret(for: Self.updateTokenKey)
            }
        } catch {
            appendLog(L.tr("settings.update_token_error", error.localizedDescription))
        }
    }

    func checkForUpdates(manual: Bool = true) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateStatusText = L.tr("settings.checking_updates")

        Task {
            defer { isCheckingForUpdates = false }
            do {
                let checker = UpdateChecker(token: updateToken)
                if let info = try await checker.check() {
                    updateInfo = info
                    updateStatusText = ""
                } else {
                    updateInfo = nil
                    updateStatusText = L.tr("settings.up_to_date", appVersion)
                }
            } catch {
                updateInfo = nil
                if manual {
                    updateStatusText = error.localizedDescription
                } else {
                    updateStatusText = ""
                }
            }
        }
    }

    func downloadUpdate() {
        guard let updateInfo, !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        updateStatusText = L.tr("settings.downloading_update")

        Task {
            defer { isDownloadingUpdate = false }
            do {
                let file = try await UpdateDownloader.download(updateInfo, token: updateToken)
                downloadedUpdate = file
                updateStatusText = L.tr("settings.update_downloaded", file.path)
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } catch {
                updateStatusText = error.localizedDescription
            }
        }
    }

    func openUpdatePage() {
        guard let url = updateInfo?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealDownloadedUpdate() {
        guard let url = downloadedUpdate, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Translation configuration

    var activeProvider: Provider? {
        guard let activeProviderID else { return nil }
        return providers.first { $0.id == activeProviderID }
    }

    /// Media goes through whisper; `.srt` inputs skip straight to translation.
    var inputMediaFiles: [URL] {
        inputFiles.filter { $0.pathExtension.lowercased() != "srt" }
    }

    var inputSubtitleFiles: [URL] {
        inputFiles.filter { $0.pathExtension.lowercased() == "srt" }
    }

    /// The model that will translate: the active provider's model for API
    /// backends, the configured Ollama tag otherwise.
    var translationModelName: String {
        switch translationSettings.backend {
        case .api:
            return activeProvider?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .ollama:
            return translationSettings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var translationSummary: String {
        guard translationSettings.isEnabled else { return L.tr("common.off") }
        let target = translationSettings.targetLanguage.displayName
        switch translationSettings.backend {
        case .api:
            guard let provider = activeProvider, !translationModelName.isEmpty else {
                return L.tr("translation.summary.unconfigured", target)
            }
            return L.tr("translation.summary.api", provider.name, translationModelName, target)
        case .ollama:
            return L.tr("translation.summary.ollama", translationModelName, target)
        }
    }

    private func loadProviderState() {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try providerStore.load(from: providersFileURL)
            try providerStore.migratePlaintextKeys(to: providersFileURL)
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
            // A providers file without an "active" entry still has a sensible
            // default: the first one. Persist it so the picker agrees with the
            // model that will actually be used.
            if activeProviderID == nil, let first = providers.first {
                try providerStore.setActive(id: first.id)
                try providerStore.save(to: providersFileURL)
                activeProviderID = providerStore.activeID
            }
        } catch {
            appendLog(L.tr("translation.log.provider_load_failed", error.localizedDescription))
            return
        }
        // First launch after installing Trans2: reuse the providers the user
        // already configured in AITrans instead of asking for the key again.
        if providers.isEmpty {
            _ = importProvidersFromAITrans(announce: false)
        }
    }

    func providerForEditing(_ provider: Provider) -> Provider {
        do {
            return try providerStore.hydrate(provider)
        } catch {
            appendLog(L.tr("translation.log.provider_key_failed", error.localizedDescription))
            return provider
        }
    }

    @discardableResult
    func saveProvider(_ provider: Provider, activate: Bool) -> Provider? {
        do {
            let saved = try providerStore.upsert(provider, activate: activate)
            try providerStore.save(to: providersFileURL)
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
            return saved
        } catch {
            appendLog(L.tr("translation.log.provider_save_failed", error.localizedDescription))
            return nil
        }
    }

    @discardableResult
    func deleteProvider(id: String) -> Bool {
        do {
            try providerStore.delete(id: id)
            try providerStore.save(to: providersFileURL)
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
            return true
        } catch {
            appendLog(L.tr("translation.log.provider_delete_failed", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func clearProviderKey(id: String) -> Bool {
        do {
            try providerStore.clearSecret(for: id)
            providers = providerStore.providers
            return true
        } catch {
            appendLog(L.tr("translation.log.provider_key_clear_failed", error.localizedDescription))
            return false
        }
    }

    func setActiveProvider(id: String) {
        do {
            try providerStore.setActive(id: id)
            try providerStore.save(to: providersFileURL)
            activeProviderID = providerStore.activeID
        } catch {
            appendLog(L.tr("translation.log.provider_save_failed", error.localizedDescription))
        }
    }

    /// Reads AITrans' own Application Support folder (providers.json plus the
    /// 0600 secrets.json) and copies every provider, keys included.
    @discardableResult
    func importProvidersFromAITrans(announce: Bool = true) -> Int {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AITrans", directoryHint: .isDirectory)
        let providersURL = directory.appending(path: "providers.json")
        let secretsURL = directory.appending(path: "secrets.json")
        guard FileManager.default.fileExists(atPath: providersURL.path) else {
            if announce { appendLog(L.tr("translation.log.import_nothing")) }
            return 0
        }

        let source = ProviderStore(secrets: FileSecretStore(path: secretsURL))
        do {
            try source.load(from: providersURL)
            var imported = 0
            for provider in source.providers {
                var hydrated = provider
                if hydrated.apiKey.isEmpty {
                    hydrated.apiKey = (try? source.hydrate(provider))?.apiKey ?? ""
                }
                _ = try providerStore.upsert(hydrated, activate: providerStore.activeID == nil)
                imported += 1
            }
            try providerStore.save(to: providersFileURL)
            providers = providerStore.providers
            activeProviderID = providerStore.activeID
            if announce {
                appendLog(L.tr("translation.log.imported", imported))
            }
            return imported
        } catch {
            appendLog(L.tr("translation.log.import_failed", error.localizedDescription))
            return 0
        }
    }

    func testProvider(_ provider: Provider) async -> String {
        let hydrated = providerForEditing(provider)
        var base = hydrated.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/models") else { return L.tr("translation.test.invalid_url") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !hydrated.apiKey.isEmpty {
            request.setValue("Bearer \(hydrated.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return L.tr("translation.test.ok") }
            if status == 401 || status == 403 { return L.tr("translation.test.auth", status) }
            if status == 404 { return L.tr("translation.test.no_models") }
            let body = String(decoding: data.prefix(160), as: UTF8.self)
            return "HTTP \(status)\(body.isEmpty ? "" : "：\(body)")"
        } catch {
            if ChatClient.isAppTransportSecurityError(error) {
                return L.tr("translation.test.ats")
            }
            return L.tr("translation.test.failed", error.localizedDescription)
        }
    }

    func refreshVADCLICapability() {
        vadCLICheckTask?.cancel()
        let path = resolvedWhisperCLIPath
        guard !path.isEmpty else {
            vadCLICapability = .unsupported
            return
        }
        vadCLICapability = .checking
        vadCLICheckTask = Task { [weak self] in
            let supported = await WhisperCLICapabilityChecker.shared.supportsVAD(at: path)
            guard !Task.isCancelled, let self, self.resolvedWhisperCLIPath == path else { return }
            self.vadCLICapability = supported ? .supported : .unsupported
        }
    }

    var downloadProgress: Double? {
        guard let totalBytes = downloadTotalBytes, totalBytes > 0, downloadedBytes > 0 else { return nil }
        return min(Double(downloadedBytes) / Double(totalBytes), 1.0)
    }

    var isBusy: Bool {
        isRunning || isDownloadingRuntime || isDownloadingVADModel || isScanningMedia
    }

    var outputDirectoryDisplayText: String {
        let trimmed = outputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let firstInput = inputFiles.first {
            return L.tr("display.follow_input_dir", firstInput.deletingLastPathComponent().path)
        }
        return L.tr("display.follow_input_default")
    }

    var configurationLooksReady: Bool {
        !resolvedModelPath.isEmpty &&
        !resolvedWhisperCLIPath.isEmpty
    }

    var missingRuntimeComponents: Set<RuntimeComponent> {
        runtimeComponentsMissing(whisperCLIPath: whisperCLIPath, modelPath: modelPath)
    }

    var resolvedVADModelPath: String {
        VADModelResolver.resolve(vadSettings.modelPath, searchRoots: vadModelSearchRoots)
    }

    var hasResolvableVADModel: Bool { !resolvedVADModelPath.isEmpty }

    var hasHuggingFaceEnvironmentOverride: Bool {
        huggingFaceEnvironment[HuggingFaceEndpoint.environmentVariableName] != nil
    }

    var resolvedHuggingFaceBaseURL: URL? {
        HuggingFaceEndpoint.resolved(
            source: huggingFaceDownloadSource,
            customValue: customHuggingFaceEndpoint,
            environment: huggingFaceEnvironment
        )
    }

    var isHuggingFaceEndpointInvalid: Bool { resolvedHuggingFaceBaseURL == nil }

    var canDownloadRuntimeAssets: Bool {
        !isBusy && !isHuggingFaceEndpointInvalid
    }

    var huggingFaceEndpointDisplayText: String {
        resolvedHuggingFaceBaseURL?.absoluteString ?? L.tr("hf.endpoint.invalid")
    }

    /// The path currently used at runtime; automatic discovery remains an overlay
    /// and is never written back into the user's explicit setting.
    var vadModelDisplayPath: String {
        let configuredPath = vadSettings.modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty { return PathResolver.expandingTilde(configuredPath) }
        return resolvedVADModelPath
    }

    var isVADModelUsingAutomaticPath: Bool {
        vadSettings.modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var downloadableRuntimeComponents: Set<RuntimeComponent> {
        missingRuntimeComponents.subtracting([.whisperCLI])
    }

    var runtimeDownloadPromptTitle: String {
        L.tr("alert.runtime_missing_title")
    }

    var runtimeDownloadPromptMessage: String {
        downloadableRuntimeComponents.isEmpty ? "" : L.tr("alert.runtime_missing_message_model")
    }

    var accelerationSummary: String {
        let resolvedWhisperCLIPath = self.resolvedWhisperCLIPath
        guard !resolvedWhisperCLIPath.isEmpty else {
            return L.tr("summary.runtime_missing_cli")
        }

        let resolvedModelPath = self.resolvedModelPath
        guard !resolvedModelPath.isEmpty else {
            return L.tr("summary.model_assets_missing")
        }

        let modelURL = URL(fileURLWithPath: resolvedModelPath)
        let coreMLURL = OutputPaths.coreMLModelURL(for: modelURL)
        let hasCoreML = FileManager.default.fileExists(atPath: coreMLURL.path)

        if accelerationMode == .gpuAndANE && !hasCoreML {
            return L.tr("summary.coreml_missing_download")
        }
        if accelerationMode == .gpuAndANE && hasCoreML {
            return L.tr("summary.mode_gpu_ane")
        }
        if hasCoreML {
            return L.tr("summary.mode_pure_gpu_coreml_present")
        }
        return L.tr("summary.mode_pure_gpu")
    }

    var accelerationDetail: String {
        switch accelerationMode {
        case .pureGPU:
            return L.tr("detail.pure_gpu")
        case .gpuAndANE:
            return L.tr("detail.gpu_ane")
        }
    }

    func chooseInputFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PanelHelper.supportedMediaTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }
        addMediaURLs(panel.urls)
    }

    func addMediaURLs(_ urls: [URL]) {
        // P0.1: a started batch executes a frozen snapshot; adding files mid-run
        // would desync the visible queue from that snapshot, so additions are
        // rejected until the batch ends.
        guard !isRunning, !isScanningMedia else { return }
        guard !urls.isEmpty else { return }
        isScanningMedia = true
        mediaAdditionFeedback = L.tr("media.scanning")
        statusText = L.tr("media.scanning")
        mediaScanTask = Task { [weak self] in
            await self?.completeMediaAdditionScan(urls)
        }
    }

    /// Awaits the one active scan; also provides a deterministic completion
    /// point for state-level tests without sleeps or polling.
    func waitForMediaScan() async {
        await mediaScanTask?.value
    }

    private func completeMediaAdditionScan(_ urls: [URL]) async {
        defer {
            isScanningMedia = false
            mediaScanTask = nil
        }
        let expanded = await mediaURLExpander(urls)
        guard !expanded.isEmpty else {
            mediaAdditionFeedback = L.tr("media.no_supported_files")
            return
        }
        let additions = PanelHelper.mediaFileAdditions(from: expanded, existing: inputFiles)
        guard !additions.isEmpty else {
            mediaAdditionFeedback = L.tr("media.no_new_files")
            return
        }
        inputFiles.append(contentsOf: additions)
        if outputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputDirectoryPath = ""
        }
        mediaAdditionFeedback = L.tr("media.added_count", additions.count)
    }

    func clearInputFiles() {
        guard !isBusy else { return }
        inputFiles.removeAll()
    }

    func removeInputFile(_ url: URL) {
        guard !isBusy else { return }
        inputFiles.removeAll { $0 == url }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectoryPath = url.path
    }

    func chooseWhisperCLI() {
        if let url = PanelHelper.chooseBinary() {
            whisperCLIPath = url.path
            PathResolver.invalidateCaches()
        }
    }

    func chooseModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.nameFieldStringValue = "ggml-large-v3-turbo.bin"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelPath = url.path
        PathResolver.invalidateCaches()
    }

    func chooseVADModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.nameFieldStringValue = VADModelResolver.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vadSettings.modelPath = url.path
    }

    func restoreAutomaticVADModel() {
        vadSettings.modelPath = ""
    }

    func downloadVADModel() {
        guard !isBusy else { return }
        guard resolvedHuggingFaceBaseURL != nil else {
            statusText = L.tr("hf.endpoint.invalid")
            return
        }
        vadDownloadTask = Task { [weak self] in await self?.installVADModel() }
    }

    func cancelVADModelDownload() {
        vadDownloadTask?.cancel()
    }

    func waitForVADDownload() async {
        await vadDownloadTask?.value
    }

    func openOutputDirectory() {
        let directoryPath = resolvedOutputDirectoryPath(for: inputFiles.first)
        guard !directoryPath.isEmpty else { return }
        let directory = URL(fileURLWithPath: directoryPath)
        NSWorkspace.shared.open(directory)
    }

    func openProjectREADME() {
        let bundledREADME = Bundle.main.resourceURL?.appending(path: "README.md")
        let readmeURL = bundledREADME.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? PathResolver.projectRoot.appending(path: "README.md")
        guard FileManager.default.fileExists(atPath: readmeURL.path) else { return }
        NSWorkspace.shared.open(readmeURL)
    }

    func refreshLocalizedContent() {
        store(appLanguage.rawValue, forKey: Keys.appLanguage)

        if !isRunning && !isDownloadingRuntime {
            statusText = ""
            currentStageDescription = ""
            logs = [
                L.tr("log.default_model"),
                L.tr("log.audio_preprocessor_switched"),
                L.tr("log.coreml_auto"),
            ]
        }

        objectWillChange.send()
    }

    func promptToDownloadMissingRuntimeIfNeeded() {
        guard !hasPresentedInitialRuntimePrompt else { return }
        hasPresentedInitialRuntimePrompt = true
        promptToDownloadMissingRuntime(force: false)
    }

    func promptToDownloadMissingRuntime(force: Bool) {
        guard !isDownloadingRuntime else { return }
        guard !downloadableRuntimeComponents.isEmpty else { return }
        if force || !isRuntimeDownloadPromptPresented {
            isRuntimeDownloadPromptPresented = true
        }
    }

    func dismissRuntimeDownloadPrompt() {
        isRuntimeDownloadPromptPresented = false
    }

    func startRuntimeDownload() {
        guard !isBusy else { return }
        guard resolvedHuggingFaceBaseURL != nil else {
            statusText = L.tr("hf.endpoint.invalid")
            return
        }
        let missing = downloadableRuntimeComponents
        guard !missing.isEmpty else { return }

        isRuntimeDownloadPromptPresented = false

        runtimeDownloadTask = Task { [weak self] in
            await self?.downloadMissingRuntime(missing)
        }
    }

    func cancelRuntimeDownload() {
        guard isDownloadingRuntime else { return }
        runtimeDownloadTask?.cancel()
    }

    func cancelActiveDownload() {
        switch TaskPresentation.activeDownload(
            isDownloadingRuntime: isDownloadingRuntime,
            isDownloadingVADModel: isDownloadingVADModel
        ) {
        case .runtime: cancelRuntimeDownload()
        case .vadModel: cancelVADModelDownload()
        case nil: break
        }
    }

    func setFormat(_ format: OutputFormat, enabled: Bool) {
        if enabled {
            outputFormats.insert(format)
            return
        }
        if outputFormats.count > 1 {
            outputFormats.remove(format)
        }
    }

    func startTranscription() {
        guard canStart else {
            promptToDownloadMissingRuntime(force: true)
            return
        }

        translationSettings.sanitize()

        // Resolve the translation model once, before the frozen snapshot is
        // taken: a missing key should stop the batch here, not after the
        // (possibly hour-long) transcription has already finished.
        var translationProvider: Provider?
        if translationSettings.isEnabled {
            switch translationSettings.backend {
            case .api:
                guard let selected = activeProvider else {
                    statusText = L.tr("translation.error.no_provider")
                    appendLog(L.tr("translation.error.no_provider"))
                    return
                }
                do {
                    translationProvider = try providerStore.hydrate(selected)
                } catch {
                    statusText = L.tr("translation.log.provider_key_failed", error.localizedDescription)
                    return
                }
                if translationProvider?.requiresKey == true,
                   translationProvider?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    statusText = L.tr("translation.error.missing_key", selected.name)
                    appendLog(L.tr("translation.error.missing_key", selected.name))
                    return
                }
                if translationModelName.isEmpty {
                    statusText = L.tr("translation.error.missing_model")
                    return
                }
            case .ollama:
                if translationModelName.isEmpty {
                    statusText = L.tr("translation.error.missing_model")
                    return
                }
            }
        }

        let hasMediaInputs = !inputMediaFiles.isEmpty
        let resolvedWhisperCLIPath = hasMediaInputs ? self.resolvedWhisperCLIPath : ""
        let resolvedModelPath = hasMediaInputs ? self.resolvedModelPath : ""

        // Translation consumes SRT; force the format for this run without
        // rewriting the user's export selection.
        var runFormats = outputFormats
        if translationSettings.isEnabled {
            runFormats.insert(.srt)
        }

        let snapshot = AppConfigurationSnapshot(
            inputFiles: inputFiles,
            outputDirectoryPath: outputDirectoryPath,
            whisperCLIPath: resolvedWhisperCLIPath,
            modelPath: resolvedModelPath,
            accelerationMode: accelerationMode,
            outputFormats: runFormats,
            sourceLanguage: sourceLanguage,
            translatesToEnglish: translatesToEnglish,
            usesTextContext: usesTextContext,
            vadSettings: {
                var settings = vadSettings
                if settings.isEnabled { settings.modelPath = resolvedVADModelPath }
                return settings
            }(),
            translation: translationSettings,
            translationProvider: translationProvider,
            translationModel: translationModelName
        )

        // A new batch starts from a clean terminal slate; the previous run's
        // outcome must not leak into this one's result view.
        lastOutcome = nil
        lastRunOutputFiles = []
        selectedResultFileID = nil
        lastTranslationCount = 0
        lastTranslationFailureCount = 0
        pipelinedTranslatedFiles = 0
        lastRunTranslationWasEnabled = translationSettings.isEnabled
        lastRunTranslationTarget = translationSettings.targetLanguage
        activeSnapshot = snapshot

        transcriptionTask = Task {
            await runTranscription(snapshot)
        }
    }

    func retryTranscriptionWithoutVAD() {
        guard vadSettings.isEnabled, case .noSpeech? = lastOutcome else { return }
        vadSettings.isEnabled = false
        dismissOutcome()
        startTranscription()
    }

    /// Leaves the terminal-result view without starting anything (used by
    /// "New Task" / "Adjust Options"); queue and settings are preserved.
    func dismissOutcome() {
        lastOutcome = nil
    }

    func selectResultFile(id: URL?) {
        guard let id, lastRunOutputFiles.contains(id) else { return }
        selectedResultFileID = id
    }

    /// Reveals the confirmed result file the user is looking at: the selected
    /// SRT preview when one exists, otherwise the selected output from the
    /// actual reported files.
    func revealSelectedResultInFinder() {
        let candidates: [URL?] = [selectedPreviewFileID, selectedResultFileID, lastRunOutputFiles.first]
        for candidate in candidates {
            if let url = candidate, FileManager.default.fileExists(atPath: url.path) {
                revealOutputFileInFinder(url)
                return
            }
        }
    }

    func revealOutputFileInFinder(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the folder of the currently selected result so the whole batch
    /// is one click away after a run.
    func openOutputFolderForResult() {
        let candidates: [URL?] = [selectedPreviewFileID, selectedResultFileID, lastRunOutputFiles.first]
        guard let url = candidates.compactMap({ $0 }).first else { return }
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }

    func cancelTranscription() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        transcriptionTask?.cancel()
    }

    private func runTranscription(_ snapshot: AppConfigurationSnapshot) async {
        isRunning = true
        keepAwakeToken = KeepAwakeController.acquire(reason: KeepAwakeController.batchReason)
        let notifier = completionNotifier
        Task { await notifier.prepareForRun() }
        let runStartedAt = Date()
        clearPreviews()
        liveSegments = []
        logs.removeAll()
        statusText = L.tr("status.preparing_start")
        overallProgress = 0
        currentFileProgress = 0
        currentFileName = ""
        currentStageDescription = ""
        currentTranscriptionProgress = 0
        activePhase = .preparingInputs(currentIndex: 0, total: snapshot.inputFiles.count)
        runEffectiveMode = nil
        runCoreMLStatus = .notRequested

        let service = TranscriptionService()
        var translationContext: TranslationContext?
        let mediaInputs = snapshot.inputFiles.filter { $0.pathExtension.lowercased() != "srt" }
        let subtitleInputs = snapshot.inputFiles.filter { $0.pathExtension.lowercased() == "srt" }
        let hasMedia = !mediaInputs.isEmpty
        let modelPlan: RuntimeModelPlan?
        var successCount = 0
        var failureCount = 0
        var wasCancelled = false
        var noSpeechFileNames: [String] = []

        if hasMedia {
            do {
                if snapshot.vadSettings.isEnabled {
                    let vadURL = URL(fileURLWithPath: PathResolver.expandingTilde(snapshot.vadSettings.modelPath))
                    guard VADModelResolver.isValidModel(at: vadURL) else {
                        throw VADModelResolutionError.missing(vadURL.path)
                    }
                }
                modelPlan = try RuntimeModelResolver.prepare(
                    modelPath: snapshot.modelPath,
                    requestedMode: snapshot.accelerationMode
                )
            } catch {
                appendLog(error.localizedDescription)
                statusText = L.tr("status.prepare_failed")
                lastOutcome = .failed(summary: error.localizedDescription)
                await finishTranscriptionRun(failureCount: snapshot.inputFiles.count)
                return
            }
        } else {
            modelPlan = nil
        }
        let awaitsCoreMLConfirmation = hasMedia
            && snapshot.accelerationMode == .gpuAndANE
            && (modelPlan?.coreMLAvailable ?? false)
        runCoreMLStatus = awaitsCoreMLConfirmation ? .loading : .notRequested
        runEffectiveMode = awaitsCoreMLConfirmation ? nil : .pureGPU

        appendLog(L.tr("log.start_files", snapshot.inputFiles.count))
        if !subtitleInputs.isEmpty {
            appendLog(L.tr("translation.log.subtitle_inputs", subtitleInputs.count))
        }
        if let modelPlan {
            appendLog(L.tr("log.requested_mode", snapshot.accelerationMode.title))
            appendLog(L.tr("log.expected_mode", modelPlan.effectiveMode.title))
            appendLog(L.tr("log.text_context", snapshot.usesTextContext ? L.tr("log.enabled") : L.tr("log.disabled")))
            appendLog(L.tr("log.vad_enabled", snapshot.vadSettings.isEnabled ? L.tr("log.enabled") : L.tr("log.disabled")))
            if snapshot.vadSettings.isEnabled {
                let vadModelName = URL(fileURLWithPath: snapshot.vadSettings.modelPath).lastPathComponent
                appendLog(L.tr("log.vad_model", vadModelName, snapshot.vadSettings.modelPath))
                appendLog(L.tr("log.vad_threshold", snapshot.vadSettings.threshold))
                appendLog(L.tr("log.vad_min_speech", Int64(snapshot.vadSettings.minSpeechDurationMs)))
                appendLog(L.tr("log.vad_min_silence", Int64(snapshot.vadSettings.minSilenceDurationMs)))
                appendLog(L.tr("log.vad_speech_pad", Int64(snapshot.vadSettings.speechPadMs)))
            }
            appendLog(L.tr("log.model_path", modelPlan.originalModelPath))
            if modelPlan.executionModelPath != modelPlan.originalModelPath {
                appendLog(L.tr("log.runtime_model_path", modelPlan.executionModelPath))
            }
            appendLog(L.tr("log.coreml_encoder", modelPlan.coreMLAvailable ? modelPlan.coreMLModelPath : L.tr("log.not_found")))
            for note in modelPlan.notes {
                appendLog(note)
            }
        }
        if snapshot.outputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog(L.tr("log.output_directory_follow"))
        } else {
            appendLog(L.tr("log.output_directory", PathResolver.expandingTilde(snapshot.outputDirectoryPath)))
        }
        if hasMedia {
            appendLog(L.tr("log.output_formats", snapshot.outputFormats.map(\.rawValue).sorted().joined(separator: ", ")))
        }

        let totalFiles = snapshot.inputFiles.count
        let batchInputs = mediaInputs.map { inputURL in
            BatchTranscriptionInput(
                inputURL: inputURL,
                outputDirectory: URL(fileURLWithPath: resolvedOutputDirectoryPath(for: inputURL, overridePath: snapshot.outputDirectoryPath))
            )
        }

        do {
            if snapshot.translation.isEnabled {
                translationContext = try await makeTranslationContext(snapshot)
                if let translationContext {
                    appendLog(L.tr("translation.log.config", translationContext.summary))
                    appendLog(L.tr("translation.log.output_mode", snapshot.translation.outputMode.title))
                    appendLog(L.tr("translation.log.polish", snapshot.translation.polish ? L.tr("log.enabled") : L.tr("log.disabled")))
                }
            }
            var reports: [TranscriptionReport] = []
            var translatedFiles: [URL] = []
            if hasMedia,
               let modelPlan,
               let translationContext,
               snapshot.translation.timing == .duringTranscription {
                let result = try await transcribeAndTranslatePipelined(
                    mediaInputs: mediaInputs,
                    batchInputs: batchInputs,
                    subtitleInputs: subtitleInputs,
                    service: service,
                    modelPlan: modelPlan,
                    context: translationContext,
                    snapshot: snapshot,
                    awaitsCoreMLConfirmation: awaitsCoreMLConfirmation
                )
                reports = result.reports
                translatedFiles = result.translatedFiles
            } else {
                if hasMedia, let modelPlan {
                    reports = try await service.transcribeBatch(
                inputs: batchInputs,
                whisperCLIPath: snapshot.whisperCLIPath,
                modelPath: modelPlan.executionModelPath,
                formats: snapshot.outputFormats,
                sourceLanguage: snapshot.sourceLanguage,
                translatesToEnglish: snapshot.translatesToEnglish,
                usesTextContext: snapshot.usesTextContext,
                vadSettings: snapshot.vadSettings,
                onInputStageChange: { [weak self] index, stage in
                    await MainActor.run {
                        guard let self else { return }
                        self.activePhase = .preparingInputs(currentIndex: index, total: totalFiles)
                        self.statusText = L.tr("status.processing", index + 1, totalFiles)
                        self.currentFileName = snapshot.inputFiles[index].lastPathComponent
                        switch stage {
                        case .preparing:
                            self.currentStageDescription = stage.description
                            self.currentFileProgress = 0.03
                        case .extractingAudio:
                            self.currentStageDescription = stage.description
                            self.currentFileProgress = max(self.currentFileProgress, 0.12)
                        default:
                            break
                        }
                        let preparationProgress = min((Double(index) + self.currentFileProgress) / Double(totalFiles), 1.0)
                        self.overallProgress = preparationProgress * 0.18 * (snapshot.translation.isEnabled ? 0.85 : 1.0)
                    }
                },
                onStageChange: { [weak self] stage in
                    await MainActor.run {
                        guard let self else { return }
                        switch stage {
                        case .transcribing:
                            self.activePhase = .transcribingBatch(totalFiles: totalFiles)
                            self.statusText = L.tr("stage.transcribing_batch", totalFiles)
                            self.currentFileName = ""
                            self.currentStageDescription = stage.description
                            self.currentFileProgress = max(self.currentFileProgress, 0.18)
                        case .finished:
                            self.currentStageDescription = stage.description
                            self.currentTranscriptionProgress = 1
                            self.currentFileProgress = 1
                            self.overallProgress = snapshot.translation.isEnabled ? 0.85 : 1
                        default:
                            break
                        }
                    }
                },
                onLog: { [weak self] line in
                    await MainActor.run {
                        self?.observeRuntimeAccelerationLog(line, expectedCoreML: awaitsCoreMLConfirmation)
                        self?.appendLog(line)
                    }
                },
                onTranscriptionProgress: { [weak self] progress in
                    await MainActor.run {
                        guard let self else { return }
                        self.currentTranscriptionProgress = progress
                        self.currentStageDescription = L.tr("stage.transcribing_progress", Int(progress * 100))
                        self.currentFileProgress = max(0.18, 0.18 + 0.82 * progress)
                        self.overallProgress = min(0.18 + 0.82 * progress, 1.0)
                            * (snapshot.translation.isEnabled ? 0.85 : 1.0)
                    }
                },
                onSegment: { [weak self] segment in
                    await MainActor.run {
                        self?.appendLiveSegment(segment)
                    }
                }
                )
                }

                let transcriptSRTs = reports.flatMap(\.outputFiles).filter {
                    $0.pathExtension.lowercased() == "srt"
                }
                let translationSources = transcriptSRTs + subtitleInputs
                if let translationContext, !translationSources.isEmpty {
                    let trimmedOutput = snapshot.outputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    let outputDirectory = trimmedOutput.isEmpty
                        ? nil
                        : URL(fileURLWithPath: PathResolver.expandingTilde(trimmedOutput))
                    let result = try await translateTranscripts(
                        translationSources,
                        outputDirectory: outputDirectory,
                        context: translationContext,
                        snapshot: snapshot
                    )
                    translatedFiles = result.files
                } else if !subtitleInputs.isEmpty, !snapshot.translation.isEnabled {
                    appendLog(L.tr("translation.log.subtitles_skipped", subtitleInputs.count))
                }
            }

            let noSpeechInputFiles = hasMedia && snapshot.vadSettings.isEnabled
                ? reports.indices.filter {
                    !reports[$0].outputFiles.isEmpty && !reports[$0].containsTranscriptContent
                }.map { mediaInputs[$0] }
                : []
            successCount = hasMedia ? mediaInputs.count - noSpeechInputFiles.count : subtitleInputs.count
            if let whisperCommand = reports.first?.whisperCommand {
                appendLog(L.tr("log.whisper_command", whisperCommand))
            }
            for (index, report) in reports.enumerated() {
                appendLog(L.tr("log.completed_file", mediaInputs[index].lastPathComponent))
                appendLog(L.tr("log.output_directory", batchInputs[index].outputDirectory.path))
                appendLog(L.tr("log.audio_preparation_command", report.audioPreparationCommand))
                if !report.outputFiles.isEmpty {
                    appendLog(L.tr("log.generated_files"))
                    for outputFile in report.outputFiles {
                        appendLog("  \(outputFile.path)")
                    }
                }
            }
            let transcriptFiles = reports.flatMap(\.outputFiles)
            let translationSources = transcriptFiles.filter {
                $0.pathExtension.lowercased() == "srt"
            } + subtitleInputs
            installPreviewFiles(
                from: reports,
                translatedFiles: translatedFiles,
                subtitleInputs: subtitleInputs
            )
            // Success comes only from the service returning normally; the
            // output list is exactly what the reports confirmed on disk.
            let outputFiles = transcriptFiles + translatedFiles
            lastRunOutputFiles = outputFiles
            selectedResultFileID = translatedFiles.first ?? outputFiles.first
            if !hasMedia, !translationSources.isEmpty, translatedFiles.isEmpty {
                failureCount = totalFiles
                successCount = 0
                lastOutcome = .failed(summary: L.tr("translation.error.all_failed"))
            } else if noSpeechInputFiles.isEmpty {
                lastOutcome = .succeeded(inputFileCount: totalFiles, outputFiles: outputFiles)
            } else {
                noSpeechFileNames = noSpeechInputFiles.map(\.lastPathComponent)
                for fileName in noSpeechFileNames {
                    appendLog(L.tr("log.vad_no_speech_file", fileName))
                }
                lastOutcome = .noSpeech(fileNames: noSpeechFileNames, outputFiles: outputFiles)
            }
            if !reports.isEmpty {
                recordHistoryEntries(
                    reports: reports,
                    inputFiles: mediaInputs,
                    outputDirectories: batchInputs.map(\.outputDirectory),
                    durationSeconds: Date().timeIntervalSince(runStartedAt)
                )
            }
        } catch is CancellationError {
            wasCancelled = true
            appendLog(L.tr("log.cancelled"))
            lastOutcome = .cancelled
        } catch {
            failureCount = totalFiles
            currentFileProgress = 1
            currentStageDescription = L.tr("stage.failed")
            appendLog(L.tr("log.failed_batch"))
            appendLog(error.localizedDescription)
            lastOutcome = .failed(summary: error.localizedDescription)
        }

        appendLog(String(repeating: "-", count: 72))

        if wasCancelled {
            statusText = L.tr("status.cancelled")
            currentStageDescription = L.tr("status.cancelled")
        } else if !noSpeechFileNames.isEmpty {
            statusText = L.tr("result.no_speech.bar", noSpeechFileNames.count)
            currentStageDescription = L.tr("result.no_speech.title")
            currentFileProgress = 1
            overallProgress = 1
        } else {
            if snapshot.translation.isEnabled, lastTranslationFailureCount > 0 {
                statusText = L.tr("translation.status.completed_with_failures", lastTranslationFailureCount)
            } else {
                statusText = L.tr("log.completed_summary", successCount, failureCount)
            }
            currentStageDescription = failureCount == 0 ? L.tr("stage.all_done") : L.tr("stage.processing_finished")
            currentFileProgress = snapshot.inputFiles.isEmpty ? 0 : 1
            overallProgress = snapshot.inputFiles.isEmpty ? 0 : 1
        }
        await finishTranscriptionRun(
            successCount: successCount,
            failureCount: failureCount,
            wasCancelled: wasCancelled
        )
    }

    // MARK: - Translation stage

    private func makeTranslationContext(_ snapshot: AppConfigurationSnapshot) async throws -> TranslationContext {
        let settings = snapshot.translation
        switch settings.backend {
        case .api:
            guard let provider = snapshot.translationProvider else {
                throw TranslationError.noProvider
            }
            let client = ChatClient(
                baseURL: provider.baseURL,
                apiKey: provider.apiKey,
                model: snapshot.translationModel,
                policy: RetryPolicy(retries: settings.apiRetries)
            )
            return TranslationContext(
                settings: settings,
                client: client,
                providerName: provider.name,
                modelName: snapshot.translationModel
            )
        case .ollama:
            statusText = L.tr("translation.status.checking_ollama")
            appendLog(L.tr("translation.log.ollama_check", settings.ollamaModel))
            try await OllamaService.ensureRunning()
            try await OllamaService.ensureModel(settings.ollamaModel)
            let client = OllamaClient(
                model: settings.ollamaModel,
                policy: RetryPolicy(retries: settings.ollamaRetries)
            )
            return TranslationContext(
                settings: settings,
                client: client,
                providerName: "Ollama",
                modelName: settings.ollamaModel
            )
        }
    }

    /// Translates every whisper-produced SRT in order. A failed file is logged
    /// and skipped: the transcript itself is still a successful result.
    /// Transcribes one media file at a time and starts translating each SRT as
    /// soon as it exists, while the next file is still on the GPU. This is the
    /// "translate while transcribing" mode; translation files run at most
    /// `maxInFlight` at a time so API providers are not flooded.
    private func transcribeAndTranslatePipelined(
        mediaInputs: [URL],
        batchInputs: [BatchTranscriptionInput],
        subtitleInputs: [URL],
        service: TranscriptionService,
        modelPlan: RuntimeModelPlan,
        context: TranslationContext,
        snapshot: AppConfigurationSnapshot,
        awaitsCoreMLConfirmation: Bool
    ) async throws -> (reports: [TranscriptionReport], translatedFiles: [URL]) {
        let mediaCount = mediaInputs.count
        let trimmedOutput = snapshot.outputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputDirectory = trimmedOutput.isEmpty
            ? nil
            : URL(fileURLWithPath: PathResolver.expandingTilde(trimmedOutput))
        let maxInFlight = snapshot.translation.backend == .api ? 2 : 1

        var reports: [TranscriptionReport] = []
        var translatedFiles: [URL] = []
        var failures = 0
        var tasks: [Task<(URL?, Int), Never>] = []
        defer { tasks.forEach { $0.cancel() } }

        func record(_ result: (URL?, Int)) {
            if let url = result.0 {
                translatedFiles.append(url)
            }
            failures += result.1
        }

        func enqueue(_ srt: URL) {
            let task = Task { [self] in
                await translateOneFile(
                    srt,
                    context: context,
                    snapshot: snapshot,
                    outputDirectory: outputDirectory
                )
            }
            tasks.append(task)
        }

        func drainIfNeeded() async throws {
            while tasks.count >= maxInFlight {
                let task = tasks.removeFirst()
                record(await task.value)
                try Task.checkCancellation()
            }
        }

        for srt in subtitleInputs {
            try Task.checkCancellation()
            enqueue(srt)
            try await drainIfNeeded()
        }

        for (index, input) in mediaInputs.enumerated() {
            try Task.checkCancellation()
            activePhase = .pipelined(
                currentIndex: index,
                totalFiles: mediaCount,
                translatedFiles: pipelinedTranslatedFiles
            )
            statusText = L.tr(
                "pipeline.status.file",
                index + 1,
                mediaCount,
                pipelinedTranslatedFiles
            )
            currentFileName = input.lastPathComponent
            currentFileProgress = 0

            let fileReports = try await service.transcribeBatch(
                inputs: [batchInputs[index]],
                whisperCLIPath: snapshot.whisperCLIPath,
                modelPath: modelPlan.executionModelPath,
                formats: snapshot.outputFormats,
                sourceLanguage: snapshot.sourceLanguage,
                translatesToEnglish: snapshot.translatesToEnglish,
                usesTextContext: snapshot.usesTextContext,
                vadSettings: snapshot.vadSettings,
                onInputStageChange: { [weak self] _, stage in
                    await MainActor.run {
                        guard let self else { return }
                        self.activePhase = .pipelined(
                            currentIndex: index,
                            totalFiles: mediaCount,
                            translatedFiles: self.pipelinedTranslatedFiles
                        )
                        self.statusText = L.tr(
                            "pipeline.status.file",
                            index + 1,
                            mediaCount,
                            self.pipelinedTranslatedFiles
                        )
                        self.currentFileName = input.lastPathComponent
                        switch stage {
                        case .preparing:
                            self.currentStageDescription = stage.description
                            self.currentFileProgress = 0.03
                        case .extractingAudio:
                            self.currentStageDescription = stage.description
                            self.currentFileProgress = max(self.currentFileProgress, 0.12)
                        default:
                            break
                        }
                        self.overallProgress = self.pipelineProgress(
                            fileIndex: index,
                            mediaCount: mediaCount,
                            fileFraction: self.currentFileProgress,
                            translatedFiles: self.pipelinedTranslatedFiles
                        )
                    }
                },
                onStageChange: { [weak self] stage in
                    await MainActor.run {
                        guard let self else { return }
                        switch stage {
                        case .transcribing:
                            self.activePhase = .pipelined(
                                currentIndex: index,
                                totalFiles: mediaCount,
                                translatedFiles: self.pipelinedTranslatedFiles
                            )
                            self.statusText = L.tr(
                                "pipeline.status.file",
                                index + 1,
                                mediaCount,
                                self.pipelinedTranslatedFiles
                            )
                            self.currentStageDescription = stage.description
                            self.currentFileProgress = max(self.currentFileProgress, 0.18)
                        case .finished:
                            self.currentStageDescription = stage.description
                            self.currentTranscriptionProgress = 1
                            self.currentFileProgress = 1
                            self.overallProgress = self.pipelineProgress(
                                fileIndex: index + 1,
                                mediaCount: mediaCount,
                                fileFraction: 0,
                                translatedFiles: self.pipelinedTranslatedFiles
                            )
                        default:
                            break
                        }
                    }
                },
                onLog: { [weak self] line in
                    await MainActor.run {
                        self?.observeRuntimeAccelerationLog(line, expectedCoreML: awaitsCoreMLConfirmation)
                        self?.appendLog(line)
                    }
                },
                onTranscriptionProgress: { [weak self] progress in
                    await MainActor.run {
                        guard let self else { return }
                        self.currentTranscriptionProgress = progress
                        self.currentStageDescription = L.tr("stage.transcribing_progress", Int(progress * 100))
                        self.currentFileProgress = max(0.18, 0.18 + 0.82 * progress)
                        self.overallProgress = self.pipelineProgress(
                            fileIndex: index,
                            mediaCount: mediaCount,
                            fileFraction: self.currentFileProgress,
                            translatedFiles: self.pipelinedTranslatedFiles
                        )
                    }
                },
                onSegment: { [weak self] segment in
                    await MainActor.run {
                        self?.appendLiveSegment(segment)
                    }
                }
            )

            if let report = fileReports.first {
                reports.append(report)
                if let srt = report.outputFiles.first(where: { $0.pathExtension.lowercased() == "srt" }) {
                    enqueue(srt)
                    try await drainIfNeeded()
                }
            }
        }

        let translationTotal = mediaCount + subtitleInputs.count
        activePhase = .translatingFiles(
            currentIndex: translatedFiles.count,
            totalFiles: translationTotal
        )
        statusText = L.tr("pipeline.status.wait", tasks.count)
        currentFileName = ""
        while !tasks.isEmpty {
            let task = tasks.removeFirst()
            record(await task.value)
            try Task.checkCancellation()
            activePhase = .translatingFiles(
                currentIndex: translatedFiles.count,
                totalFiles: translationTotal
            )
        }

        if failures > 0 {
            appendLog(L.tr("pipeline.log.failed_files", failures))
        }
        return (reports, translatedFiles)
    }

    private func pipelineProgress(
        fileIndex: Int,
        mediaCount: Int,
        fileFraction: Double,
        translatedFiles: Int
    ) -> Double {
        guard mediaCount > 0 else { return 0 }
        let transcription = min((Double(fileIndex) + fileFraction) / Double(mediaCount), 1)
        let translation = min(Double(translatedFiles) / Double(mediaCount), 1)
        return min(0.98, transcription * 0.9 + translation * 0.1)
    }

    private func translateOneFile(
        _ srt: URL,
        context: TranslationContext,
        snapshot: AppConfigurationSnapshot,
        outputDirectory: URL?
    ) async -> (URL?, Int) {
        let service = SRTTranslationService(client: context.client)
        appendLog(L.tr("translation.log.file", srt.lastPathComponent))
        do {
            let outcome = try await service.translateFile(
                source: srt,
                language: snapshot.translation.targetLanguage,
                outputMode: snapshot.translation.outputMode,
                polish: snapshot.translation.polish,
                workers: snapshot.translation.workers,
                polishWorkers: snapshot.translation.backend == .api
                    ? min(snapshot.translation.workers, Spec.defaultPolishWorkers)
                    : 1,
                outputDirectory: outputDirectory,
                onProgress: nil
            )
            lastTranslationCount += outcome.translatedCount
            lastTranslationFailureCount += outcome.errorCount
            pipelinedTranslatedFiles += 1
            appendLog(L.tr(
                "translation.log.done",
                outcome.outputURL.lastPathComponent,
                outcome.translatedCount,
                outcome.cueCount
            ))
            return (outcome.outputURL, 0)
        } catch is CancellationError {
            return (nil, 1)
        } catch {
            lastTranslationFailureCount += 1
            appendLog(L.tr("translation.log.failed", srt.lastPathComponent, error.localizedDescription))
            return (nil, 1)
        }
    }

    private func translateTranscripts(
        _ srtFiles: [URL],
        outputDirectory: URL?,
        context: TranslationContext,
        snapshot: AppConfigurationSnapshot
    ) async throws -> (files: [URL], failures: Int) {
        let service = SRTTranslationService(client: context.client)
        var files: [URL] = []
        var failures = 0
        let total = srtFiles.count

        for (index, srt) in srtFiles.enumerated() {
            try Task.checkCancellation()
            activePhase = .translatingFiles(currentIndex: index, totalFiles: total)
            currentFileName = srt.lastPathComponent
            currentStageDescription = L.tr("stage.translating")
            currentFileProgress = 0
            statusText = L.tr("translation.status.file", index + 1, total, srt.lastPathComponent)
            appendLog(L.tr("translation.log.file", srt.lastPathComponent))

            do {
                let outcome = try await service.translateFile(
                    source: srt,
                    language: snapshot.translation.targetLanguage,
                    outputMode: snapshot.translation.outputMode,
                    polish: snapshot.translation.polish,
                    workers: snapshot.translation.workers,
                    polishWorkers: snapshot.translation.backend == .api
                        ? min(snapshot.translation.workers, Spec.defaultPolishWorkers)
                        : 1,
                    outputDirectory: outputDirectory,
                    onProgress: { cue in
                        Task { @MainActor [weak self] in
                            guard let self, self.isRunning else { return }
                            let fraction = cue.fraction
                            self.currentFileProgress = fraction
                            self.overallProgress = 0.85 + 0.15 * ((Double(index) + fraction) / Double(max(total, 1)))
                            self.currentStageDescription = cue.stage == .translating
                                ? L.tr("stage.translating_progress", cue.completed, cue.total)
                                : L.tr("stage.polishing_progress", cue.completed, cue.total)
                        }
                    }
                )
                files.append(outcome.outputURL)
                lastTranslationCount += outcome.translatedCount
                lastTranslationFailureCount += outcome.errorCount
                appendLog(L.tr(
                    "translation.log.done",
                    outcome.outputURL.lastPathComponent,
                    outcome.translatedCount,
                    outcome.cueCount
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                lastTranslationFailureCount += 1
                appendLog(L.tr("translation.log.failed", srt.lastPathComponent, error.localizedDescription))
            }
        }

        return (files, failures)
    }

    private func observeRuntimeAccelerationLog(_ line: String, expectedCoreML: Bool) {
        guard expectedCoreML, let signal = RuntimeAccelerationSignal.parse(line) else { return }
        switch signal {
        case .coreMLLoaded:
            runCoreMLStatus = .loaded
            runEffectiveMode = .gpuAndANE
            appendLog(L.tr("log.coreml_runtime_loaded"))
        case .coreMLFailed:
            runCoreMLStatus = .failed
            runEffectiveMode = .pureGPU
            appendLog(L.tr("log.coreml_runtime_failed"))
        }
    }

    private func installPreviewFiles(
        from reports: [TranscriptionReport],
        translatedFiles: [URL],
        subtitleInputs: [URL]
    ) {
        var files: [TranscriptPreviewFile] = []
        let transcriptSRTs = reports.flatMap(\.outputFiles).filter { $0.pathExtension.lowercased() == "srt" }
        let candidates: [URL]
        if !translatedFiles.isEmpty {
            candidates = translatedFiles
        } else if !transcriptSRTs.isEmpty {
            candidates = transcriptSRTs
        } else {
            candidates = subtitleInputs
        }
        files.reserveCapacity(candidates.count)
        for output in candidates {
            files.append(TranscriptPreviewFile(
                id: output,
                url: output,
                displayName: output.lastPathComponent
            ))
        }
        guard let last = files.last else { return }
        previewFiles = files
        selectedPreviewFileID = last.id
        loadPreviewSegments(for: last.id)
    }

    func selectPreviewFile(id: URL?) {
        guard id != selectedPreviewFileID else { return }
        selectedPreviewFileID = id
        loadPreviewSegments(for: id)
    }

    private func loadPreviewSegments(for fileID: URL?) {
        previewLoadGeneration += 1
        let generation = previewLoadGeneration
        guard let fileID, let file = previewFiles.first(where: { $0.id == fileID }) else {
            previewSegments = []
            isLoadingPreview = false
            return
        }
        let url = file.url
        isLoadingPreview = true
        previewSegments = []
        Task { [weak self] in
            let segments = await Self.readSegments(url: url)
            guard let self, generation == self.previewLoadGeneration else { return }
            self.previewSegments = segments
            self.isLoadingPreview = false
        }
    }

    /// Runs off the main actor (nonisolated async functions execute on the global
    /// executor); read failures yield an empty list so the UI shows a hint instead.
    private nonisolated static func readSegments(url: URL) async -> [TranscriptSegment] {
        (try? SRTParser.load(at: url)) ?? []
    }

    private func clearPreviews() {
        previewLoadGeneration += 1
        previewFiles = []
        selectedPreviewFileID = nil
        previewSegments = []
        isLoadingPreview = false
    }

    /// Hands the live section over to the static preview (or to nothing after a
    /// cancellation); the UI hides the live section once isRunning flips false.
    private func appendLiveSegment(_ segment: TranscriptSegment) {
        liveSegments = TranscriptPreview.appendCapped(
            segment,
            to: liveSegments,
            limit: TranscriptPreview.liveSegmentLimit
        )
    }

    // MARK: - History

    func revealHistoryEntryInFinder(_ entry: HistoryEntry) {
        if let firstOutputPath = entry.outputFilePaths.first,
           FileManager.default.fileExists(atPath: firstOutputPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: firstOutputPath)])
            return
        }

        let outputDirectory = URL(fileURLWithPath: entry.outputDirectoryPath)
        guard FileManager.default.fileExists(atPath: outputDirectory.path) else { return }
        NSWorkspace.shared.open(outputDirectory)
    }

    func clearHistory() {
        historyEntries = []
        let store = historyStore
        Task {
            await Self.eraseHistory(store: store)
        }
    }

    private func loadHistoryFromStore() {
        let store = historyStore
        Task { [weak self] in
            let entries = await Self.readHistory(store: store)
            self?.historyEntries = entries
        }
    }

    /// History is best-effort: recording failures are swallowed and the store
    /// is simply re-read so the published list matches what is on disk.
    private func recordHistoryEntries(
        reports: [TranscriptionReport],
        inputFiles: [URL],
        outputDirectories: [URL],
        durationSeconds: Double
    ) {
        guard !reports.isEmpty else { return }
        let entries = TranscriptionHistoryStore.makeEntries(
            reports: reports,
            inputFiles: inputFiles,
            outputDirectories: outputDirectories,
            durationSeconds: durationSeconds
        )
        let store = historyStore
        Task { [weak self] in
            let loaded = await Self.writeHistory(store: store, entries: entries)
            self?.historyEntries = loaded
        }
    }

    /// Runs off the main actor (nonisolated async functions execute on the
    /// global executor), keeping history file I/O out of the UI.
    private nonisolated static func readHistory(store: TranscriptionHistoryStore) async -> [HistoryEntry] {
        store.load()
    }

    private nonisolated static func writeHistory(store: TranscriptionHistoryStore, entries: [HistoryEntry]) async -> [HistoryEntry] {
        try? store.record(entries)
        return store.load()
    }

    private nonisolated static func eraseHistory(store: TranscriptionHistoryStore) async {
        try? store.clear()
    }

    /// The single funnel every run path (success/failure/cancel) flows through:
    /// releases the keep-awake assertion by dropping it and posts the completion
    /// notification unless the batch was cancelled.
    private func finishTranscriptionRun(
        successCount: Int = 0,
        failureCount: Int = 0,
        wasCancelled: Bool = false
    ) async {
        liveSegments = []
        isRunning = false
        isCancelling = false
        transcriptionTask = nil
        keepAwakeToken = nil
        activePhase = nil
        activeSnapshot = nil
        runEffectiveMode = nil
        await completionNotifier.notifyBatchFinished(
            successCount: successCount,
            failureCount: failureCount,
            wasCancelled: wasCancelled
        )
    }

    private func downloadMissingRuntime(_ missing: Set<RuntimeComponent>) async {
        isDownloadingRuntime = true
        downloadedBytes = 0
        downloadTotalBytes = nil
        statusText = L.tr("status.runtime_preparing_download")
        appendLog(L.tr("log.runtime_download_start"))

        do {
            guard let baseURL = resolvedHuggingFaceBaseURL else { throw HuggingFaceDownloadError.invalidEndpoint }
            let result = try await RuntimeInstaller.install(missing: missing, baseURL: baseURL) { [weak self] event in
                await MainActor.run {
                    guard let self else { return }
                    switch event {
                    case .status(let status):
                        self.statusText = status
                    case .log(let line):
                        self.appendLog(line)
                    case .progress(let bytesDownloaded, let totalBytes):
                        self.downloadedBytes = bytesDownloaded
                        self.downloadTotalBytes = totalBytes
                    }
                }
            }

            // The installer placed new files on disk; cached resolution
            // results for unchanged inputs must not shadow them.
            PathResolver.invalidateCaches()

            if let modelPath = result.modelPath {
                self.modelPath = modelPath
            }

            statusText = L.tr("status.runtime_ready")
        } catch is CancellationError {
            statusText = L.tr("status.download_cancelled")
            appendLog(L.tr("log.download_cancelled"))
        } catch {
            appendLog(error.localizedDescription)
            statusText = L.tr("status.runtime_download_failed")
        }

        isDownloadingRuntime = false
        runtimeDownloadTask = nil
    }

    private func installVADModel() async {
        isDownloadingVADModel = true
        downloadedBytes = 0
        downloadTotalBytes = nil
        statusText = L.tr("status.runtime_preparing_download")
        do {
            guard let baseURL = resolvedHuggingFaceBaseURL else { throw HuggingFaceDownloadError.invalidEndpoint }
            let path = try await vadModelInstaller(baseURL) { [weak self] event in
                await MainActor.run {
                    guard let self else { return }
                    switch event {
                    case .status(let status): self.statusText = status
                    case .log(let line): self.logs.append(line)
                    case .progress(let bytes, let total):
                        self.downloadedBytes = bytes
                        self.downloadTotalBytes = total
                    }
                }
            }
            vadSettings.modelPath = ""
            guard !resolvedVADModelPath.isEmpty else {
                throw VADModelResolutionError.missing(path)
            }
            statusText = L.tr("status.runtime_ready")
        } catch is CancellationError {
            statusText = L.tr("status.download_cancelled")
        } catch {
            logs.append(error.localizedDescription)
            statusText = L.tr("status.runtime_download_failed")
        }
        isDownloadingVADModel = false
        vadDownloadTask = nil
    }

    private func appendLog(_ line: String) {
        logs.append(line)
    }

    private func runtimeComponentsMissing(whisperCLIPath: String, modelPath: String) -> Set<RuntimeComponent> {
        var missing = Set<RuntimeComponent>()
        let resolvedWhisperCLIPath = PathResolver.resolveWhisperCLIPath(whisperCLIPath)
        let resolvedModelPath = PathResolver.resolveModelPath(modelPath, whisperCLIPath: resolvedWhisperCLIPath)

        if resolvedWhisperCLIPath.isEmpty {
            missing.insert(.whisperCLI)
        }

        if resolvedModelPath.isEmpty {
            missing.insert(.model)
        }

        if !missing.contains(.model), accelerationMode == .gpuAndANE {
            let modelURL = URL(fileURLWithPath: resolvedModelPath)
            let coreMLURL = OutputPaths.coreMLModelURL(for: modelURL)
            if !FileManager.default.fileExists(atPath: coreMLURL.path) {
                missing.insert(.coreMLEncoder)
            }
        }

        return missing
    }

    private var providersFileURL: URL {
        supportDirectory.appending(path: "providers.json")
    }

    private func store(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private var resolvedWhisperCLIPath: String {
        PathResolver.resolveWhisperCLIPath(whisperCLIPath)
    }

    private var resolvedModelPath: String {
        PathResolver.resolveModelPath(modelPath, whisperCLIPath: resolvedWhisperCLIPath)
    }

    private func resolvedOutputDirectoryPath(for inputURL: URL?, overridePath: String? = nil) -> String {
        let trimmed = (overridePath ?? outputDirectoryPath).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return PathResolver.expandingTilde(trimmed)
        }
        if let inputURL {
            return inputURL.deletingLastPathComponent().path
        }
        return ""
    }
}

private enum Keys {
    static let appLanguage = "appLanguage"
    static let outputDirectoryPath = "outputDirectoryPath"
    static let whisperCLIPath = "whisperCLIPath"
    static let modelPath = "modelPath"
    static let accelerationMode = "accelerationMode"
    static let outputFormats = "outputFormats"
    static let sourceLanguage = "sourceLanguage"
    static let translatesToEnglish = "translatesToEnglish"
    static let usesTextContext = "usesTextContext"
    static let vadSettings = "vadSettings"
    static let huggingFaceDownloadSource = "huggingFaceDownloadSource"
    static let customHuggingFaceEndpoint = "customHuggingFaceEndpoint"
    static let translationSettings = "translationSettings"
    static let autoCheckUpdates = "autoCheckUpdates"
}

private enum HuggingFaceDownloadError: LocalizedError {
    case invalidEndpoint
    var errorDescription: String? { L.tr("hf.endpoint.invalid") }
}
