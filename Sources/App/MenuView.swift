import SwiftUI
import CodexAccountSwitchCore

/// 菜单栏面板：只放一眼要看的东西——每个账号一行（周额度、重置时间、重置卡角标）和切换按钮。
/// 详情、节奏、历史曲线和重置卡兑换都在 GUI 窗口里。
struct MenuView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if state.entries.isEmpty {
                emptyHint
            } else {
                VStack(spacing: 6) {
                    ForEach(state.entries) { entry in
                        CompactAccountRow(entry: entry, isBusy: state.isBusy) {
                            state.switchTo(accountId: entry.id)
                        } onLogin: {
                            Task { await state.loginViaCodex() }
                        } onOpenDetail: {
                            MainWindowController.shared.show(state: state, selecting: entry.id)
                        }
                    }
                }
            }
            if let prompt = state.loginPrompt {
                LoginPromptBox(prompt: prompt) { state.cancelLogin() }
            }
            ActivityFooter(state: state)
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            if let last = state.lastRefreshAt, Date().timeIntervalSince(last) < 60 { return }
            Task { await state.refreshUsage() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
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
            Button {
                MainWindowController.shared.show(state: state, selecting: nil)
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("打开详情窗口：完整额度、节奏预测、用量历史、重置卡兑换")
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
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .font(.caption)
            }
        }
    }
}

/// 菜单栏里的账号一行：邮箱 · 套餐 · 状态；周额度条 + 重置时间；重置卡角标点开详情窗口。
struct CompactAccountRow: View {
    let entry: AccountEntry
    let isBusy: Bool
    let onSwitch: () -> Void
    let onLogin: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.email).font(.system(.callout, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(entry.planLabel).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if entry.availableResetCredits > 0 {
                    Button(action: onOpenDetail) {
                        ResetCreditBadge(count: entry.availableResetCredits, applicable: entry.resetCreditApplicable)
                    }
                    .buttonStyle(.plain)
                }
                StatusBadge(entry: entry)
            }
            if let window = entry.usage?.headlineWindow {
                WindowRow(window: window, baselinePercent: entry.pace?.plannedPercent, compact: true)
            } else if let error = entry.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2)
            } else {
                Text("额度加载中…").font(.caption2).foregroundStyle(.tertiary)
            }
            if entry.needsLogin || !entry.isActive {
                HStack {
                    if entry.needsLogin {
                        Button("重新登录…", action: onLogin).controlSize(.small).disabled(isBusy)
                    } else {
                        Button("切换到此账号", action: onSwitch)
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(isBusy)
                    }
                    Spacer()
                    Button("详情", action: onOpenDetail).buttonStyle(.borderless).controlSize(.small).font(.caption)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(entry.isActive ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(entry.isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpenDetail)
    }
}
