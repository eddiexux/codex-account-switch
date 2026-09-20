import AppKit
import SwiftUI
import Charts
import CodexAccountSwitchCore

/// 详情窗口由 AppKit 托管：SwiftUI 的 `Window` 场景会在启动时自动弹出，菜单栏工具不想要这个行为。
/// 窗口打开期间把应用切成 `.regular`（有 Dock 图标和主菜单，Cmd+W/Cmd+Q 可用），关闭后退回 `.accessory`。
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show(state: AppState, selecting accountId: String?) {
        if let accountId { state.selectedAccountId = accountId }
        if window == nil {
            let hosting = NSHostingController(rootView: MainWindowView(state: state))
            let created = NSWindow(contentViewController: hosting)
            created.title = "Codex 账号"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 900, height: 620))
            created.minSize = NSSize(width: 760, height: 480)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.setFrameAutosaveName("CodexAccountSwitch.MainWindow")
            created.center()
            window = created
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// 开发用：把菜单面板放进普通窗口里预览，方便截图核对布局。
    func showMenuPreview(state: AppState) {
        let hosting = NSHostingController(rootView: MenuView(state: state))
        let preview = NSWindow(contentViewController: hosting)
        preview.title = "菜单面板预览"
        preview.styleMask = [.titled, .closable]
        preview.isReleasedWhenClosed = false
        preview.center()
        NSApp.activate(ignoringOtherApps: true)
        preview.makeKeyAndOrderFront(nil)
    }
}

struct MainWindowView: View {
    @Bindable var state: AppState

    private var selection: Binding<String?> {
        Binding(
            get: { state.showsOverview ? AppState.overviewSelectionId : state.selectedEntry?.id },
            set: { state.selectedAccountId = $0 }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            if state.showsOverview {
                OverviewView(state: state)
            } else if let entry = state.selectedEntry {
                AccountDetailView(state: state, entry: entry)
                    .id(entry.id)
            } else {
                emptyDetail
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if let last = state.lastRefreshAt, Date().timeIntervalSince(last) < 60 { return }
            Task { await state.refreshUsage() }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                if state.entries.count >= 2 {
                    OverviewSidebarRow(pool: state.combinedPace).tag(AppState.overviewSelectionId)
                }
                ForEach(state.entries) { entry in
                    SidebarRow(entry: entry).tag(entry.id)
                }
            }
            .listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        Task { await state.refreshUsage() }
                    } label: {
                        if state.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(state.isRefreshing)
                    Spacer()
                    if let last = state.lastRefreshAt {
                        Text(last, style: .time).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Button {
                    Task { await state.loginViaCodex() }
                } label: {
                    Label("添加账号…", systemImage: "person.badge.plus")
                }
                .disabled(state.isBusy)
                Toggle("开机自启", isOn: $state.launchAtLogin).toggleStyle(.checkbox).font(.caption)
                if state.codexProcessCount > 0 {
                    Label("\(state.codexProcessCount) 个 Codex 进程运行中，切换只对新会话生效", systemImage: "info.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.largeTitle).foregroundStyle(.tertiary)
            Text("还没有账号").font(.title3)
            Text("点左下角「添加账号」运行 codex login，登录完成后账号自动入库。")
                .font(.caption).foregroundStyle(.secondary)
            if let prompt = state.loginPrompt {
                LoginPromptBox(prompt: prompt) { state.cancelLogin() }.frame(maxWidth: 420)
            }
            ActivityFooter(state: state)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 侧边栏顶部的"全部账号"行：合池已用与节奏差距一眼可见。
struct OverviewSidebarRow: View {
    let pool: CombinedPace?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                Text("全部账号").font(.callout.weight(.semibold))
            }
            HStack(spacing: 6) {
                // 选中时底色是强调色，这里不用红绿着色，否则看不清。
                if let pool {
                    Text("合计 \(Int(pool.usedPercent.rounded()))% · \(PaceFormat.gapText(pool.gapPercent, verdict: pool.verdict))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("额度加载中…").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct SidebarRow: View {
    let entry: AccountEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.needsLogin ? Color.orange : entry.isActive ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(entry.email).font(.callout.weight(entry.isActive ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if entry.availableResetCredits > 0 {
                    ResetCreditBadge(count: entry.availableResetCredits, applicable: entry.resetCreditApplicable)
                }
            }
            HStack(spacing: 6) {
                Text(entry.planLabel).font(.caption2).foregroundStyle(.secondary)
                if let window = entry.usage?.headlineWindow {
                    Text("\(window.label) \(Int(window.usedPercent.rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(UsageTint.color(window.usedPercent))
                    if let reset = window.resetAt {
                        Text("· \(ResetFormatter.relative(reset))").font(.caption2).foregroundStyle(.tertiary)
                    }
                } else if entry.needsLogin {
                    Text("需重新登录").font(.caption2).foregroundStyle(.orange)
                }
            }
            if let until = entry.subscriptionActiveUntil {
                Text(ResetFormatter.subscriptionExpiry(until))
                    .font(.caption2)
                    .foregroundStyle(entry.isSubscriptionExpiringSoon ? Color.orange : Color.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// 单个账号的完整详情：额度窗口、节奏、按模型额度、重置卡、用量历史。
struct AccountDetailView: View {
    @Bindable var state: AppState
    let entry: AccountEntry
    @State private var confirmRedeem = false
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let prompt = state.loginPrompt {
                    LoginPromptBox(prompt: prompt) { state.cancelLogin() }
                }
                if let usage = entry.usage {
                    section("额度窗口", systemImage: "chart.bar") {
                        if usage.windows.isEmpty {
                            Text("接口未返回额度窗口").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                                WindowRow(
                                    window: window,
                                    baselinePercent: window == usage.headlineWindow ? entry.pace?.plannedPercent : nil
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                        if usage.limitReached {
                            Label("已达上限，当前无法发起新请求", systemImage: "exclamationmark.octagon")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    if let pace = entry.pace {
                        section("每周节奏", systemImage: "speedometer") { PaceSection(pace: pace) }
                    }
                    if !usage.additionalLimits.isEmpty {
                        section("按模型单独计量", systemImage: "cpu") {
                            ForEach(usage.additionalLimits) { limit in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(limit.name).font(.caption.weight(.semibold))
                                    HStack(alignment: .top, spacing: 16) {
                                        ForEach(Array(limit.windows.enumerated()), id: \.offset) { _, window in
                                            WindowRow(window: window).frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                resetCreditSection
                historySection
                if let error = entry.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                ActivityFooter(state: state)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("使用重置卡？", isPresented: $confirmRedeem) {
            Button("使用", role: .destructive) {
                Task { await state.redeemResetCredit(accountId: entry.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(redeemConfirmMessage)
        }
        .alert("移除这个账号快照？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { state.removeAccount(accountId: entry.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除本工具保存的 \(entry.email) 登录态副本，不影响 ChatGPT 账号本身。之后要用它需重新登录。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.email).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(entry.planLabel).font(.caption).foregroundStyle(.secondary)
                    StatusBadge(entry: entry)
                    Text("ID \(entry.id.prefix(8))…").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                if let until = entry.subscriptionActiveUntil {
                    Label(ResetFormatter.subscriptionExpiry(until), systemImage: "calendar.badge.clock")
                        .font(.caption)
                        .foregroundStyle(entry.isSubscriptionExpiringSoon ? Color.orange : Color.secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if entry.needsLogin {
                    Button("重新登录…") { Task { await state.loginViaCodex() } }.disabled(state.isBusy)
                } else if !entry.isActive {
                    Button("切换到此账号") { state.switchTo(accountId: entry.id) }
                        .buttonStyle(.borderedProminent).disabled(state.isBusy)
                }
                if !entry.isActive {
                    Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                        .help("从工具里移除这个账号快照").disabled(state.isBusy)
                }
            }
        }
    }

    // MARK: 重置卡

    private var resetCreditSection: some View {
        section("重置卡", systemImage: "ticket") {
            let count = entry.availableResetCredits
            if count == 0 {
                Text("没有可用的重置卡。OpenAI 会不定期赠送，兑换后可把已达上限的额度窗口清零。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("可用 \(count) 张").font(.callout.weight(.semibold))
                        if entry.resetCreditApplicable {
                            Label("当前有已达上限的窗口，现在兑换会立即生效", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Label("当前没有达上限的窗口；现在兑换服务端会返回「无需重置」，不会消耗卡", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        confirmRedeem = true
                    } label: {
                        Label("使用一张重置卡", systemImage: "arrow.counterclockwise.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy || !entry.canRedeemResetCredit)
                }
                if let list = entry.resetCredits {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(list.available) { credit in
                            HStack(spacing: 8) {
                                Image(systemName: "ticket").foregroundStyle(.secondary)
                                Text(credit.title ?? credit.resetType ?? "重置卡").font(.caption)
                                if credit.id == list.soonestExpiring?.id {
                                    Text("下次使用").font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                        .foregroundStyle(Color.accentColor)
                                }
                                Spacer()
                                if let expires = credit.expiresAt {
                                    Text("\(ResetFormatter.expiry(expires)) · \(ResetFormatter.absolute(expires))")
                                        .font(.caption2).foregroundStyle(expiringSoon(expires) ? .red : .secondary)
                                }
                                if !credit.isSupportedByPlan {
                                    Text("当前套餐不支持").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                        if let first = list.available.first?.description {
                            Text(first).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("明细加载失败，刷新后重试；兑换时会重新向服务端核对。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var redeemConfirmMessage: String {
        var lines = ["将为 \(entry.email) 兑换一张重置卡，把已达上限的额度窗口清零。"]
        if let credit = entry.resetCredits?.soonestExpiring, let expires = credit.expiresAt {
            lines.append("优先使用最早过期的那张（\(ResetFormatter.absolute(expires)) 过期）。")
        }
        if !entry.resetCreditApplicable {
            lines.append("当前没有达上限的窗口，服务端很可能返回「无需重置」并保留这张卡。")
        }
        lines.append("兑换不可撤销。")
        return lines.joined(separator: "\n")
    }

    private func expiringSoon(_ date: Date) -> Bool { date.timeIntervalSinceNow < 3 * 86_400 }

    // MARK: 用量历史

    private var historySection: some View {
        section("用量历史（最近 7 天）", systemImage: "chart.xyaxis.line") {
            let samples = state.usageSamples(for: entry.id)
            if samples.count < 2 {
                Text("采样不足，每次刷新会记录一次周额度用量。").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(samples, id: \.at) { sample in
                    LineMark(
                        x: .value("时间", sample.at),
                        y: .value("已用", sample.usedPercent),
                        series: .value("窗口", sample.resetAt?.timeIntervalSince1970 ?? 0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    AreaMark(
                        x: .value("时间", sample.at),
                        y: .value("已用", sample.usedPercent),
                        series: .value("窗口", sample.resetAt?.timeIntervalSince1970 ?? 0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0.0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day().hour())
                } }
                .frame(height: 170)
                Text("百分比归零处是窗口重置；曲线按窗口分段。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func section<Content: View>(
        _ title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        DetailSection(title, systemImage: systemImage, content: content)
    }
}
