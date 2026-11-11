import SwiftUI
import TransCore

/// Provider management for the translation stage. Mirrors AITrans' provider
/// sheet: presets, per-provider keys in a local 0600 file, connectivity test,
/// and a one-click import of an existing AITrans install.
///
/// Embedded as the "提供商" tab of the settings window; it owns no window
/// chrome of its own.
struct TranslationProviderManager: View {
    @EnvironmentObject private var model: AppModel

    @State private var selection: String?
    @State private var draft = Provider(id: "", name: "", baseURL: "", model: "", apiKey: "", requiresKey: true)
    @State private var isNew = false
    @State private var testMessage: String?
    @State private var isTesting = false
    @State private var importMessage: String?
    @State private var pendingDeletion: Provider?
    @State private var pendingClear: Provider?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L.tr("translation.providers.title"))
                    .font(.headline)
                Spacer()
                Button(L.tr("translation.providers.import_aitrans")) { importFromAITrans() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let importMessage {
                Text(importMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            HSplitView {
                sidebar
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
                editor
                    .frame(minWidth: 420)
            }
        }
        .onAppear(perform: syncSelection)
        .confirmationDialog(
            L.tr("translation.providers.delete_title"),
            isPresented: deleteConfirmation,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { provider in
            Button(L.tr("translation.providers.delete_action", provider.name), role: .destructive) {
                performDelete(provider)
            }
            Button(L.tr("button.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L.tr("translation.providers.delete_message"))
        }
        .confirmationDialog(
            L.tr("translation.providers.clear_title"),
            isPresented: clearConfirmation,
            titleVisibility: .visible,
            presenting: pendingClear
        ) { provider in
            Button(L.tr("translation.providers.clear_action"), role: .destructive) {
                performClearKey(provider)
            }
            Button(L.tr("button.cancel"), role: .cancel) {}
        } message: { provider in
            Text(L.tr("translation.providers.clear_message", provider.name))
        }
    }

    private var deleteConfirmation: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var clearConfirmation: Binding<Bool> {
        Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            Text(provider.model)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if provider.id == model.activeProviderID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .tag(provider.id)
                }
            }
            .onChange(of: selection) { _, _ in loadDraft() }

            Divider()
            HStack {
                Button {
                    startNew()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                Spacer()
                Menu {
                    ForEach(Spec.presets) { preset in
                        Button(preset.name) { applyPreset(preset) }
                    }
                } label: {
                    Label(L.tr("translation.providers.new_from_preset"), systemImage: "square.grid.2x2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)
        }
    }

    private var editor: some View {
        Form {
            Section(L.tr("translation.providers.basic")) {
                TextField(L.tr("translation.providers.name"), text: $draft.name)
                TextField(
                    L.tr("translation.providers.base_url"),
                    text: $draft.baseURL,
                    prompt: Text("https://api.deepseek.com")
                )
                TextField(L.tr("translation.providers.model"), text: $draft.model, prompt: Text("deepseek-flash"))
                SecureField(L.tr("translation.providers.api_key"), text: $draft.apiKey)
                Toggle(L.tr("translation.providers.requires_key"), isOn: $draft.requiresKey)
            }

            Section {
                HStack {
                    Button(L.tr("translation.providers.save")) { save() }
                        .keyboardShortcut("s", modifiers: .command)
                    Button(L.tr("translation.providers.save_activate")) { save(activate: true) }
                    Spacer()
                    Button(L.tr("translation.providers.clear_key")) { clearKey() }
                        .disabled(isNew || selection == nil)
                    Button(L.tr("translation.providers.test")) { test() }
                        .disabled(isTesting || draft.baseURL.isEmpty)
                }
                if let testMessage {
                    Text(testMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(selection == nil && !isNew)
        .overlay {
            if selection == nil && !isNew {
                ContentUnavailableView(
                    L.tr("translation.providers.empty_title"),
                    systemImage: "cpu",
                    description: Text(L.tr("translation.providers.empty_detail"))
                )
            }
        }
    }

    private func syncSelection() {
        if selection == nil {
            selection = model.activeProviderID ?? model.providers.first?.id
        }
        loadDraft()
    }

    private func loadDraft() {
        isNew = false
        testMessage = nil
        if let id = selection, let provider = model.providers.first(where: { $0.id == id }) {
            draft = model.providerForEditing(provider)
        }
    }

    private func startNew() {
        selection = nil
        isNew = true
        testMessage = nil
        draft = Provider(id: "", name: "", baseURL: "", model: "", apiKey: "", requiresKey: true)
    }

    private func applyPreset(_ preset: ProviderPreset) {
        isNew = true
        selection = nil
        testMessage = nil
        draft = Provider(
            id: preset.id,
            name: preset.name,
            baseURL: preset.baseURL,
            model: preset.model,
            apiKey: "",
            requiresKey: preset.requiresKey
        )
    }

    private func save(activate: Bool = false) {
        let candidate = Provider(
            id: isNew ? "" : draft.id,
            name: draft.name,
            baseURL: draft.baseURL,
            model: draft.model,
            apiKey: draft.apiKey,
            requiresKey: draft.requiresKey
        )
        guard let saved = model.saveProvider(candidate, activate: activate) else { return }
        selection = saved.id
        isNew = false
        loadDraft()
    }

    private func deleteSelected() {
        guard let id = selection,
              let provider = model.providers.first(where: { $0.id == id }) else { return }
        pendingDeletion = provider
    }

    private func performDelete(_ provider: Provider) {
        pendingDeletion = nil
        guard model.deleteProvider(id: provider.id) else { return }
        selection = model.activeProviderID ?? model.providers.first?.id
        if selection == nil { startNew() } else { loadDraft() }
    }

    private func test() {
        isTesting = true
        testMessage = L.tr("translation.providers.testing")
        Task {
            let message = await model.testProvider(draft)
            await MainActor.run {
                testMessage = message
                isTesting = false
            }
        }
    }

    private func clearKey() {
        guard let id = selection,
              let provider = model.providers.first(where: { $0.id == id }) else { return }
        pendingClear = provider
    }

    private func performClearKey(_ provider: Provider) {
        pendingClear = nil
        guard model.clearProviderKey(id: provider.id) else { return }
        draft.apiKey = ""
        testMessage = L.tr("translation.providers.key_cleared")
    }

    private func importFromAITrans() {
        let count = model.importProvidersFromAITrans(announce: false)
        if count > 0 {
            importMessage = L.tr("translation.providers.imported", count)
            syncSelection()
        } else {
            importMessage = L.tr("translation.providers.import_none")
        }
    }
}
