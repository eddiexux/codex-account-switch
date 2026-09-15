import SwiftUI
import CodexAccountSwitchCore

/// 账号状态胶囊：使用中 / 待机 / 需重新登录。
struct StatusBadge: View {
    let entry: AccountEntry

    var body: some View {
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

/// 重置卡角标：张数 + 是否此刻可用（有窗口达上限时高亮）。
struct ResetCreditBadge: View {
    let count: Int
    let applicable: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "ticket")
            Text("\(count)").monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill((applicable ? Color.accentColor : Color.secondary).opacity(0.15)))
        .foregroundStyle(applicable ? Color.accentColor : Color.secondary)
        .help(applicable ? "有 \(count) 张重置卡，且当前有已达上限的窗口可以清零" : "有 \(count) 张重置卡；当前没有达上限的窗口")
    }
}

enum UsageTint {
    static func color(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}

/// 一个额度窗口：标签、百分比、进度条（可叠加计划基准线）、重置时间。
struct WindowRow: View {
    let window: UsageWindow
    var baselinePercent: Double? = nil
    var compact = false

    private var tint: Color { UsageTint.color(window.usedPercent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if compact, let reset = window.resetAt {
                    Text(ResetFormatter.relative(reset)).font(.caption2).foregroundStyle(.secondary)
                }
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
            .frame(height: compact ? 6 : 8)
            if !compact, let reset = window.resetAt {
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

/// 忙碌提示 + 状态行，菜单与窗口共用。
struct ActivityFooter: View {
    @Bindable var state: AppState

    var body: some View {
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
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
        }
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

    /// 重置卡过期用的表述："N 天后过期"。
    static func expiry(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "已过期" }
        let days = seconds / 86_400
        if days > 0 { return "\(days) 天后过期" }
        let hours = seconds / 3600
        return hours > 0 ? "\(hours) 小时后过期" : "即将过期"
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE HH:mm"
        return f
    }()

    static func absolute(_ date: Date) -> String { absoluteFormatter.string(from: date) }
}
