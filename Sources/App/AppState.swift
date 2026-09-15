import Foundation
import CodexAccountSwitchCore
import Observation
import ServiceManagement

struct AccountEntry: Identifiable {
    let snapshot: AuthSnapshot
    var isActive: Bool
    var usage: UsageSnapshot?
    var errorMessage: String?
    /// refresh_token 已终态失效，只能重新登录。
    var needsLogin: Bool
    var pace: WeeklyPace?

    var id: String { snapshot.accountId }
    var email: String { snapshot.displayName }
    var planLabel: String {
        let plan = usage?.planType ?? snapshot.planType ?? ""
        return plan.isEmpty ? "—" : plan.prefix(1).uppercased() + plan.dropFirst()
    }
}

@MainActor
@Observable
final class AppState {
    private(set) var entries: [AccountEntry] = []
    private(set) var isRefreshing = false
    private(set) var isBusy = false
    private(set) var busyMessage: String?
    private(set) var lastRefreshAt: Date?
    private(set) var codexProcessCount = 0
    /// 设备码登录进行中时的链接与一次性代码，面板据此展示。
    private(set) var loginPrompt: LoginSession.Prompt?
    private var loginSession: LoginSession?
    var statusMessage: String? {
        didSet { if let statusMessage { AppLog.write(statusMessage) } }
    }
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { applyLaunchAtLogin() }
    }

    private let store = AccountStore()
    private let history = UsageHistoryStore()
    private var timer: Timer?
    private var usageCache: [String: UsageSnapshot] = [:]
    private var needsLoginCache: Set<String> = []

    nonisolated static let refreshInterval: TimeInterval = 5 * 60
    /// 待机账号的访问令牌距过期不足 24 小时就提前续期，避免在界面上显示过期数据。
    nonisolated static let refreshTokenLeadTime: TimeInterval = 24 * 3600

    init() {
        reloadEntries()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshUsage() }
        }
        Task { await refreshUsage() }
    }

    var activeEntry: AccountEntry? { entries.first(where: \.isActive) }

    /// 菜单栏文字：活跃账号周窗已用百分比；拿不到就留空只显示图标。
    var menuBarTitle: String {
        guard let window = activeEntry?.usage?.headlineWindow else { return "" }
        var title = "\(Int(window.usedPercent.rounded()))%"
        if let pace = activeEntry?.pace {
            switch pace.verdict {
            case .ahead: title += " ▲\(Int(pace.gapPercent.rounded()))"
            case .behind: title += " ▼\(Int((-pace.gapPercent).rounded()))"
            case .onTrack: break
            }
        }
        return title
    }

    var menuBarSymbol: String {
        if activeEntry == nil { return "person.crop.circle.badge.questionmark" }
        if activeEntry?.needsLogin == true { return "person.crop.circle.badge.exclamationmark" }
        return "person.crop.circle"
    }

    // MARK: 状态装载

    /// 把 live auth.json 回写到槽位，再从槽位目录重建列表。缓存的额度数据按 account_id 复用。
    func reloadEntries() {
        var live: AuthSnapshot?
        do {
            live = try store.syncLiveIntoSlot()
        } catch {
            statusMessage = "读取 auth.json 失败：\(error.localizedDescription)"
        }
        let liveId = live?.accountId
        entries = store.loadSlots().map { slot in
            AccountEntry(
                snapshot: slot,
                isActive: slot.accountId == liveId,
                usage: usageCache[slot.accountId],
                errorMessage: nil,
                needsLogin: needsLoginCache.contains(slot.accountId),
                pace: pace(accountId: slot.accountId, usage: usageCache[slot.accountId])
            )
        }
        codexProcessCount = CodexProcess.runningCount()
    }

    // MARK: 额度刷新

    func refreshUsage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        reloadEntries()

        await withTaskGroup(of: (String, Result<UsageSnapshot, Error>, AuthSnapshot?).self) { group in
            for entry in entries {
                group.addTask { [store] in
                    await Self.fetchUsage(for: entry, store: store)
                }
            }
            for await (id, result, renewed) in group {
                guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
                if let renewed { entries[index] = AccountEntry(
                    snapshot: renewed, isActive: entries[index].isActive,
                    usage: entries[index].usage, errorMessage: nil, needsLogin: false
                ) }
                switch result {
                case .success(let usage):
                    usageCache[id] = usage
                    needsLoginCache.remove(id)
                    if let window = usage.headlineWindow { history.record(accountId: id, window: window) }
                    entries[index].usage = usage
                    entries[index].pace = pace(accountId: id, usage: usage)
                    entries[index].errorMessage = nil
                    entries[index].needsLogin = false
                case .failure(let error):
                    entries[index].errorMessage = error.localizedDescription
                    if case TokenRefreshError.permanent = error {
                        needsLoginCache.insert(id)
                        entries[index].needsLogin = true
                    } else if entries[index].isActive, case UsageError.unauthorized = error {
                        // 活跃账号不由本工具续期。访问令牌已过期 → 等 Codex 下次请求自行刷新；
                        // 名义上未过期却被拒 → 已被服务端撤销，只能重新登录。
                        if entries[index].snapshot.accessTokenExpires(within: 0) {
                            entries[index].errorMessage = "访问令牌已过期，等待 Codex 续期"
                        } else {
                            needsLoginCache.insert(id)
                            entries[index].needsLogin = true
                            entries[index].errorMessage = "令牌已被撤销，需要重新登录"
                        }
                    }
                }
            }
        }
        lastRefreshAt = Date()
    }

    private func pace(accountId: String, usage: UsageSnapshot?) -> WeeklyPace? {
        guard let window = usage?.headlineWindow else { return nil }
        return WeeklyPace(window: window, samples: history.samples(for: accountId))
    }

    /// 单个账号的额度获取。待机账号在令牌临期或 401 时先续期再重试；活跃账号从不由工具续期。
    nonisolated private static func fetchUsage(
        for entry: AccountEntry, store: AccountStore
    ) async -> (String, Result<UsageSnapshot, Error>, AuthSnapshot?) {
        var snapshot = entry.snapshot
        var renewed: AuthSnapshot?
        let canRenew = !entry.isActive && !entry.needsLogin

        func renew() async -> Error? {
            do {
                let fresh = try await TokenRefresher.refresh(snapshot)
                try store.writeSlot(fresh)
                snapshot = fresh
                renewed = fresh
                return nil
            } catch {
                return error
            }
        }

        if canRenew, snapshot.accessTokenExpires(within: refreshTokenLeadTime), let err = await renew() {
            return (entry.id, .failure(err), nil)
        }
        do {
            let usage = try await UsageClient.fetch(accessToken: snapshot.accessToken, accountId: snapshot.accountId)
            return (entry.id, .success(usage), renewed)
        } catch UsageError.unauthorized where canRenew && renewed == nil {
            if let err = await renew() { return (entry.id, .failure(err), nil) }
            do {
                let usage = try await UsageClient.fetch(accessToken: snapshot.accessToken, accountId: snapshot.accountId)
                return (entry.id, .success(usage), renewed)
            } catch {
                return (entry.id, .failure(error), renewed)
            }
        } catch {
            return (entry.id, .failure(error), renewed)
        }
    }

    // MARK: 动作

    func switchTo(accountId: String) {
        guard !isBusy, let target = entries.first(where: { $0.id == accountId }), !target.isActive else { return }
        isBusy = true
        busyMessage = "正在切换到 \(target.email)…"
        defer { isBusy = false; busyMessage = nil }
        AppLog.write("切换：\(activeEntry?.email ?? "无") → \(target.email)")
        do {
            try store.activate(accountId: accountId)
            statusMessage = "已切换到 \(target.email)"
            reloadEntries()
            Task { await refreshUsage() }
        } catch {
            statusMessage = "切换失败：\(error.localizedDescription)"
            reloadEntries()
        }
    }

    /// 通过 `codex login --device-auth` 添加账号或重新登录：先回写并清空 live，
    /// 把链接和一次性代码展示在面板上，用户在任意浏览器完成后新账号自动入库。
    func loginViaCodex() async {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = "正在向 OpenAI 申请登录代码…"
        defer { isBusy = false; busyMessage = nil; loginPrompt = nil; loginSession = nil }
        // codex login 一启动就会对现有 auth.json 执行 logout_with_revoke（服务端作废令牌）。
        // 所以先回写槽位、再删掉 auth.json，让它无东西可撤销；失败时再从槽位恢复。
        let previous: AuthSnapshot?
        let executable: URL
        do {
            executable = try CodexProcess.requireExecutable()
            previous = try store.syncLiveIntoSlot()
            try store.removeLive()
        } catch {
            statusMessage = "登录前准备失败，已取消：\(error.localizedDescription)"
            return
        }
        AppLog.write("开始设备码登录（已回写并清空 live，上一账号：\(previous?.displayName ?? "无")）")
        let session = LoginSession()
        loginSession = session
        do {
            try session.start(executable: executable) { [weak self] prompt in
                self?.loginPrompt = prompt
                self?.busyMessage = "在浏览器里打开链接并输入代码，等待授权…"
            }
        } catch {
            restore(previous, reason: "无法启动 codex login：\(error.localizedDescription)")
            reloadEntries()
            return
        }
        switch await session.waitUntilExit() {
        case .succeeded:
            do {
                if let live = try store.syncLiveIntoSlot() {
                    needsLoginCache.remove(live.accountId)
                    statusMessage = "已登录 \(live.displayName)"
                } else {
                    restore(previous, reason: "登录未产生 auth.json")
                }
            } catch {
                restore(previous, reason: "读取新登录态失败：\(error.localizedDescription)")
            }
        case .cancelled:
            restore(previous, reason: "已取消登录")
        case .failed(let status, let output):
            restore(previous, reason: "登录未完成（codex 退出码 \(status)）：\(output.split(separator: "\n").last.map(String.init) ?? "")")
        }
        reloadEntries()
        await refreshUsage()
    }

    var loginSessionActive: Bool { loginSession != nil }

    func cancelLogin() {
        loginSession?.cancel()
    }

    private func restore(_ previous: AuthSnapshot?, reason: String) {
        guard let previous else {
            statusMessage = reason
            return
        }
        do {
            try store.activate(accountId: previous.accountId)
            statusMessage = "\(reason)；已恢复 \(previous.displayName)"
        } catch {
            statusMessage = "\(reason)；恢复 \(previous.displayName) 失败：\(error.localizedDescription)"
        }
    }

    func removeAccount(accountId: String) {
        guard let entry = entries.first(where: { $0.id == accountId }), !entry.isActive else { return }
        do {
            try store.removeSlot(accountId: accountId)
            usageCache[accountId] = nil
            needsLoginCache.remove(accountId)
            history.remove(accountId: accountId)
            reloadEntries()
        } catch {
            statusMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusMessage = "开机自启设置失败（需从 .app 包运行）：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
