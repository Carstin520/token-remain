import AppKit
import SwiftUI

/// Where a Cookie-only provider's web session lives and how its pasted header
/// becomes the stored credential. Claude keeps its own guide (it needs only
/// `sessionKey` and an organization choice); every other Cookie provider uses
/// this one: copy the page request's whole `Cookie` header from the Network
/// panel, which also carries HttpOnly cookies the Storage panel hides.
struct WebCookieGuideSpec {
    let provider: ProviderQuota.Provider
    let siteURL: URL
    /// The host shown in the steps and illustrations, e.g. `muse.ai`.
    let host: String
    /// Turns the pasted header into what `UsageStore.saveAPIKey` stores.
    var encode: (String) -> String? = { $0 }

    static func spec(for provider: ProviderQuota.Provider) -> Self? {
        func site(_ url: String, _ host: String) -> Self {
            Self(provider: provider, siteURL: URL(string: url)!, host: host)
        }
        switch provider {
        case .muse: return site("https://muse.ai/?settings_tab=general", "muse.ai")
        case .museCode: return site("https://dev.meta.ai", "dev.meta.ai")
        case .amp: return site("https://ampcode.com/settings", "ampcode.com")
        case .factory: return site("https://app.factory.ai", "app.factory.ai")
        case .augment: return site("https://app.augmentcode.com", "app.augmentcode.com")
        case .mimo: return site("https://platform.xiaomimimo.com", "platform.xiaomimimo.com")
        case .qoder: return site("https://qoder.com", "qoder.com")
        case .ollama: return site("https://ollama.com/settings", "ollama.com")
        default: return nil
        }
    }

    /// Alibaba's console depends on the region and edition chosen in its row,
    /// and the stored credential is a configuration wrapping the Cookie.
    static func alibaba(
        region: AlibabaTokenPlanConfiguration.Region,
        edition: AlibabaTokenPlanConfiguration.Edition
    ) -> Self {
        let sample = AlibabaTokenPlanConfiguration(region: region, edition: edition, cookie: "")
        return Self(
            provider: .alibabaTokenPlan,
            siteURL: sample.dashboardURL,
            host: sample.dashboardURL.host ?? "aliyun.com",
            encode: { cookie in
                try? AlibabaTokenPlanConfiguration(region: region, edition: edition, cookie: cookie).encoded()
            }
        )
    }

    func openSite() {
        NSWorkspace.shared.open(siteURL)
    }
}

/// Four short steps from "the site is open" to "Cookie saved". The guide only
/// shortens the way to a header the user copied themselves: it never reads
/// browser storage, and the clipboard is read once per click.
struct WebCookieGuideView: View {
    static let width: CGFloat = 520
    static let height: CGFloat = 560
    private static let stepCount = 4

    @ObservedObject var store: UsageStore
    let spec: WebCookieGuideSpec
    @State var browser: ClaudeCookieGuideBrowser
    @ObservedObject var action: AsyncViewAction
    let onClose: () -> Void

    @State private var step = 0
    @State private var clipboardUnrecognized = false
    @State private var submitError: String?
    @State private var connected = false

    private var name: String { spec.provider.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.format("cookieguide.title", name))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Spacer(minLength: 8)
                Text(L10n.format("claude.guide.step_counter", step + 1, Self.stepCount))
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.mutedText)
            }
            Picker(L10n.text("claude.guide.browser"), selection: $browser) {
                ForEach(ClaudeCookieGuideBrowser.allCases) { browser in
                    Text(browser.label).tag(browser)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            illustration
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                .background(DashboardTheme.surface2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DashboardTheme.border))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(stepTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Text(stepBody)
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step == 0 {
                Button(L10n.format("cookieguide.reopen", spec.host)) { spec.openSite() }
            }
            if step == Self.stepCount - 1 {
                pasteSection
            }

            Spacer(minLength: 0)

            HStack {
                if step > 0 {
                    Button(L10n.text("claude.guide.back")) { step -= 1 }
                        .disabled(action.isRunning)
                }
                Spacer()
                if step < Self.stepCount - 1 {
                    Button(L10n.text("claude.guide.next")) { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.text(connected ? "claude.guide.done" : "action.close")) { onClose() }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(DashboardTheme.canvas)
        .controlSize(.regular)
        .onDisappear { action.cancel() }
    }

    private var stepTitle: String {
        switch step {
        case 0: L10n.format("cookieguide.step1.title", spec.host)
        case 1: L10n.text("claude.guide.step2.title")
        case 2: L10n.text("cookieguide.step3.title")
        default: L10n.text("cookieguide.step4.title")
        }
    }

    private var stepBody: String {
        switch step {
        case 0: L10n.format("cookieguide.step1.body", spec.host)
        case 1: L10n.format("cookieguide.step2.body.\(browser.rawValue)", spec.host)
        case 2: L10n.format("cookieguide.step3.body.\(browser.rawValue)", spec.host)
        default: L10n.format("cookieguide.step4.body", spec.host)
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch step {
        case 0: WebGuideBrowserIllustration(provider: spec.provider, host: spec.host)
        case 1: GuideShortcutIllustration(showsSafariSetting: browser == .safari)
        default: WebGuideNetworkIllustration(browser: browser, host: spec.host, showsCopy: step == 3)
        }
    }

    @ViewBuilder
    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(L10n.text("claude.web.paste_clipboard")) { paste() }
                    .buttonStyle(.borderedProminent)
                    .disabled(action.isRunning || connected)
                if action.isRunning {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("action.cancel")) { action.cancel() }
                }
            }
            if connected {
                Label(L10n.format("cookieguide.connected", name), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.success)
            } else if clipboardUnrecognized {
                warning(L10n.text("cookieguide.clipboard_unrecognized"))
            } else if !action.isRunning, let submitError {
                warning(submitError)
            }
            Text(L10n.text("cookieguide.privacy"))
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DashboardTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Same validation-before-save path as Data Sources; nothing is stored
    /// unless the provider accepts the session.
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let header = WebCookieHeader.extract(fromClipboard: text),
              let credential = spec.encode(header) else {
            clipboardUnrecognized = true
            return
        }
        clipboardUnrecognized = false
        submitError = nil
        let provider = spec.provider
        action.start {
            let saved = await store.saveAPIKey(credential, for: provider)
            guard !Task.isCancelled else { return }
            if saved {
                connected = true
            } else {
                submitError = store.providerNotices[provider]
            }
        }
    }
}

// MARK: - Illustrations
//
// Drawn schematics, never screenshots: a real capture of request headers
// would contain a live session.

private struct WebGuideBrowserIllustration: View {
    let provider: ProviderQuota.Provider
    let host: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(DashboardTheme.mutedText.opacity(0.6)).frame(width: 8, height: 8)
                }
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text(host).font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(DashboardTheme.text)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(DashboardTheme.surface3, in: Capsule())
                .overlay(Capsule().stroke(guideHighlight, lineWidth: 1.5))
                .padding(.leading, 8)
            }
            .padding(10)
            Divider().overlay(DashboardTheme.border)
            HStack(spacing: 10) {
                BrandIcon(provider: provider)
                    .foregroundStyle(DashboardTheme.accent(for: provider))
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 6) {
                    placeholderBar(width: 150)
                    placeholderBar(width: 110)
                }
                Spacer()
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 22))
                    .foregroundStyle(DashboardTheme.success)
            }
            .padding(14)
            Spacer(minLength: 0)
        }
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .padding(14)
    }
}

/// Network panel: the page's document request on the left, its request
/// headers on the right with the `cookie` row highlighted.
private struct WebGuideNetworkIllustration: View {
    let browser: ClaudeCookieGuideBrowser
    let host: String
    let showsCopy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ForEach(Array(browser.toolTabs.enumerated()), id: \.offset) { index, tab in
                    let isTarget = index == 3
                    Text(tab)
                        .font(.system(size: 10.5, weight: isTarget ? .semibold : .regular))
                        .foregroundStyle(isTarget ? DashboardTheme.text : DashboardTheme.mutedText)
                        .padding(.horizontal, isTarget ? 6 : 0)
                        .padding(.vertical, 3)
                        .background {
                            if isTarget {
                                RoundedRectangle(cornerRadius: 4).fill(guideHighlight.opacity(0.25))
                                RoundedRectangle(cornerRadius: 4).stroke(guideHighlight, lineWidth: 1.5)
                            }
                        }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider().overlay(DashboardTheme.border)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text").font(.system(size: 9))
                        Text(host).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(DashboardTheme.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(guideHighlight.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(guideHighlight, lineWidth: 1.5))
                    placeholderBar(width: 110)
                    placeholderBar(width: 90)
                    placeholderBar(width: 120)
                }
                .padding(10)
                .frame(width: 170, alignment: .leading)
                Divider().overlay(DashboardTheme.border)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Request Headers")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DashboardTheme.mutedText)
                    placeholderBar(width: 150)
                    HStack(spacing: 6) {
                        Text("cookie:").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        Text("a=••••; b=••••").font(.system(size: 10.5, design: .monospaced))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(DashboardTheme.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(guideHighlight.opacity(0.25))
                    .overlay(Rectangle().stroke(guideHighlight, lineWidth: 1.5))
                    placeholderBar(width: 130)
                    if showsCopy {
                        HStack {
                            Spacer()
                            GuideKeycapBadge(text: "Copy value")
                        }
                    }
                }
                .padding(10)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .padding(14)
    }
}
