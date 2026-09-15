import SwiftUI
import CodexAccountSwitchCore

struct MenuView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if state.entries.isEmpty {
                emptyHint
            } else {
                ForEach(state.entries) { entry in
                    AccountCard(entry: entry, isBusy: state.isBusy) {
                        state.switchTo(accountId: entry.id)
                    } onLogin: {
                        Task { await state.loginViaCodex() }
                    } onRemove: {
                        state.removeAccount(accountId: entry.id)
                    }
                }
            }
            if let prompt = state.loginPrompt {
                LoginPromptBox(prompt: prompt) { state.cancelLogin() }
            }
            if let busy = state.busyMessage {
                HStack {
                    Label(busy, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if state.loginSessionActive {
                        Button("取消") { state.cancelLogin() }.font(.caption)
                    }
                }
            }
            if let message = state.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            if let last = state.lastRefreshAt, Date().timeIntervalSince(last) < 60 { return }
            Task { await state.refreshUsage() }
        }
    }

    private var header: some View {
        HStack {
            Text("Codex 账号").font(.headline)
            Spacer()
            if let last = state.lastRefreshAt {
                Text(last, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            Button {
                Task { await state.refreshUsage() }
            } label: {
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(state.isRefreshing)
            .help("刷新额度")
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有账号").font(.subheadline)
            Text("点击下方「添加账号」会运行 codex login；登录完成后账号自动入库。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.codexProcessCount > 0 {
                Label(
                    "\(state.codexProcessCount) 个 Codex 进程运行中，切换只对新会话生效",
                    systemImage: "info.circle"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("添加账号…") { Task { await state.loginViaCodex() } }
                    .disabled(state.isBusy)
                    .help("运行 codex login，在浏览器里登录另一个 ChatGPT 账号")
                Spacer()
                Toggle("开机自启", isOn: $state.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            HStack {
                Text("只替换 ~/.codex/auth.json，不改其他配置")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .font(.caption)
            }
        }
    }
}

struct AccountCard: View {
    let entry: AccountEntry
    let isBusy: Bool
    let onSwitch: () -> Void
    let onLogin: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.email).font(.system(.body, weight: .semibold)).lineLimit(1)
                    Text(entry.planLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            if let usage = entry.usage {
                ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                    WindowRow(
                        window: window,
                        baselinePercent: window == usage.headlineWindow ? entry.pace?.plannedPercent : nil
                    )
                }
                if usage.windows.isEmpty {
                    Text("接口未返回额度窗口").font(.caption).foregroundStyle(.secondary)
                }
                if let pace = entry.pace {
                    PaceSection(pace: pace)
                }
            }
            if let error = entry.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }

            HStack {
                if entry.needsLogin {
                    Button("重新登录…", action: onLogin).disabled(isBusy)
                } else if !entry.isActive {
                    Button("切换到此账号", action: onSwitch)
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                }
                Spacer()
                if !entry.isActive {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("从工具里移除这个账号快照（不影响 ChatGPT 账号本身）")
                    .disabled(isBusy)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(entry.isActive ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(entry.isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (text, color): (String, Color) = entry.needsLogin
            ? ("需重新登录", .orange)
            : entry.isActive ? ("使用中", .green) : ("待机", .gray)
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}

/// 一个额度窗口：标签、百分比、进度条（可叠加计划基准线）、重置时间。
struct WindowRow: View {
    let window: UsageWindow
    var baselinePercent: Double? = nil

    private var tint: Color {
        switch window.usedPercent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * window.usedPercent / 100)
                    if let baseline = baselinePercent {
                        Rectangle().fill(Color.primary.opacity(0.7))
                            .frame(width: 2, height: 12)
                            .offset(x: max(0, geo.size.width * min(baseline, 100) / 100 - 1))
                            .help("计划基准线：按时间线性推算此刻应当用到的比例")
                    }
                }
            }
            .frame(height: 8)
            if let reset = window.resetAt {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(ResetFormatter.relative(reset))
                    Text("·").foregroundStyle(.tertiary)
                    Text(ResetFormatter.absolute(reset))
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// 每周积分节奏：已用 / 计划 / 差距三格 + 速度预测与建议。
struct PaceSection: View {
    let pace: WeeklyPace

    private var gapColor: Color {
        switch pace.verdict {
        case .ahead: return .orange
        case .behind: return .green
        case .onTrack: return .secondary
        }
    }

    private var gapText: String {
        let g = Int(pace.gapPercent.rounded())
        switch pace.verdict {
        case .ahead: return "超前 \(g)%"
        case .behind: return "富余 \(-g)%"
        case .onTrack: return g >= 0 ? "+\(g)%" : "\(g)%"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                stat("当前已用", "\(Int(pace.usedPercent.rounded()))%", .primary)
                stat("计划截至当前", "\(Int(pace.plannedPercent.rounded()))%", .primary)
                stat("节奏差距", gapText, gapColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let rate = pace.recentRatePerHour, let projected = pace.projectedPercentAtReset {
                    if let exhaustion = pace.projectedExhaustionAt {
                        Label(
                            "最近 6 小时 \(rate, specifier: "%.1f")%/时，预计 \(ResetFormatter.relative(exhaustion).replacingOccurrences(of: "重置", with: "耗尽"))，早于重置",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.red)
                    } else {
                        Label(
                            "最近 6 小时 \(rate, specifier: "%.1f")%/时，按此速度重置前约用到 \(Int(projected.rounded()))%",
                            systemImage: "speedometer"
                        )
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Label("速度采样中，约 20 分钟后给出预测", systemImage: "speedometer")
                        .foregroundStyle(.tertiary)
                }
                Label(
                    "要撑到重置：每天 ≤ \(pace.sustainablePercentPerDay, specifier: "%.1f")%（剩余 \(Int(pace.remainingPercent.rounded()))%）",
                    systemImage: "gauge.with.needle"
                )
                .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
        .padding(.top, 2)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

/// 设备码登录提示：链接 + 一次性代码，可复制到任意浏览器（含隐私窗口）用另一个账号登录。
struct LoginPromptBox: View {
    let prompt: LoginSession.Prompt
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("在浏览器打开链接并输入代码（换账号可用隐私窗口）", systemImage: "key.horizontal")
                .font(.caption.weight(.semibold))
            HStack(spacing: 6) {
                Text(prompt.url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("复制") { copy(prompt.url) }.font(.caption)
                Button("打开") {
                    if let url = URL(string: prompt.url) { NSWorkspace.shared.open(url) }
                }.font(.caption)
            }
            HStack(spacing: 6) {
                Text(prompt.code).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                Spacer()
                Button("复制代码") { copy(prompt.code) }.font(.caption)
            }
            Text("代码 15 分钟内有效。授权完成后这里会自动更新。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum ResetFormatter {
    static func relative(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 60 { return "即将重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days) 天 \(hours) 小时后重置" : "\(days) 天后重置" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟后重置" }
        return "\(minutes) 分钟后重置"
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE HH:mm"
        return f
    }()

    static func absolute(_ date: Date) -> String { absoluteFormatter.string(from: date) }
}
