import SwiftUI
import TransCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case transcription
    case translation
    case output
    case providers
    case runtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L.tr("settings.tab.general")
        case .transcription: return L.tr("settings.tab.transcription")
        case .translation: return L.tr("settings.tab.translation")
        case .output: return L.tr("settings.tab.output")
        case .providers: return L.tr("settings.tab.providers")
        case .runtime: return L.tr("settings.tab.runtime")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .translation: return "character.book.closed"
        case .output: return "folder"
        case .providers: return "server.rack"
        case .runtime: return "cpu"
        }
    }
}

/// One settings window, grouped by the part of the pipeline it controls.
/// Task-level controls stay in the left rail; everything that is configured
/// once (paths, providers, defaults) lives here.
struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var tab: SettingsTab

    init(initialTab: SettingsTab = .general) {
        var resolved = initialTab
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["TRANS2_DEBUG_SETTINGS_TAB"],
           let debugTab = SettingsTab(rawValue: raw) {
            resolved = debugTab
        }
        #endif
        _tab = State(initialValue: resolved)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.tr("settings.title"))
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(L.tr("button.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            TabView(selection: $tab) {
                GeneralSettingsTab()
                    .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage) }
                    .tag(SettingsTab.general)

                TranscriptionSettingsTab()
                    .tabItem { Label(SettingsTab.transcription.title, systemImage: SettingsTab.transcription.systemImage) }
                    .tag(SettingsTab.transcription)

                TranslationSettingsTab(openProviders: { tab = .providers })
                    .tabItem { Label(SettingsTab.translation.title, systemImage: SettingsTab.translation.systemImage) }
                    .tag(SettingsTab.translation)

                OutputSettingsTab()
                    .tabItem { Label(SettingsTab.output.title, systemImage: SettingsTab.output.systemImage) }
                    .tag(SettingsTab.output)

                TranslationProviderManager()
                    .padding(16)
                    .tabItem { Label(SettingsTab.providers.title, systemImage: SettingsTab.providers.systemImage) }
                    .tag(SettingsTab.providers)

                RuntimeSettingsTab()
                    .tabItem { Label(SettingsTab.runtime.title, systemImage: SettingsTab.runtime.systemImage) }
                    .tag(SettingsTab.runtime)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(width: 820, height: 660)
    }
}

private struct SettingsPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsPane {
            GroupBox(L.tr("settings.section.general")) {
                LabeledRow(title: L.tr("label.interface_language")) {
                    Picker(L.tr("label.interface_language"), selection: $model.appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 200, alignment: .leading)
                }
                .padding(.vertical, 4)
            }

            GroupBox(L.tr("settings.updates")) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(title: L.tr("settings.current_version")) {
                        Text("v\(model.appVersion)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Toggle(L.tr("settings.auto_check_updates"), isOn: $model.autoCheckUpdates)

                    HStack(spacing: 10) {
                        Button(L.tr("settings.check_updates")) {
                            model.checkForUpdates()
                        }
                        .disabled(model.isCheckingForUpdates)

                        if model.isCheckingForUpdates {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.updateStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let info = model.updateInfo {
                        Divider()
                        Text(L.tr("settings.update_available", info.version))
                            .font(.headline)
                        if !info.notes.isEmpty {
                            ScrollView {
                                Text(plainNotes(info.notes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 150)
                        }
                        HStack(spacing: 10) {
                            Button(L.tr("settings.download_update")) {
                                model.downloadUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isDownloadingUpdate)

                            Button(L.tr("settings.open_release_page")) {
                                model.openUpdatePage()
                            }
                            .buttonStyle(.bordered)

                            if model.isDownloadingUpdate {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }

                    if model.downloadedUpdate != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(nsColor: .systemGreen))
                            Text(model.updateStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                            Button(L.tr("settings.show_download")) {
                                model.revealDownloadedUpdate()
                            }
                            .font(.caption)
                        }
                    }

                    DisclosureGroup(L.tr("settings.private_repo")) {
                        VStack(alignment: .leading, spacing: 6) {
                            SecureField(L.tr("settings.github_token"), text: $model.githubUpdateToken)
                                .textFieldStyle(.roundedBorder)
                            Text(L.tr("settings.github_token_hint"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }

            Text(L.tr("settings.privacy_note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// SwiftUI's Text only understands inline Markdown; keep the generated
    /// release notes readable by dropping block markers but preserving lines.
    private func plainNotes(_ notes: String) -> String {
        notes.components(separatedBy: .newlines).map { raw in
            var line = raw
            line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^---+$"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            line = line.replacingOccurrences(of: #"^_(.+)_$"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(
                of: #"\[([^\]]+)\]\([^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            return line
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TranscriptionSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsVADAdvanced = false

    var body: some View {
        SettingsPane {
            GroupBox(L.tr("options.section.transcribe")) {
                VStack(spacing: 12) {
                    LabeledRow(title: L.tr("label.audio_language")) {
                        Picker("", selection: $model.sourceLanguage) {
                            Text(WhisperLanguage.auto.displayName).tag(WhisperLanguage.autoCode)
                            ForEach(WhisperLanguage.common) { language in
                                Text(language.displayName).tag(language.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(minWidth: 220, alignment: .leading)
                    }

                    LabeledRow(title: L.tr("toggle.translate_to_english")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("", isOn: $model.translatesToEnglish)
                                .labelsHidden()
                            Text(L.tr("hint.translate_to_english"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LabeledRow(title: L.tr("text_context.title")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("", isOn: $model.usesTextContext)
                                .labelsHidden()
                            Text(L.tr("text_context.hint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox(L.tr("vad.title")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L.tr("vad.enable"), isOn: $model.vadSettings.isEnabled)

                    if model.vadSettings.isEnabled {
                        HStack(spacing: 8) {
                            StatusDot(color: model.hasResolvableVADModel
                                ? Color(nsColor: .systemGreen)
                                : Color(nsColor: .systemOrange))
                            Text(model.hasResolvableVADModel
                                ? L.tr("vad.model_available", URL(fileURLWithPath: model.resolvedVADModelPath).lastPathComponent)
                                : L.tr("vad.model_missing_short"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if !model.hasResolvableVADModel {
                                Button(L.tr("vad.download")) { model.downloadVADModel() }
                                    .disabled(!model.canDownloadRuntimeAssets)
                            }
                        }

                        LabeledRow(title: L.tr("vad.threshold")) {
                            HStack(spacing: 12) {
                                Slider(value: $model.vadSettings.threshold, in: 0...1, step: 0.05)
                                Text(String(format: "%.2f", model.vadSettings.threshold))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 42, alignment: .trailing)
                            }
                            .frame(maxWidth: 380)
                        }

                        DisclosureGroup(L.tr("vad.advanced"), isExpanded: $showsVADAdvanced) {
                            VStack(alignment: .leading, spacing: 10) {
                                vadDurationSlider(
                                    title: L.tr("vad.min_speech"),
                                    value: $model.vadSettings.minSpeechDurationMs,
                                    range: 0...2_000,
                                    step: 50
                                )
                                vadDurationSlider(
                                    title: L.tr("vad.min_silence"),
                                    value: $model.vadSettings.minSilenceDurationMs,
                                    range: 0...2_000,
                                    step: 50
                                )
                                vadDurationSlider(
                                    title: L.tr("vad.speech_pad"),
                                    value: $model.vadSettings.speechPadMs,
                                    range: 0...1_000,
                                    step: 25
                                )
                            }
                            .padding(.top, 8)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox(L.tr("section.runtime")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L.tr("label.acceleration_mode"), selection: $model.accelerationMode) {
                        ForEach(AccelerationMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 340, alignment: .leading)

                    Text(model.accelerationDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.accelerationSummary)
                        .font(.callout)
                        .foregroundStyle(model.configurationLooksReady
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Color(nsColor: .systemOrange)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func vadDurationSlider(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        LabeledRow(title: title) {
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { Double(value.wrappedValue) },
                        set: { value.wrappedValue = Int($0.rounded()) }
                    ),
                    in: range,
                    step: step
                )
                Text(L.tr("vad.milliseconds", Int64(value.wrappedValue)))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 64, alignment: .trailing)
            }
            .frame(maxWidth: 380)
        }
    }
}

private struct TranslationSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    let openProviders: () -> Void

    var body: some View {
        SettingsPane {
            GroupBox(L.tr("settings.section.translation")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L.tr("translation.enabled"), isOn: $model.translationSettings.isEnabled)

                    if model.translationSettings.isEnabled {
                        LabeledRow(title: L.tr("translation.timing")) {
                            VStack(alignment: .leading, spacing: 4) {
                                Picker("", selection: $model.translationSettings.timing) {
                                    ForEach(TranslationTiming.allCases) { timing in
                                        Text(timing.title).tag(timing)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(minWidth: 240, alignment: .leading)
                                Text(model.translationSettings.timing.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        LabeledRow(title: L.tr("translation.engine")) {
                            Picker("", selection: $model.translationSettings.backend) {
                                Text(L.tr("translation.engine.api")).tag(Engine.api)
                                Text(L.tr("translation.engine.ollama")).tag(Engine.ollama)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 240, alignment: .leading)
                        }

                        LabeledRow(title: L.tr("translation.target_language")) {
                            Picker("", selection: $model.translationSettings.targetLanguage) {
                                ForEach(Language.allCases, id: \.self) { language in
                                    Text(language.displayName).tag(language)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 200, alignment: .leading)
                        }

                        if model.translationSettings.backend == .api {
                            LabeledRow(title: L.tr("translation.provider")) {
                                HStack(spacing: 8) {
                                    if model.providers.isEmpty {
                                        Text(L.tr("translation.provider.none"))
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Picker("", selection: providerSelection) {
                                            ForEach(model.providers) { provider in
                                                Text(provider.name).tag(provider.id)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .labelsHidden()
                                        .frame(width: 220, alignment: .leading)
                                    }
                                    Button(L.tr("translation.manage_providers")) {
                                        openProviders()
                                    }
                                }
                            }
                            LabeledRow(title: L.tr("translation.model")) {
                                Text(model.translationModelName.isEmpty
                                    ? L.tr("translation.model.none")
                                    : model.translationModelName)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            LabeledRow(title: L.tr("translation.ollama_model")) {
                                TextField("qwen2.5", text: $model.translationSettings.ollamaModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                            }
                        }

                        LabeledRow(title: L.tr("translation.output_mode")) {
                            Picker("", selection: $model.translationSettings.outputMode) {
                                ForEach(TranslationOutputMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 240, alignment: .leading)
                        }

                        Toggle(L.tr("translation.polish"), isOn: $model.translationSettings.polish)

                        if !translationProviderReady {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color(nsColor: .systemOrange))
                                Text(L.tr("sidebar.translation.not_ready"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(L.tr("sidebar.translation.off_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if model.translationSettings.isEnabled {
                GroupBox(L.tr("settings.concurrency")) {
                    VStack(spacing: 10) {
                        stepperRow(
                            title: L.tr("settings.api_workers"),
                            value: $model.translationSettings.apiWorkers,
                            range: 1...64
                        )
                        stepperRow(
                            title: L.tr("settings.api_retries"),
                            value: $model.translationSettings.apiRetries,
                            range: 0...5
                        )
                        stepperRow(
                            title: L.tr("settings.ollama_workers"),
                            value: $model.translationSettings.ollamaWorkers,
                            range: 1...64
                        )
                        stepperRow(
                            title: L.tr("settings.ollama_retries"),
                            value: $model.translationSettings.ollamaRetries,
                            range: 0...5
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { model.activeProviderID ?? model.providers.first?.id ?? "" },
            set: { model.setActiveProvider(id: $0) }
        )
    }

    private var translationProviderReady: Bool {
        switch model.translationSettings.backend {
        case .ollama:
            return !model.translationModelName.isEmpty
        case .api:
            return model.activeProvider != nil && !model.translationModelName.isEmpty
        }
    }

    private func stepperRow(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        LabeledRow(title: title) {
            HStack(spacing: 10) {
                Stepper("", value: value, in: range)
                    .labelsHidden()
                Text("\(value.wrappedValue)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }
}

private struct OutputSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsPane {
            GroupBox(L.tr("sidebar.section.output")) {
                VStack(spacing: 14) {
                    LabeledRow(title: L.tr("label.output_directory")) {
                        HStack(spacing: 8) {
                            Menu {
                                Button(L.tr("options.output.follow")) {
                                    model.outputDirectoryPath = ""
                                }
                                if !model.outputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button(model.outputDirectoryPath) {}
                                        .disabled(true)
                                }
                                Divider()
                                Button(L.tr("options.output.choose")) {
                                    model.chooseOutputDirectory()
                                }
                            } label: {
                                HStack {
                                    Text(outputLocationDisplayText(model.outputDirectoryPath))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .frame(minWidth: 320, idealWidth: 380, maxWidth: 520, alignment: .leading)

                            Button(L.tr("settings.output.open")) {
                                model.openOutputDirectory()
                            }
                        }
                    }

                    LabeledRow(title: L.tr("label.export_formats")) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading),
                            ],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            formatToggle(.txt)
                            formatToggle(.srt)
                            formatToggle(.vtt)
                            formatToggle(.json)
                        }
                        .frame(maxWidth: 360, alignment: .leading)
                    }

                    Text(L.tr("options.formats.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L.tr("sidebar.output.auto_srt"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func formatToggle(_ format: OutputFormat) -> some View {
        Toggle(L.tr("toggle.export_\(format.rawValue)"), isOn: formatBinding(for: format))
            .disabled(model.isBusy || model.outputFormats == [format])
    }

    private func formatBinding(for format: OutputFormat) -> Binding<Bool> {
        Binding(
            get: { model.outputFormats.contains(format) },
            set: { enabled in model.setFormat(format, enabled: enabled) }
        )
    }
}

private struct RuntimeSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsPane {
            GroupBox(L.tr("settings.section.paths")) {
                VStack(spacing: 12) {
                    pathRow(title: L.tr("field.whisper_cli"), text: $model.whisperCLIPath) {
                        model.chooseWhisperCLI()
                    }
                    pathRow(title: L.tr("field.model_file"), text: $model.modelPath) {
                        model.chooseModel()
                    }
                    vadModelPathRow
                    HStack(spacing: 8) {
                        StatusDot(color: model.hasResolvableVADModel
                            ? Color(nsColor: .systemGreen)
                            : Color(nsColor: .systemOrange))
                        Text(model.hasResolvableVADModel
                            ? L.tr("vad.model_available", URL(fileURLWithPath: model.resolvedVADModelPath).lastPathComponent)
                            : L.tr("vad.model_missing_short"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if model.isDownloadingVADModel {
                            Button(L.tr("button.cancel_download"), role: .destructive) {
                                model.cancelVADModelDownload()
                            }
                        } else if !model.hasResolvableVADModel {
                            Button(L.tr("vad.download")) { model.downloadVADModel() }
                                .disabled(!model.canDownloadRuntimeAssets)
                        }
                    }
                    if model.isDownloadingVADModel {
                        HStack(spacing: 12) {
                            if let progress = model.downloadProgress {
                                ProgressView(value: progress).frame(width: 200)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            Text(model.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox(L.tr("hf.section")) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(title: L.tr("hf.source.label")) {
                        Picker(L.tr("hf.source.label"), selection: $model.huggingFaceDownloadSource) {
                            ForEach(HuggingFaceDownloadSource.allCases) { source in
                                Text(source.displayName).tag(source)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 230, alignment: .leading)
                        .disabled(model.isBusy)
                    }
                    if model.huggingFaceDownloadSource == .custom {
                        LabeledRow(title: L.tr("hf.endpoint.custom")) {
                            TextField("https://example.com", text: $model.customHuggingFaceEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.isBusy)
                        }
                    }
                    LabeledRow(title: L.tr("hf.endpoint.current")) {
                        Text(model.huggingFaceEndpointDisplayText)
                            .font(.callout.monospaced())
                            .foregroundStyle(model.isHuggingFaceEndpointInvalid
                                ? Color(nsColor: .systemOrange)
                                : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.isHuggingFaceEndpointInvalid {
                        Text(L.tr("hf.endpoint.invalid_detail"))
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                    }
                    if model.hasHuggingFaceEnvironmentOverride {
                        Text(L.tr("hf.endpoint.environment_override", HuggingFaceEndpoint.environmentVariableName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    downloadStatusRow
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var vadModelPathRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledRow(title: L.tr("vad.model_path")) {
                HStack(spacing: 8) {
                    TextField(L.tr("vad.model_path_unavailable"), text: .constant(model.vadModelDisplayPath))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                        .textSelection(.enabled)
                    Button(L.tr("button.choose")) { model.chooseVADModel() }
                        .disabled(model.isBusy)
                }
            }
            HStack(spacing: 8) {
                Text(model.isVADModelUsingAutomaticPath ? L.tr("vad.path_automatic") : L.tr("vad.path_manual"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.vadSettings.modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(L.tr("vad.restore_automatic")) { model.restoreAutomaticVADModel() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(model.isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var downloadStatusRow: some View {
        if model.isDownloadingRuntime {
            HStack(spacing: 12) {
                if let progress = model.downloadProgress {
                    ProgressView(value: progress)
                        .frame(width: 200)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button(L.tr("button.cancel_download"), role: .destructive) {
                    model.cancelRuntimeDownload()
                }
            }
        } else if !model.downloadableRuntimeComponents.isEmpty {
            HStack(spacing: 12) {
                Button(L.tr("button.download_runtime")) {
                    model.startRuntimeDownload()
                }
                .disabled(!model.canDownloadRuntimeAssets)
                Text(L.tr("privacy.download"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pathRow(title: String, text: Binding<String>, choose: @escaping () -> Void) -> some View {
        LabeledRow(title: title) {
            HStack(spacing: 8) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                Button(L.tr("button.choose"), action: choose)
                    .disabled(model.isBusy)
            }
        }
    }
}
