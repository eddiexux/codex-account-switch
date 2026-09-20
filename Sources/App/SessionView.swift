import SwiftUI
import CodexAccountSwitchCore

struct ActiveSessionsSidebarRow: View {
    let sessions: [ActiveSessionEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                Text("活跃会话").font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                Text("\(sessions.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            let known = sessions.filter { $0.evidence != .unknown }.count
            Text(known == sessions.count ? "账号归属已识别" : "\(known) 个已识别 · \(sessions.count - known) 个未知")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// 菜单面板只展示前三个会话的账号和内容摘要，完整时间与路径放在详情窗口。
struct CompactSessionList: View {
    let sessions: [ActiveSessionEntry]
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: onOpen) {
                HStack {
                    Label("活跃会话", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption.weight(.semibold))
                    Text("\(sessions.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(Array(sessions.prefix(3))) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle().fill(evidenceColor(entry.evidence)).frame(width: 6, height: 6)
                        Text(entry.accountLabel)
                            .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let updated = entry.session.updatedAt {
                            Text(updated, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text(entry.session.title)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let message = entry.session.latestUserMessage,
                       CodexSessionReader.cleanTitle(message) != entry.session.title {
                        Text(message)
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.leading, 2)
            }
            if sessions.count > 3 {
                Button("另外 \(sessions.count - 3) 个…", action: onOpen)
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
            }
            Text("切换账号只影响之后新建的会话")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

struct ActiveSessionsView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("活跃 Codex 会话").font(.title2.weight(.semibold))
                        Text("只列出仍被存活 Codex 进程持有的会话；账号未知时不会猜测。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await state.refreshCodexSessions() }
                    } label: {
                        if state.isRefreshingSessions {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(state.isRefreshingSessions)
                }

                if state.activeSessions.isEmpty {
                    ContentUnavailableView(
                        "没有活跃会话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("新建 Codex 会话后刷新即可看到账号归属和内容摘要。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ForEach(state.activeSessions) { entry in
                        SessionCard(entry: entry)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("活跃会话")
    }
}

private struct SessionCard: View {
    let entry: ActiveSessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.session.title)
                        .font(.headline).lineLimit(2)
                    HStack(spacing: 6) {
                        Label(entry.accountLabel, systemImage: evidenceIcon(entry.evidence))
                            .foregroundStyle(evidenceColor(entry.evidence))
                        Text(evidenceText(entry.evidence)).foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
                Spacer(minLength: 12)
                Text("PID \(entry.session.processId)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }

            if let message = entry.session.latestUserMessage {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近请求").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                        .textSelection(.enabled)
                }
            }

            Divider()
            HStack(spacing: 18) {
                SessionTimeLabel(title: "创建", date: entry.session.createdAt)
                SessionTimeLabel(title: "更新", date: entry.session.updatedAt)
                if let cwd = entry.session.cwd {
                    Label(URL(fileURLWithPath: cwd).lastPathComponent, systemImage: "folder")
                        .help(cwd)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text(entry.session.id.prefix(8) + "…")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .help(entry.session.id)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.055))
                .strokeBorder(Color.secondary.opacity(0.12))
        )
    }
}

private struct SessionTimeLabel: View {
    let title: String
    let date: Date?

    var body: some View {
        if let date {
            HStack(spacing: 3) {
                Text(title)
                Text(date, style: .date)
                Text(date, style: .time)
            }
        } else {
            Text("\(title)时间未知")
        }
    }
}

private func evidenceText(_ evidence: SessionAccountEvidence) -> String {
    switch evidence {
    case .observed: return "创建时确认"
    case .usageMatch: return "额度唯一匹配"
    case .unknown: return "证据不足"
    }
}

private func evidenceIcon(_ evidence: SessionAccountEvidence) -> String {
    switch evidence {
    case .observed: return "checkmark.circle.fill"
    case .usageMatch: return "waveform.path.ecg"
    case .unknown: return "questionmark.circle"
    }
}

private func evidenceColor(_ evidence: SessionAccountEvidence) -> Color {
    switch evidence {
    case .observed: return .green
    case .usageMatch: return .orange
    case .unknown: return .secondary
    }
}
