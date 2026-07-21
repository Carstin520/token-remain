import SwiftUI

/// 新用户首启引导:检测本机已安装的 AI 编码工具,预勾选检测到的项,
/// 用户确认(可去掉不需要的、也可勾上暂未检测到的)后开始追踪。
/// 零阻力原则:合理默认已选好,一个按钮即可完成;所有选择之后都能在
/// 「额度」页随时调整,这里不做任何不可逆决定。
struct OnboardingView: View {
    @ObservedObject var tracked: TrackedProvidersStore

    @State private var detections: [TrackedProvidersStore.Detection] = []
    @State private var selection: Set<ProviderQuota.Provider> = []
    /// 用户通过 "+" 手动加入列表的未检测到应用,保持行可见、可再取消。
    @State private var manuallyAdded: Set<ProviderQuota.Provider> = []

    /// 主列表只放检测到的应用 + 用户手动添加的;其余收进 "+" 菜单,
    /// 列表短而相关,又不会把"没列出来"误读成"不支持"。
    private var visibleDetections: [TrackedProvidersStore.Detection] {
        detections.filter { $0.installed || manuallyAdded.contains($0.provider) }
    }

    private var addableDetections: [TrackedProvidersStore.Detection] {
        detections.filter { !$0.installed && !manuallyAdded.contains($0.provider) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 10) {
                TokenRemainLogo(remainingPercent: nil)
                    .frame(width: 56, height: 56)
                Text("欢迎使用 Token Remain")
                    .wordmarkFont(26)
                    .foregroundStyle(DashboardTheme.text)
                Text("已扫描本机的 AI 编码工具。勾选要追踪额度的应用——之后随时可在「额度」页增删。")
                    .font(.system(size: 13))
                    .foregroundStyle(DashboardTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.bottom, 22)

            VStack(spacing: 8) {
                if visibleDetections.isEmpty {
                    Text("未检测到已安装的 AI 编码工具；点下方 + 手动添加,或先安装工具后再打开 Token Remain。")
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 12)
                }
                ForEach(visibleDetections) { detection in
                    providerRow(detection)
                }
                addRow
            }
            .frame(maxWidth: 460)

            Spacer(minLength: 20)

            VStack(spacing: 8) {
                Button {
                    tracked.completeOnboarding(enabled: selection)
                } label: {
                    Text(selection.isEmpty ? "暂不追踪，直接开始" : "开始追踪 \(selection.count) 个应用")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: 300)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(DashboardTheme.purple)

                Text("凭证只读、绝不上传；未检测到的应用登录后会自动接入。")
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardTheme.mutedText)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashboardTheme.canvas)
        .preferredColorScheme(.dark)
        .onAppear {
            guard detections.isEmpty else { return }
            detections = TrackedProvidersStore.detections()
            selection = Set(detections.filter(\.installed).map(\.provider))
        }
    }

    /// "+" 行:二级菜单列出未检测到的可支持应用(点选即加入上方列表并
    /// 勾选),底部如实展示路线图中的应用,避免"没列出=不支持"的误解。
    private var addRow: some View {
        Menu {
            if addableDetections.isEmpty {
                Button("可支持的应用都已在列表中") {}.disabled(true)
            } else {
                Section("未检测到,手动添加") {
                    ForEach(addableDetections) { detection in
                        Button {
                            manuallyAdded.insert(detection.provider)
                            selection.insert(detection.provider)
                        } label: {
                            Label(detection.provider.displayName, systemImage: "plus.circle")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.dashed")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DashboardTheme.secondaryText)
                Text("添加其他应用")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardTheme.text)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DashboardTheme.mutedText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        DashboardTheme.border,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("添加其他应用")
    }

    private func providerRow(_ detection: TrackedProvidersStore.Detection) -> some View {
        let isOn = selection.contains(detection.provider)
        return Button {
            if isOn {
                selection.remove(detection.provider)
            } else {
                selection.insert(detection.provider)
            }
        } label: {
            HStack(spacing: 12) {
                BrandIcon(provider: detection.provider)
                    .foregroundStyle(DashboardTheme.text)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(detection.provider.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DashboardTheme.text)
                        if detection.installed {
                            TagPill(text: "已检测到")
                        }
                    }
                    Text(detection.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardTheme.secondaryText)
                }

                Spacer(minLength: 12)

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? DashboardTheme.success : DashboardTheme.mutedText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? DashboardTheme.surface2 : DashboardTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isOn ? DashboardTheme.purple.opacity(0.5) : DashboardTheme.border, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detection.provider.displayName)
        .accessibilityValue(isOn ? "追踪中" : "未追踪")
        .accessibilityHint(detection.detail)
    }
}
