import SwiftUI

/// Provider-specific guidance for the keychain-secret add-account flow. These
/// are hints only: the credential itself goes straight to the device Keychain
/// through `UsageStore.addProviderAccount` and is never read back into the UI.
struct ProviderAccountCredentialHint: Equatable {
    let placeholderKey: String
    let hintKey: String
    /// Documented optional JSON form. Kept literal on purpose — the field names
    /// are part of the provider contract and must not be translated.
    let jsonExample: String?

    static func resolve(for provider: ProviderQuota.Provider) -> Self? {
        guard provider.multiAccountCapability?.credentialKind == .keychainSecret else {
            return nil
        }
        switch provider {
        case .antigravity:
            return Self(
                placeholderKey: "accounts.credential.placeholder.token",
                hintKey: "accounts.credential.hint.antigravity",
                jsonExample: nil
            )
        case .cursor:
            return Self(
                placeholderKey: "accounts.credential.placeholder.token",
                hintKey: "accounts.credential.hint.cursor",
                jsonExample: nil
            )
        case .grok:
            return Self(
                placeholderKey: "accounts.credential.placeholder.token",
                hintKey: "accounts.credential.hint.grok",
                jsonExample: nil
            )
        case .zai:
            return Self(
                placeholderKey: "accounts.credential.placeholder.api_key",
                hintKey: "accounts.credential.hint.zai",
                jsonExample: #"{"apiKey": "…", "region": "global"}"#
            )
        case .zaiTeam:
            return Self(
                placeholderKey: "accounts.credential.placeholder.json",
                hintKey: "accounts.credential.hint.zai_team",
                jsonExample: #"{"apiKey": "…", "organization": "…", "project": "…"}"#
            )
        case .copilot:
            return Self(
                placeholderKey: "accounts.credential.placeholder.token",
                hintKey: "accounts.credential.hint.copilot",
                jsonExample: nil
            )
        case .devin:
            return Self(
                placeholderKey: "accounts.credential.placeholder.api_key",
                hintKey: "accounts.credential.hint.devin",
                jsonExample: #"{"apiKey": "…", "apiServerURL": "https://…"}"#
            )
        case .windsurf:
            return Self(
                placeholderKey: "accounts.credential.placeholder.api_key",
                hintKey: "accounts.credential.hint.windsurf",
                jsonExample: #"{"apiKey": "…", "apiServerURL": "https://…"}"#
            )
        case .openrouter:
            return Self(
                placeholderKey: "accounts.credential.placeholder.api_key",
                hintKey: "accounts.credential.hint.openrouter",
                jsonExample: nil
            )
        case .deepseek:
            return Self(
                placeholderKey: "accounts.credential.placeholder.api_key",
                hintKey: "accounts.credential.hint.deepseek",
                jsonExample: nil
            )
        case .minimax:
            return Self(
                placeholderKey: "accounts.credential.placeholder.api_key",
                hintKey: "accounts.credential.hint.minimax",
                jsonExample: nil
            )
        case .kimi:
            return Self(
                placeholderKey: "accounts.credential.placeholder.api_key",
                hintKey: "accounts.credential.hint.kimi",
                jsonExample: nil
            )
        case .mimo:
            return Self(
                placeholderKey: "accounts.credential.placeholder.cookie",
                hintKey: "accounts.credential.hint.mimo",
                jsonExample: nil
            )
        case .qoder:
            return Self(
                placeholderKey: "accounts.credential.placeholder.cookie",
                hintKey: "accounts.credential.hint.qoder",
                jsonExample: nil
            )
        case .ollama:
            return Self(
                placeholderKey: "accounts.credential.placeholder.cookie",
                hintKey: "accounts.credential.hint.ollama",
                jsonExample: nil
            )
        case .volcengine:
            return Self(
                placeholderKey: "accounts.credential.placeholder.aksk",
                hintKey: "accounts.credential.hint.volcengine",
                jsonExample: nil
            )
        case .thirdParty:
            return Self(
                placeholderKey: "accounts.credential.placeholder.json",
                hintKey: "accounts.credential.hint.third_party",
                jsonExample: #"{"adapter": "newapi-token", "baseUrl": "https://…", "apiKey": "…"}"#
            )
        default:
            // A provider that becomes keychain-backed later still gets a usable
            // entry form instead of an Add button that opens nothing.
            return Self(
                placeholderKey: "accounts.credential.placeholder.api_key",
                hintKey: "accounts.credential.hint.generic",
                jsonExample: nil
            )
        }
    }
}

/// Native add-account form for providers whose second account is one opaque
/// credential. It only ever writes: the field starts empty for every
/// presentation and no saved secret is read back into it.
struct AddProviderAccountSheet: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderQuota.Provider
    let hint: ProviderAccountCredentialHint
    @Binding var isPresented: Bool

    @State private var accountName = ""
    @State private var credential = ""
    @State private var isSubmitting = false
    @State private var failure: String?
    @FocusState private var isCredentialFocused: Bool

    private var trimmedCredential: String {
        credential.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedName: String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                BrandIcon(provider: provider)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(DashboardTheme.text)
                Text(L10n.format("accounts.credential_title", provider.displayName))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("accounts.credential_name_label"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardTheme.secondaryText)
                TextField(
                    L10n.text("accounts.credential_name_placeholder"),
                    text: $accountName
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .disabled(isSubmitting)
                .accessibilityLabel(L10n.text("accounts.credential_name_label"))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("accounts.credential_label"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardTheme.secondaryText)
                SecureField(L10n.text(hint.placeholderKey), text: $credential)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($isCredentialFocused)
                    .disabled(isSubmitting)
                    .onSubmit(submit)
                    .accessibilityLabel(
                        L10n.format("accounts.credential_accessibility", provider.displayName)
                    )
                    .accessibilityHint(L10n.text(hint.hintKey))
                Text(L10n.text(hint.hintKey))
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let jsonExample = hint.jsonExample {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("accounts.credential_json_label"))
                            .font(.system(size: 10))
                            .foregroundStyle(DashboardTheme.mutedText)
                        Text(jsonExample)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DashboardTheme.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 1)
                }
            }

            Label {
                Text(L10n.format("accounts.credential_privacy", provider.displayName))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
            }
            .font(.system(size: 10))
            .foregroundStyle(DashboardTheme.mutedText)

            if let failure, !failure.isEmpty {
                Text(failure)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardTheme.warning)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(failure)
                    .accessibilityLabel(L10n.format("accounts.management_notice", failure))
            }

            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView().controlSize(.mini)
                    Text(L10n.format("accounts.credential_verifying", provider.displayName))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(L10n.text("action.cancel")) {
                    credential = ""
                    isPresented = false
                }
                .disabled(isSubmitting)
                Button(L10n.text("accounts.credential_submit"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedCredential.isEmpty || isSubmitting)
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 336)
        .onAppear { isCredentialFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("accounts.credential_title", provider.displayName))
    }

    /// The store owns the real guard against a second concurrent add; failing
    /// here keeps the form open with the provider's own explanation.
    private func submit() {
        let secret = trimmedCredential
        guard !secret.isEmpty, !isSubmitting else { return }
        failure = nil
        isSubmitting = true
        Task {
            let added = await store.addProviderAccount(
                provider: provider,
                displayName: trimmedName.isEmpty ? nil : trimmedName,
                credential: secret
            )
            isSubmitting = false
            credential = ""
            if added {
                accountName = ""
                isPresented = false
            } else {
                failure = store.accountManagementNotice(for: provider)
                    ?? L10n.text("accounts.credential_failed")
                isCredentialFocused = true
            }
        }
    }
}
