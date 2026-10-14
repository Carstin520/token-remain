import AppKit
import SwiftUI

/// Hosts the claude.ai Cookie guide in a floating panel. Opening claude.ai
/// brings the browser to the front, so a sheet on the Dashboard would sit
/// behind it exactly when the user needs it; the panel stays above the browser
/// while they follow the steps there.
@MainActor
final class ClaudeCookieGuideWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ClaudeCookieGuideWindowController()

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: ClaudeCookieGuideView.width, height: ClaudeCookieGuideView.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = L10n.text("claude.guide.title")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(
            srgbRed: 0x0D / 255, green: 0x0E / 255, blue: 0x10 / 255, alpha: 1
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Starts the guide from its first step and, when asked, opens claude.ai in
    /// the user's default browser. Reopening restarts the flow rather than
    /// resuming a half-finished paste.
    func show(store: UsageStore, openingSite: Bool) {
        guard let panel = window else { return }
        panel.contentViewController = NSHostingController(
            rootView: ClaudeCookieGuideView(
                store: store,
                browser: .systemDefault,
                onClose: { [weak self] in self?.close() }
            )
        )
        panel.setContentSize(NSSize(width: ClaudeCookieGuideView.width, height: ClaudeCookieGuideView.height))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 24,
                y: visible.maxY - panel.frame.height - 24
            ))
        }
        panel.orderFrontRegardless()
        if openingSite {
            ClaudeCookieGuideView.openClaudeSite()
        }
    }

    /// Dropping the hosted view releases its action, which cancels a validation
    /// still in flight instead of letting it save after the guide is gone.
    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }
}

/// Which browser's developer tools the steps describe. Only the labels and
/// panel names differ; the cookie is the same `sessionKey` in every browser.
enum ClaudeCookieGuideBrowser: String, CaseIterable, Identifiable {
    case chromium
    case safari
    case firefox

    var id: String { rawValue }

    /// The browser claude.ai will open in, so the first steps already match.
    static var systemDefault: Self {
        guard let url = URL(string: "https://claude.ai"),
              let application = NSWorkspace.shared.urlForApplication(toOpen: url),
              let identifier = Bundle(url: application)?.bundleIdentifier?.lowercased() else {
            return .chromium
        }
        if identifier.hasPrefix("com.apple.safari") { return .safari }
        if identifier.hasPrefix("org.mozilla") { return .firefox }
        return .chromium
    }

    var label: String { L10n.text("claude.guide.browser.\(rawValue)") }

    /// Developer-tools panel names as the browser shows them. They are the
    /// browser's own UI, so the illustration keeps them untranslated.
    var toolTabs: [String] {
        switch self {
        case .chromium: ["Elements", "Console", "Sources", "Network", "Application"]
        case .safari: ["Elements", "Console", "Sources", "Network", "Storage"]
        case .firefox: ["Inspector", "Console", "Debugger", "Network", "Storage"]
        }
    }

    var cookieHost: String { self == .safari ? "claude.ai" : "https://claude.ai" }
}

/// Four short steps from "claude.ai is open" to "Cookie saved". The guide only
/// shortens the way to the user's own copied `sessionKey`: it never reads
/// browser storage, and the clipboard is read once per click.
struct ClaudeCookieGuideView: View {
    static let width: CGFloat = 520
    static let height: CGFloat = 540
    private static let stepCount = 4

    @ObservedObject var store: UsageStore
    @State var browser: ClaudeCookieGuideBrowser
    let onClose: () -> Void

    @State private var step = 0
    @State private var pendingCredential: String?
    @State private var organizationID = ""
    @State private var clipboardUnrecognized = false
    @State private var submitError: String?
    @State private var connected = false
    @StateObject private var action = AsyncViewAction()

    static func openClaudeSite() {
        if let url = URL(string: "https://claude.ai") {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("claude.guide.title"))
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
                Text(L10n.text("claude.guide.step\(step + 1).title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Text(stepBody)
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step == 0 {
                Button(L10n.text("claude.guide.reopen")) { Self.openClaudeSite() }
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
        .onChange(of: store.claudeWebOrganizationChoices) { _, choices in
            if !choices.contains(where: { $0.id == organizationID }) {
                organizationID = ""
            }
        }
    }

    private var stepBody: String {
        switch step {
        case 0: L10n.text("claude.guide.step1.body")
        case 1: L10n.text("claude.guide.step2.body.\(browser.rawValue)")
        case 2: L10n.text("claude.guide.step3.body.\(browser.rawValue)")
        default: L10n.text("claude.guide.step4.body")
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch step {
        case 0: GuideBrowserIllustration()
        case 1: GuideShortcutIllustration(showsSafariSetting: browser == .safari)
        case 2: GuideDevToolsIllustration(browser: browser)
        default: GuideCookieTableIllustration()
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
                Label(L10n.text("claude.guide.connected"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardTheme.success)
            } else if clipboardUnrecognized {
                warning(L10n.text("claude.web.clipboard_unrecognized"))
            } else if !action.isRunning, let submitError {
                warning(submitError)
            }
            let choices = store.claudeWebOrganizationChoices
            if !connected, pendingCredential != nil, !choices.isEmpty {
                let labels = ClaudeWebUsageService.OrganizationChoice.labels(for: choices)
                Picker(
                    L10n.text("claude.web.organization"),
                    selection: Binding(
                        get: { organizationID },
                        set: { chosen in
                            organizationID = chosen
                            if !chosen.isEmpty { submit() }
                        }
                    )
                ) {
                    Text(L10n.text("claude.web.organization_prompt")).tag("")
                    ForEach(choices) { choice in
                        Text(labels[choice.id] ?? choice.id).tag(choice.id)
                    }
                }
                .disabled(action.isRunning)
            }
            Text(L10n.text("claude.web.setup"))
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

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let credential = ClaudeWebUsageService.Configuration.recognizedCredential(in: text) else {
            clipboardUnrecognized = true
            return
        }
        clipboardUnrecognized = false
        organizationID = ""
        pendingCredential = credential
        submit()
    }

    /// Same validation-before-save path as Data Sources. The error is captured
    /// at completion because a later background refresh may replace the
    /// Claude notice with an unrelated OAuth message.
    private func submit() {
        guard var credential = pendingCredential else { return }
        if !organizationID.isEmpty,
           var parsed = try? ClaudeWebUsageService.Configuration.decode(credential) {
            parsed.organizationID = organizationID
            if let encoded = try? parsed.encoded() { credential = encoded }
        }
        let submitted = credential
        submitError = nil
        action.start {
            let saved = await store.saveAPIKey(submitted, for: .claude)
            guard !Task.isCancelled else { return }
            if saved {
                connected = true
                pendingCredential = nil
            } else {
                submitError = store.providerNotices[.claude]
            }
        }
    }
}

// MARK: - Illustrations
//
// Drawn schematics rather than screenshots: they follow the selected browser
// and theme, and a real capture of the Cookies panel would contain a live
// session value.

private let guideHighlight = DashboardTheme.violet

private struct GuideBrowserIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(DashboardTheme.mutedText.opacity(0.6)).frame(width: 8, height: 8)
                }
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text("claude.ai").font(.system(size: 11, weight: .medium))
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
                BrandIcon(provider: .claude)
                    .foregroundStyle(DashboardTheme.claudeBrand)
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

private struct GuideShortcutIllustration: View {
    let showsSafariSetting: Bool

    var body: some View {
        VStack(spacing: 14) {
            if showsSafariSetting {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.square.fill").foregroundStyle(guideHighlight)
                    Text("Show features for web developers")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.text)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DashboardTheme.surface3, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 10) {
                GuideKeycap(symbol: "⌥", caption: "option")
                Text("+").foregroundStyle(DashboardTheme.mutedText)
                GuideKeycap(symbol: "⌘", caption: "command")
                Text("+").foregroundStyle(DashboardTheme.mutedText)
                GuideKeycap(symbol: "I", caption: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GuideKeycap: View {
    let symbol: String
    let caption: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(symbol).font(.system(size: 22, weight: .medium))
            if let caption {
                Text(caption).font(.system(size: 9)).foregroundStyle(DashboardTheme.mutedText)
            }
        }
        .foregroundStyle(DashboardTheme.text)
        .frame(width: 64, height: 56)
        .background(DashboardTheme.surface3, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DashboardTheme.border))
        .shadow(color: .black.opacity(0.35), radius: 0, y: 2)
    }
}

private struct GuideDevToolsIllustration: View {
    let browser: ClaudeCookieGuideBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ForEach(Array(browser.toolTabs.enumerated()), id: \.offset) { index, tab in
                    let isTarget = index == browser.toolTabs.count - 1
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
                    treeRow("chevron.right", "Local storage", dimmed: true)
                    treeRow("chevron.down", "Cookies", dimmed: false)
                    HStack(spacing: 5) {
                        Image(systemName: "globe").font(.system(size: 9))
                        Text(browser.cookieHost).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(DashboardTheme.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(guideHighlight.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(guideHighlight, lineWidth: 1.5))
                    .padding(.leading, 14)
                    treeRow("chevron.right", "Session storage", dimmed: true)
                }
                .padding(10)
                .frame(width: 190, alignment: .leading)
                Divider().overlay(DashboardTheme.border)
                VStack(alignment: .leading, spacing: 8) {
                    placeholderBar(width: 180)
                    placeholderBar(width: 140)
                    placeholderBar(width: 160)
                }
                .padding(12)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .padding(14)
    }

    private func treeRow(_ chevron: String, _ title: String, dimmed: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: chevron).font(.system(size: 8, weight: .bold))
            Text(title).font(.system(size: 10.5))
        }
        .foregroundStyle(dimmed ? DashboardTheme.mutedText : DashboardTheme.text)
    }
}

private struct GuideCookieTableIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            row(name: "Name", value: "Value", isHeader: true)
            Divider().overlay(DashboardTheme.border)
            placeholderRow
            row(name: "sessionKey", value: "sk-ant-sid01-••••••••••", isHeader: false)
                .background(guideHighlight.opacity(0.25))
                .overlay(Rectangle().stroke(guideHighlight, lineWidth: 1.5))
            placeholderRow
            HStack {
                Spacer()
                GuideKeycapBadge(text: "⌘C")
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .background(DashboardTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .padding(14)
    }

    private func row(name: String, value: String, isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            Text(name)
                .frame(width: 150, alignment: .leading)
            Text(value)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: isHeader ? .semibold : .medium, design: isHeader ? .default : .monospaced))
        .foregroundStyle(isHeader ? DashboardTheme.mutedText : DashboardTheme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var placeholderRow: some View {
        HStack(spacing: 0) {
            placeholderBar(width: 90).frame(width: 150, alignment: .leading)
            placeholderBar(width: 170)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct GuideKeycapBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DashboardTheme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DashboardTheme.surface3, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(guideHighlight, lineWidth: 1.5))
    }
}

private func placeholderBar(width: CGFloat) -> some View {
    Capsule()
        .fill(DashboardTheme.track)
        .frame(width: width, height: 7)
}
