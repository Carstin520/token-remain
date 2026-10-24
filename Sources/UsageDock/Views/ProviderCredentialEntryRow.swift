import AppKit
import SwiftUI

/// Shared metadata for providers whose first connection requires a pasted
/// secret. Keeping this in one place lets Data Sources and the quota card offer
/// the same secure setup flow without duplicating provider-specific rules.
struct ProviderCredentialConfiguration: Equatable {
    let placeholder: String
    let isCookie: Bool

    static func resolve(for provider: ProviderQuota.Provider) -> Self? {
        switch provider {
        case .zai:
            return Self(
                placeholder: L10n.text("datasource.zai_key_placeholder"),
                isCookie: false
            )
        case .openrouter:
            return Self(
                placeholder: L10n.text("datasource.openrouter_key_placeholder"),
                isCookie: false
            )
        default:
            guard let descriptor = ProviderSecretStore.descriptor(for: provider) else {
                return nil
            }
            return Self(placeholder: descriptor.placeholder, isCookie: descriptor.isCookie)
        }
    }

    static func storedCredentialStatus(
        for provider: ProviderQuota.Provider
    ) -> StoredCredentialStatus {
        switch provider {
        case .zai: ZAIKeyStore().credentialStatus()
        case .openrouter: OpenRouterKeyStore().credentialStatus()
        default: ProviderSecretStore(provider: provider).credentialStatus()
        }
    }

    static func hasStoredCredential(for provider: ProviderQuota.Provider) -> Bool {
        storedCredentialStatus(for: provider) == .available
    }
}

/// Secure pasted-secret editor. Secrets are never read back into the field;
/// save and clear continue to use the app-owned Keychain stores in UsageStore.
struct ProviderCredentialEntryRow: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderQuota.Provider
    let configuration: ProviderCredentialConfiguration
    @State private var credentialStatus: StoredCredentialStatus = .missing
    @State private var loadedStoredState = false
    @State private var draft = ""
    @State private var claudeOrganizationID = ""
    @State private var clipboardUnrecognized = false
    @StateObject private var action = AsyncViewAction()
    private var isSaving: Bool { action.isRunning }
    @State private var zaiRegion: ZAIAPIRegion
    @State private var zaiQueryMode: ZAIQueryMode
    @State private var alibabaRegion: AlibabaTokenPlanConfiguration.Region
    @State private var alibabaEdition: AlibabaTokenPlanConfiguration.Edition
    @State private var museCodeTeams: [MuseCodeTeam] = []
    @State private var museCodeTeamID = ""

    init(
        store: UsageStore,
        provider: ProviderQuota.Provider,
        configuration: ProviderCredentialConfiguration
    ) {
        self.store = store
        self.provider = provider
        self.configuration = configuration
        _zaiRegion = State(initialValue: ZAIRegionStore().load())
        _zaiQueryMode = State(initialValue: ZAIQueryModeStore().load())
        _alibabaRegion = State(initialValue: .china)
        _alibabaEdition = State(initialValue: .team)
    }

    /// `init` runs on every parent re-render, but `@State` keeps only its
    /// first value; reading the Keychain there repeated a discarded read for
    /// each row on every store update. Load once per row identity instead.
    private func loadStoredStateIfNeeded() {
        guard !loadedStoredState else { return }
        loadedStoredState = true
        reloadCredentialStatus()
        if provider == .alibabaTokenPlan,
           let stored = ProviderSecretStore(provider: provider).load()
            .flatMap({ try? AlibabaTokenPlanConfiguration.decode($0) }) {
            alibabaRegion = stored.region
            alibabaEdition = stored.edition
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if provider == .claude {
                claudeWebSetup
            } else if let guideSpec {
                webCookieSetup(guideSpec)
            }
            if provider == .museCode, museCodeTeams.count > 1 {
                museCodeTeamPicker
            }
            if provider == .amp {
                Text(L10n.text("amp.cli_hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider == .alibabaTokenPlan {
                Picker(L10n.text("alibaba.region"), selection: $alibabaRegion) {
                    ForEach(AlibabaTokenPlanConfiguration.Region.allCases, id: \.self) { region in
                        Text(region.displayName).tag(region)
                    }
                }
                .disabled(isSaving)
                Picker(L10n.text("alibaba.edition"), selection: $alibabaEdition) {
                    ForEach(AlibabaTokenPlanConfiguration.Edition.allCases, id: \.self) { edition in
                        Text(edition.displayName).tag(edition)
                    }
                }
                .disabled(isSaving)
                Text(L10n.text("alibaba.setup_hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider == .zai {
                HStack(spacing: 8) {
                    Text(L10n.text("datasource.zai_region"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.secondaryText)
                    Picker(
                        L10n.text("datasource.zai_region"),
                        selection: Binding(
                            get: { zaiRegion },
                            set: { newRegion in
                                zaiRegion = newRegion
                                action.start { await store.setZAIRegion(newRegion) }
                            }
                        )
                    ) {
                        ForEach(ZAIAPIRegion.allCases, id: \.self) { region in
                            Text(region.displayName).tag(region)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 230)
                    .disabled(isSaving)
                }
                if zaiRegion == .china {
                    Picker(
                        L10n.text("datasource.zai_query_mode"),
                        selection: Binding(
                            get: { zaiQueryMode },
                            set: { newMode in
                                zaiQueryMode = newMode
                                action.start { await store.setZAIQueryMode(newMode) }
                            }
                        )
                    ) {
                        ForEach(ZAIQueryMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .disabled(isSaving)
                }
            }

            HStack(spacing: 8) {
                SecureField(
                    credentialPlaceholder,
                    text: $draft
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .disabled(isSaving)

                Button(
                    canReplaceCredential
                        ? L10n.text("action.replace")
                        : L10n.text("action.save")
                ) {
                    saveDraft()
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

                if canReplaceCredential {
                    Button(L10n.text("action.clear")) {
                        action.start {
                            _ = await store.clearAPIKey(for: provider)
                            reloadCredentialStatus()
                            reloadMuseCodeTeams()
                        }
                    }
                    .disabled(isSaving)
                }
            }

            if isSaving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Button(L10n.text("action.cancel")) { action.cancel() }
                }
            }

            if credentialStatus == .authorizationRequired {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text("datasource.credential_authorization_required"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.warning)
                    Spacer(minLength: 4)
                    Button(L10n.text("action.authorize")) {
                        action.start {
                            _ = await store.authorizeProviderCredentials(provider)
                            guard !Task.isCancelled else { return }
                            reloadCredentialStatus()
                        }
                    }
                    .disabled(isSaving)
                }
            } else if credentialStatus == .failed {
                Text(L10n.text("datasource.credential_read_failed"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardTheme.warning)
            }
        }
        .onAppear {
            loadStoredStateIfNeeded()
            reloadMuseCodeTeams()
        }
        .onDisappear { action.cancel() }
        .onChange(of: store.claudeWebOrganizationChoices) { _, choices in
            // A new session brings its own list; a choice from the previous one
            // must not be submitted with it.
            if !choices.contains(where: { $0.id == claudeOrganizationID }) {
                claudeOrganizationID = ""
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("datasource.api_key_settings", provider.displayName))
    }

    /// claude.ai session setup. The step-by-step instructions live in the
    /// guide panel that "Open claude.ai" brings up beside the browser; the row
    /// keeps only the entry points. No browser storage is read, and the
    /// clipboard is read once per click, never watched.
    @ViewBuilder
    private var claudeWebSetup: some View {
        Text(L10n.text("claude.web.summary"))
            .font(.system(size: 11))
            .foregroundStyle(DashboardTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            Button(L10n.text("claude.web.open_site")) {
                ClaudeCookieGuideWindowController.shared.show(store: store, openingSite: true)
            }
            Button(L10n.text("claude.web.paste_clipboard")) {
                pasteClaudeCredentialFromClipboard()
            }
            .disabled(isSaving)
        }
        if clipboardUnrecognized {
            Text(L10n.text("claude.web.clipboard_unrecognized"))
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Choosing needs a session to apply it to: the draft still in the
        // field, or one already saved. A list raised by the guide's own paste
        // has neither here, and the guide offers it itself.
        let choices = store.claudeWebOrganizationChoices
        if !choices.isEmpty,
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || credentialStatus == .available {
            let labels = ClaudeWebUsageService.OrganizationChoice.labels(for: choices)
            Picker(
                L10n.text("claude.web.organization"),
                selection: Binding(
                    get: { claudeOrganizationID },
                    set: { chosen in
                        claudeOrganizationID = chosen
                        guard !chosen.isEmpty else { return }
                        chooseClaudeOrganization(chosen)
                    }
                )
            ) {
                Text(L10n.text("claude.web.organization_prompt")).tag("")
                ForEach(choices) { choice in
                    Text(labels[choice.id] ?? choice.id).tag(choice.id)
                }
            }
            .disabled(isSaving)
        }
    }

    /// Cookie-only providers other than Claude: the steps live in the guide
    /// panel; the row keeps the entry points. Alibaba's spec follows the
    /// region and edition currently chosen above.
    private var guideSpec: WebCookieGuideSpec? {
        if provider == .alibabaTokenPlan {
            return .alibaba(region: alibabaRegion, edition: alibabaEdition)
        }
        return WebCookieGuideSpec.spec(for: provider)
    }

    @ViewBuilder
    private func webCookieSetup(_ spec: WebCookieGuideSpec) -> some View {
        Text(L10n.format("cookieguide.summary", spec.host))
            .font(.system(size: 11))
            .foregroundStyle(DashboardTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            Button(L10n.text("cookieguide.open")) {
                WebCookieGuideWindowController.shared.show(store: store, spec: spec, openingSite: true)
            }
            Button(L10n.text("claude.web.paste_clipboard")) {
                pasteCookieFromClipboard()
            }
            .disabled(isSaving)
        }
        if clipboardUnrecognized {
            Text(L10n.text("cookieguide.clipboard_unrecognized"))
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Quota is per team. Shown once the account is known to have several;
    /// "Automatic" keeps the first team that has a subscription.
    private var museCodeTeamPicker: some View {
        HStack(spacing: 8) {
            Text(L10n.text("muse_code.team"))
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardTheme.secondaryText)
            Picker(
                L10n.text("muse_code.team"),
                selection: Binding(
                    get: { museCodeTeamID },
                    set: { chosen in
                        museCodeTeamID = chosen
                        action.start {
                            await store.setMuseCodeTeam(chosen.isEmpty ? nil : chosen)
                            reloadMuseCodeTeams()
                        }
                    }
                )
            ) {
                Text(L10n.text("muse_code.team_automatic")).tag("")
                ForEach(museCodeTeams) { team in
                    Text(team.name).tag(team.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .disabled(isSaving)
        }
    }

    private func reloadMuseCodeTeams() {
        guard provider == .museCode else { return }
        let teamStore = MuseCodeTeamStore()
        museCodeTeams = teamStore.knownTeams()
        museCodeTeamID = teamStore.selectedTeamID() ?? ""
    }

    /// The field holds the bare header; `saveDraft` wraps it where needed.
    private func pasteCookieFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let header = WebCookieHeader.extract(fromClipboard: text) else {
            clipboardUnrecognized = true
            return
        }
        clipboardUnrecognized = false
        draft = header
        saveDraft()
    }

    private func pasteClaudeCredentialFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let credential = ClaudeWebUsageService.Configuration.recognizedCredential(in: text) else {
            clipboardUnrecognized = true
            return
        }
        clipboardUnrecognized = false
        claudeOrganizationID = ""
        draft = credential
        saveDraft()
    }

    /// A pasted draft is still in the field after an ambiguous validation, so
    /// it is re-submitted with the organization. Without a draft the choice
    /// applies to the session already saved in the Keychain.
    private func chooseClaudeOrganization(_ organizationID: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            action.start {
                _ = await store.chooseStoredClaudeWebOrganization(organizationID)
                guard !Task.isCancelled else { return }
                claudeOrganizationID = ""
                reloadCredentialStatus()
            }
        } else {
            saveDraft()
        }
    }

    private func saveDraft() {
        var credential = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { return }
        if provider == .alibabaTokenPlan {
            let config = AlibabaTokenPlanConfiguration(
                region: alibabaRegion, edition: alibabaEdition, cookie: credential
            )
            guard let encoded = try? config.encoded() else { return }
            credential = encoded
        }
        if provider == .claude {
            clipboardUnrecognized = false
            if !claudeOrganizationID.isEmpty {
                guard var parsed = try? ClaudeWebUsageService.Configuration.decode(credential) else { return }
                parsed.organizationID = claudeOrganizationID
                guard let encoded = try? parsed.encoded() else { return }
                credential = encoded
            }
        }
        let submittedCredential = credential
        action.start {
            let saved = await store.saveAPIKey(submittedCredential, for: provider)
            guard !Task.isCancelled else { return }
            if saved {
                draft = ""
                claudeOrganizationID = ""
            }
            reloadCredentialStatus()
            reloadMuseCodeTeams()
        }
    }

    private var canReplaceCredential: Bool {
        credentialStatus == .available || credentialStatus == .authorizationRequired
    }

    private var credentialPlaceholder: String {
        switch credentialStatus {
        case .available:
            return L10n.text("datasource.key_saved_placeholder")
        case .authorizationRequired:
            return L10n.text("datasource.credential_authorization_placeholder")
        case .missing, .failed:
            return configuration.placeholder
        }
    }

    private func reloadCredentialStatus() {
        credentialStatus = ProviderCredentialConfiguration.storedCredentialStatus(for: provider)
    }
}
