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

    static func hasStoredCredential(for provider: ProviderQuota.Provider) -> Bool {
        switch provider {
        case .zai: ZAIKeyStore().hasStoredKey()
        case .openrouter: OpenRouterKeyStore().hasStoredKey()
        default: ProviderSecretStore(provider: provider).hasStoredSecret()
        }
    }
}

/// Secure pasted-secret editor. Secrets are never read back into the field;
/// save and clear continue to use the app-owned Keychain stores in UsageStore.
struct ProviderCredentialEntryRow: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderQuota.Provider
    let configuration: ProviderCredentialConfiguration
    @State private var hasStoredCredential: Bool
    @State private var draft = ""
    @State private var isSaving = false

    init(
        store: UsageStore,
        provider: ProviderQuota.Provider,
        configuration: ProviderCredentialConfiguration
    ) {
        self.store = store
        self.provider = provider
        self.configuration = configuration
        _hasStoredCredential = State(
            initialValue: ProviderCredentialConfiguration.hasStoredCredential(for: provider)
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            SecureField(
                hasStoredCredential
                    ? L10n.text("datasource.key_saved_placeholder")
                    : configuration.placeholder,
                text: $draft
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .disabled(isSaving)

            Button(
                hasStoredCredential ? L10n.text("action.replace") : L10n.text("action.save")
            ) {
                let credential = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !credential.isEmpty else { return }
                isSaving = true
                Task {
                    await store.saveAPIKey(credential, for: provider)
                    draft = ""
                    hasStoredCredential = ProviderCredentialConfiguration.hasStoredCredential(
                        for: provider
                    )
                    isSaving = false
                }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

            if hasStoredCredential {
                Button(L10n.text("action.clear")) {
                    isSaving = true
                    Task {
                        await store.clearAPIKey(for: provider)
                        hasStoredCredential = ProviderCredentialConfiguration.hasStoredCredential(
                            for: provider
                        )
                        isSaving = false
                    }
                }
                .disabled(isSaving)
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("datasource.api_key_settings", provider.displayName))
    }
}
