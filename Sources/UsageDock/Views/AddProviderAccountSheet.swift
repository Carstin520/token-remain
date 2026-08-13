import AppKit
import SwiftUI

struct ProviderAccountCLISetup: Equatable {
    let executableName: String
    let installCommand: String
    let officialGuideURL: URL
    let executable: URL?

    static func resolve(for provider: ProviderQuota.Provider) -> Self? {
        switch provider {
        case .codex:
            return Self(
                executableName: "Codex",
                installCommand: "npm install -g @openai/codex",
                officialGuideURL: URL(string: "https://help.openai.com/en/articles/11096431")!,
                executable: CodexAccountLoginService.executable()
            )
        case .claude:
            return Self(
                executableName: "Claude Code",
                installCommand: "npm install -g @anthropic-ai/claude-code",
                officialGuideURL: URL(string: "https://docs.anthropic.com/en/docs/claude-code/getting-started")!,
                executable: ClaudeAccountLoginService.claudeExecutable()
            )
        default:
            return nil
        }
    }
}

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
    var editingProfile: ProviderAccountProfile?
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

    private var isEditing: Bool { editingProfile != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                BrandIcon(provider: provider)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(DashboardTheme.text)
                Text(L10n.format(
                    isEditing ? "accounts.credential_update_title" : "accounts.credential_title",
                    provider.displayName
                ))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
            }

            if !isEditing {
                AccountSetupNotice(
                    icon: "person.crop.circle.badge.checkmark",
                    title: L10n.text("accounts.setup.current_title"),
                    message: L10n.format("accounts.setup.current_body", provider.displayName),
                    tint: DashboardTheme.success
                )

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
            }

            AccountSetupNotice(
                icon: "key.fill",
                title: L10n.format("accounts.setup.credential_method", provider.displayName),
                message: L10n.text(
                    isEditing
                        ? "accounts.setup.credential_update_body"
                        : "accounts.setup.credential_body"
                ),
                tint: DashboardTheme.accent(for: provider)
            )

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

            if provider == .antigravity {
                Label(L10n.text("accounts.setup.short_lived_warning"), systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                Button(
                    L10n.text(
                        isEditing
                            ? "accounts.credential_update_submit"
                            : "accounts.credential_submit"
                    ),
                    action: submit
                )
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedCredential.isEmpty || isSubmitting)
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 380)
        .onAppear {
            store.clearAccountManagementNotice(for: provider)
            isCredentialFocused = true
        }
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
            let added: Bool
            if let editingProfile {
                added = await store.updateProviderAccountCredential(
                    editingProfile.id,
                    credential: secret
                )
            } else {
                added = await store.addProviderAccount(
                    provider: provider,
                    displayName: trimmedName.isEmpty ? nil : trimmedName,
                    credential: secret
                )
            }
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

/// Guided setup for providers whose official CLI can own a separate OAuth
/// session. Nothing is launched until the user has seen the requirements and
/// explicitly continues.
struct AddCLIProviderAccountSheet: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderQuota.Provider
    @Binding var isPresented: Bool

    @State private var accountName = ""
    @State private var isSubmitting = false
    @State private var failure: String?
    @State private var availabilityRevision = UUID()
    @State private var copiedCommand = false

    private var setup: ProviderAccountCLISetup? {
        _ = availabilityRevision
        return ProviderAccountCLISetup.resolve(for: provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BrandIcon(provider: provider)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(DashboardTheme.text)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.format("accounts.setup.title", provider.displayName))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DashboardTheme.text)
                    Text(L10n.text("accounts.setup.subtitle"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.secondaryText)
                }
            }

            AccountSetupNotice(
                icon: "person.crop.circle.badge.checkmark",
                title: L10n.text("accounts.setup.current_title"),
                message: L10n.format("accounts.setup.current_body", provider.displayName),
                tint: DashboardTheme.success
            )

            if let setup {
                AccountSetupNotice(
                    icon: setup.executable == nil ? "terminal.fill" : "checkmark.circle.fill",
                    title: setup.executable == nil
                        ? L10n.format("accounts.setup.cli_missing", setup.executableName)
                        : L10n.format("accounts.setup.cli_ready", setup.executableName),
                    message: setup.executable == nil
                        ? L10n.text("accounts.setup.cli_missing_body")
                        : L10n.text("accounts.setup.cli_body"),
                    tint: setup.executable == nil ? DashboardTheme.warning : DashboardTheme.success
                )

                if setup.executable == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("accounts.setup.install_command"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DashboardTheme.secondaryText)
                        HStack(spacing: 6) {
                            Text(setup.installCommand)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(DashboardTheme.text)
                                .textSelection(.enabled)
                            Spacer(minLength: 6)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(setup.installCommand, forType: .string)
                                copiedCommand = true
                            } label: {
                                Label(
                                    L10n.text(
                                        copiedCommand
                                            ? "accounts.setup.copied"
                                            : "accounts.setup.copy_command"
                                    ),
                                    systemImage: copiedCommand ? "checkmark" : "doc.on.doc"
                                )
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(8)
                        .background(DashboardTheme.surface2, in: RoundedRectangle(cornerRadius: 8))

                        HStack {
                            Link(destination: setup.officialGuideURL) {
                                Label(
                                    L10n.text("accounts.setup.official_guide"),
                                    systemImage: "arrow.up.right.square"
                                )
                            }
                            .buttonStyle(.link)
                            Spacer()
                            Button(L10n.text("accounts.setup.check_again")) {
                                copiedCommand = false
                                availabilityRevision = UUID()
                            }
                        }
                    }
                }
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
                .disabled(isSubmitting)
            }

            VStack(alignment: .leading, spacing: 7) {
                SetupStepRow(number: 1, text: L10n.text("accounts.setup.step_browser"))
                SetupStepRow(number: 2, text: L10n.text("accounts.setup.step_other_account"))
                SetupStepRow(number: 3, text: L10n.text("accounts.setup.step_private"))
            }

            if let failure, !failure.isEmpty {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(L10n.format("accounts.management_notice", failure))
            }

            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView().controlSize(.mini)
                    Text(L10n.text("accounts.setup.signing_in"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Button(L10n.text("action.cancel")) { isPresented = false }
                    .disabled(isSubmitting)
                Button(L10n.text("accounts.setup.continue"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup?.executable == nil || isSubmitting)
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 400)
        .onAppear { store.clearAccountManagementNotice(for: provider) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("accounts.setup.title", provider.displayName))
    }

    private func submit() {
        guard setup?.executable != nil, !isSubmitting else { return }
        failure = nil
        isSubmitting = true
        Task {
            let trimmedName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            let added = await store.addProviderAccount(
                provider: provider,
                displayName: trimmedName.isEmpty ? nil : trimmedName,
                credential: nil
            )
            isSubmitting = false
            if added {
                isPresented = false
            } else {
                failure = store.accountManagementNotice(for: provider)
                    ?? L10n.text("accounts.setup.failed")
                availabilityRevision = UUID()
            }
        }
    }
}

private struct AccountSetupNotice: View {
    let icon: String
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardTheme.surface2, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(DashboardTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SetupStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .numericFont(9, .bold)
                .foregroundStyle(DashboardTheme.text)
                .frame(width: 18, height: 18)
                .background(DashboardTheme.surface2, in: Circle())
                .overlay { Circle().stroke(DashboardTheme.border, lineWidth: 1) }
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number). \(text)")
    }
}
