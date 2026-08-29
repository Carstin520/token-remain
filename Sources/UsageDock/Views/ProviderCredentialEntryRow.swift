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
    @State private var credentialStatus: StoredCredentialStatus
    @State private var draft = ""
    @State private var isSaving = false
    @State private var zaiRegion: ZAIAPIRegion

    init(
        store: UsageStore,
        provider: ProviderQuota.Provider,
        configuration: ProviderCredentialConfiguration
    ) {
        self.store = store
        self.provider = provider
        self.configuration = configuration
        _credentialStatus = State(
            initialValue: ProviderCredentialConfiguration.storedCredentialStatus(for: provider)
        )
        _zaiRegion = State(initialValue: ZAIRegionStore().load())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
                                Task { await store.setZAIRegion(newRegion) }
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
                    let credential = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !credential.isEmpty else { return }
                    isSaving = true
                    Task {
                        let saved = await store.saveAPIKey(credential, for: provider)
                        if saved { draft = "" }
                        reloadCredentialStatus()
                        isSaving = false
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

                if canReplaceCredential {
                    Button(L10n.text("action.clear")) {
                        isSaving = true
                        Task {
                            _ = await store.clearAPIKey(for: provider)
                            reloadCredentialStatus()
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                }
            }

            if credentialStatus == .authorizationRequired {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text("datasource.credential_authorization_required"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.warning)
                    Spacer(minLength: 4)
                    Button(L10n.text("action.authorize")) {
                        isSaving = true
                        Task {
                            _ = await store.authorizeProviderCredentials(provider)
                            reloadCredentialStatus()
                            isSaving = false
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
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("datasource.api_key_settings", provider.displayName))
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
