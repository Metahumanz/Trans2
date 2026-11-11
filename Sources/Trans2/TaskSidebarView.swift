import SwiftUI
import TransCore

/// Left rail: the task queue on top, the settings that shape the next run
/// underneath. Keeping translation and output controls next to the queue means
/// the common path — add files, choose a target language, start — never needs
/// a modal sheet.
struct TaskSidebarView: View {
    @EnvironmentObject private var model: AppModel
    let openSettings: (SettingsTab) -> Void

    @State private var showsTranslationAdvanced = false

    private var isLocked: Bool { model.isRunning || model.isScanningMedia }

    var body: some View {
        VStack(spacing: 0) {
            queueSection
            Divider()
            settingsSection
        }
        .frame(width: TaskWorkspaceMetrics.queueWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L.tr("queue.title")))
    }

    // MARK: - Queue

    private var queueSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L.tr("queue.title"))
                    .font(.system(size: UITypographyScale.scaled(13), weight: .semibold))
                Spacer()
                Text(L.tr("label.file_count", model.inputFiles.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.chooseInputFiles()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(isLocked)
                .help(L.tr("button.add_media"))
                .accessibilityLabel(Text(L.tr("button.add_media")))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if model.inputFiles.isEmpty {
                VStack(spacing: 4) {
                    Text(L.tr("queue.empty.title"))
                        .font(.system(size: UITypographyScale.scaled(13)))
                    Text(L.tr("queue.empty.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .center)
            } else {
                List(model.inputFiles, id: \.path) { url in
                    queueRow(url)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: queueListHeight)
            }

            queueFooter
        }
    }

    /// Five rows are enough to see the shape of a batch; longer queues scroll
    /// inside the rail instead of pushing the settings out of reach.
    private var queueListHeight: CGFloat {
        let visible = min(max(model.inputFiles.count, 1), 5)
        return CGFloat(visible) * 54
    }

    private func queueRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconForExtension(url.pathExtension))
                .font(.system(size: UITypographyScale.scaled(14)))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: UITypographyScale.scaled(13)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if !isLocked {
                Button {
                    model.removeInputFile(url)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L.tr("button.remove"))
                .accessibilityValue(Text(url.lastPathComponent))
            }
        }
        .padding(.vertical, 7)
        .help(url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(url.lastPathComponent), \(url.deletingLastPathComponent().path)"))
    }

    private var queueFooter: some View {
        HStack(spacing: 8) {
            if isLocked {
                Image(systemName: "lock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L.tr("queue.locked"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(L.tr("privacy.local"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button(L.tr("button.clear_list")) {
                model.clearInputFiles()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(model.inputFiles.isEmpty || model.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func iconForExtension(_ pathExtension: String) -> String {
        let ext = pathExtension.lowercased()
        if ext == "srt" { return "captions.bubble" }
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        return videoExtensions.contains(ext) ? "film" : "music.note"
    }

    // MARK: - Settings

    private var settingsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                translationSection
                Divider()
                transcriptionSection
                Divider()
                outputSection
            }
            .padding(16)
            .disabled(model.isBusy)
            .opacity(model.isBusy ? 0.55 : 1)
        }
        .frame(maxHeight: .infinity)
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SidebarHeader(title: L.tr("settings.section.translation"))
                Spacer()
                Toggle("", isOn: $model.translationSettings.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(L.tr("translation.enabled"))
            }

            if model.translationSettings.isEnabled {
                SidebarField( L.tr("translation.engine")) {
                    Picker("", selection: $model.translationSettings.backend) {
                        Text(L.tr("translation.engine.api")).tag(Engine.api)
                        Text(L.tr("translation.engine.ollama")).tag(Engine.ollama)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SidebarField( L.tr("translation.target_language")) {
                    Picker("", selection: $model.translationSettings.targetLanguage) {
                        ForEach(Language.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if model.translationSettings.backend == .api {
                    SidebarField( L.tr("translation.provider")) {
                        providerRow
                    }
                } else {
                    SidebarField( L.tr("translation.ollama_model")) {
                        TextField("qwen2.5", text: $model.translationSettings.ollamaModel)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }
                }

                SidebarField( L.tr("translation.timing")) {
                    Picker("", selection: $model.translationSettings.timing) {
                        ForEach(TranslationTiming.allCases) { timing in
                            Text(timing.title).tag(timing)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(model.translationSettings.timing.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup(L.tr("sidebar.more_translation"), isExpanded: $showsTranslationAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        SidebarField( L.tr("translation.output_mode")) {
                            Picker("", selection: $model.translationSettings.outputMode) {
                                ForEach(TranslationOutputMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Toggle(L.tr("translation.polish"), isOn: $model.translationSettings.polish)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)

                if !translationProviderReady {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: .systemOrange))
                        Text(L.tr("sidebar.translation.not_ready"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text(L.tr("sidebar.translation.off_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if model.providers.isEmpty {
                    Text(L.tr("translation.provider.none"))
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("", selection: providerSelection) {
                        ForEach(model.providers) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    openSettings(.providers)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L.tr("translation.manage_providers"))
                .accessibilityLabel(Text(L.tr("translation.manage_providers")))
            }
            if let provider = model.activeProvider, !model.translationModelName.isEmpty {
                Text(provider.model)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        guard model.translationSettings.isEnabled else { return true }
        switch model.translationSettings.backend {
        case .ollama:
            return !model.translationModelName.isEmpty
        case .api:
            return model.activeProvider != nil && !model.translationModelName.isEmpty
        }
    }

    private var transcriptionSection: some View {
        settingsSummaryRow(
            title: L.tr("sidebar.section.transcribe"),
            summary: transcriptionSummary,
            tab: .transcription
        )
    }

    private var transcriptionSummary: String {
        let language = languageDisplayName(forCode: model.sourceLanguage)
        let vad = model.vadSettings.isEnabled ? L.tr("common.on") : L.tr("common.off")
        return "\(language) · VAD \(vad)"
    }

    private var outputSection: some View {
        settingsSummaryRow(
            title: L.tr("sidebar.section.output"),
            summary: outputSummary,
            tab: .output
        )
    }

    private var outputSummary: String {
        let formats = formatsSummaryText(model.outputFormats)
        let location = outputLocationDisplayText(model.outputDirectoryPath)
        return "\(formats) · \(location)"
    }

    private func settingsSummaryRow(title: String, summary: String, tab: SettingsTab) -> some View {
        HStack(spacing: 8) {
            SidebarHeader(title: title)
            Spacer(minLength: 6)
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                openSettings(tab)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help(L.tr("sidebar.open_settings"))
            .accessibilityLabel(Text(L.tr("sidebar.open_settings")))
        }
    }


}

private struct SidebarHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: UITypographyScale.scaled(13), weight: .semibold))
    }
}

private struct SidebarField<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}
