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
    /// 名下重置卡明细；只有 usage 说有可用卡时才会去拉，拉失败为 nil。
    var resetCredits: ResetCreditList?

    var id: String { snapshot.accountId }
    var email: String { snapshot.displayName }
    var planLabel: String {
        let plan = usage?.planType ?? snapshot.planType ?? ""
        return plan.isEmpty ? "—" : plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// 可用重置卡张数：明细优先，没有明细就用 usage 里的摘要。
    var availableResetCredits: Int {
        resetCredits?.availableCount ?? usage?.resetCredits?.availableCount ?? 0
    }

    /// 此刻有没有已达上限的窗口可以被重置卡清零。
    var resetCreditApplicable: Bool {
        (usage?.resetCredits?.applicableCount ?? 0) > 0 || usage?.limitReached == true
    }

    var canRedeemResetCredit: Bool { availableResetCredits > 0 && !needsLogin }

    /// id_token 里解析到的 ChatGPT 会员到期时间；没有此字段时为 nil。
    var subscriptionActiveUntil: Date? { snapshot.subscriptionActiveUntil }

    /// 会员是否在 7 天内到期（日期未知时返回 false）。
    var isSubscriptionExpiringSoon: Bool {
        guard let until = subscriptionActiveUntil else { return false }
        return until.timeIntervalSinceNow < 7 * 86_400
    }
}

enum SessionAccountEvidence: Equatable {
    case observed
    case usageMatch
    case unknown
}

struct ActiveSessionEntry: Identifiable, Equatable {
    let session: CodexSession
    let accountId: String?
    let accountLabel: String
    let evidence: SessionAccountEvidence

    var id: String { session.id }
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
    private(set) var activeSessions: [ActiveSessionEntry] = []
    private(set) var isRefreshingSessions = false
    /// 设备码登录进行中时的链接与一次性代码，面板据此展示。
    private(set) var loginPrompt: LoginSession.Prompt?
    private var loginSession: LoginSession?
    /// GUI 窗口里当前选中的账号；nil 表示跟随活跃账号。
    var selectedAccountId: String?
    var statusMessage: String? {
        didSet { if let statusMessage { AppLog.write(statusMessage) } }
    }
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { applyLaunchAtLogin() }
    }

    private let store = AccountStore()
    private let history = UsageHistoryStore()
    private let sessionAccounts = CodexSessionAccountStore()
    private var timer: Timer?
    private var usageCache: [String: UsageSnapshot] = [:]
    private var resetCreditCache: [String: ResetCreditList] = [:]
    private var needsLoginCache: Set<String> = []
    /// 启动时已经存在的会话只作为基线，不直接绑定当前账号；之后新出现的会话才可确定归属。
    private var observedSessionIds: Set<String> = []

    nonisolated static let refreshInterval: TimeInterval = 5 * 60
    /// 待机账号的访问令牌距过期不足 24 小时就提前续期，避免在界面上显示过期数据。
    nonisolated static let refreshTokenLeadTime: TimeInterval = 24 * 3600

    init() {
        reloadEntries()
        observedSessionIds = Set(CodexProcess.activeThreads(codexHome: store.codexHome).map(\.id))
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshUsage() }
        }
        Task { await refreshUsage() }
    }

    var activeEntry: AccountEntry? { entries.first(where: \.isActive) }

    /// 详情窗口侧边栏"全部账号"总览页的选中标识，与真实 account_id 不会冲突。
    nonisolated static let overviewSelectionId = "__overview__"
    nonisolated static let sessionsSelectionId = "__sessions__"
    var showsOverview: Bool { selectedAccountId == Self.overviewSelectionId }
    var showsSessions: Bool { selectedAccountId == Self.sessionsSelectionId }

    /// 全局节奏：所有拿到周节奏的账号合成一个池子；需重新登录或额度未加载的账号计入 excludedCount。
    var combinedPace: CombinedPace? {
        let members = entries.compactMap { entry in
            entry.pace.map { CombinedPace.Member(accountId: entry.id, label: entry.email, pace: $0) }
        }
        return CombinedPace(members: members, excludedCount: entries.count - members.count)
    }

    var selectedEntry: AccountEntry? {
        entries.first(where: { $0.id == selectedAccountId }) ?? activeEntry ?? entries.first
    }

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

    func usageSamples(for accountId: String) -> [UsageSample] {
        history.samples(for: accountId)
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
                pace: pace(accountId: slot.accountId, usage: usageCache[slot.accountId]),
                resetCredits: resetCreditCache[slot.accountId]
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

        await withTaskGroup(of: FetchOutcome.self) { group in
            for entry in entries {
                group.addTask { [store] in
                    await Self.fetchUsage(for: entry, store: store)
                }
            }
            for await outcome in group {
                guard let index = entries.firstIndex(where: { $0.id == outcome.id }) else { continue }
                let id = outcome.id
                if let renewed = outcome.renewed {
                    entries[index] = AccountEntry(
                        snapshot: renewed, isActive: entries[index].isActive,
                        usage: entries[index].usage, errorMessage: nil, needsLogin: false,
                        resetCredits: entries[index].resetCredits
                    )
                }
                switch outcome.result {
                case .success(let usage):
                    usageCache[id] = usage
                    resetCreditCache[id] = outcome.resetCredits
                    needsLoginCache.remove(id)
                    if let window = usage.headlineWindow { history.record(accountId: id, window: window) }
                    entries[index].usage = usage
                    entries[index].pace = pace(accountId: id, usage: usage)
                    entries[index].resetCredits = outcome.resetCredits
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
        await refreshCodexSessions()
    }

    /// 刷新活跃会话独立于额度请求；失败时至少保留会话 ID/PID，不影响账号切换。
    func refreshCodexSessions() async {
        guard !isRefreshingSessions else { return }
        isRefreshingSessions = true
        defer { isRefreshingSessions = false }

        let codexHome = store.codexHome
        let executable = CodexProcess.executable()
        let threads = await Task.detached {
            CodexProcess.activeThreads(codexHome: codexHome)
        }.value
        captureNewSessions(threads, accountId: activeEntry?.id)
        let sessions = await CodexSessionReader.read(
            activeThreads: threads, executable: executable, codexHome: codexHome
        )
        activeSessions = sessions.map(resolveAccount)
        codexProcessCount = CodexProcess.runningCount()
    }

    private func captureNewSessions(_ threads: [ActiveCodexThread], accountId: String?) {
        let ids = Set(threads.map(\.id))
        let newlyObserved = ids.subtracting(observedSessionIds)
        if let accountId { sessionAccounts.bindIfAbsent(sessionIds: newlyObserved, accountId: accountId) }
        observedSessionIds.formUnion(ids)
    }

    private func resolveAccount(for session: CodexSession) -> ActiveSessionEntry {
        if let binding = sessionAccounts.binding(for: session.id) {
            return ActiveSessionEntry(
                session: session,
                accountId: binding.accountId,
                accountLabel: accountLabel(binding.accountId),
                evidence: .observed
            )
        }
        if let accountId = uniqueUsageMatch(for: session.rateLimitFingerprint) {
            return ActiveSessionEntry(
                session: session,
                accountId: accountId,
                accountLabel: accountLabel(accountId),
                evidence: .usageMatch
            )
        }
        return ActiveSessionEntry(
            session: session, accountId: nil, accountLabel: "账号未知", evidence: .unknown
        )
    }

    private func accountLabel(_ accountId: String) -> String {
        entries.first(where: { $0.id == accountId })?.email ?? "\(accountId.prefix(8))…"
    }

    /// 只接受唯一匹配。窗口时长和 resetAt 同时相同最强；7 天历史采样只用于补足刚好刷新失败的账号。
    private func uniqueUsageMatch(for fingerprint: CodexRateLimitFingerprint?) -> String? {
        let evidence = entries.map { entry in
            CodexAccountUsageEvidence(
                accountId: entry.id,
                planType: entry.usage?.planType ?? entry.snapshot.planType,
                currentWindows: entry.usage?.windows ?? [],
                historicalWeeklyResetDates: history.samples(for: entry.id).compactMap(\.resetAt)
            )
        }
        return CodexSessionAccountMatcher.uniqueAccountId(fingerprint: fingerprint, accounts: evidence)
    }

    private func pace(accountId: String, usage: UsageSnapshot?) -> WeeklyPace? {
        guard let window = usage?.headlineWindow else { return nil }
        return WeeklyPace(window: window, samples: history.samples(for: accountId))
    }

    private struct FetchOutcome {
        let id: String
        let result: Result<UsageSnapshot, Error>
        let renewed: AuthSnapshot?
        let resetCredits: ResetCreditList?
    }

    /// 单个账号的额度获取。待机账号在令牌临期或 401 时先续期再重试；活跃账号从不由工具续期。
    /// usage 说名下有重置卡时顺便拉明细（拿过期时间）；明细失败不影响额度本身。
    nonisolated private static func fetchUsage(for entry: AccountEntry, store: AccountStore) async -> FetchOutcome {
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

        func fetchBoth() async throws -> (UsageSnapshot, ResetCreditList?) {
            let usage = try await UsageClient.fetch(accessToken: snapshot.accessToken, accountId: snapshot.accountId)
            guard (usage.resetCredits?.availableCount ?? 0) > 0 else { return (usage, nil) }
            let credits = try? await ResetCreditsClient.fetch(accessToken: snapshot.accessToken, accountId: snapshot.accountId)
            return (usage, credits)
        }

        if canRenew, snapshot.accessTokenExpires(within: refreshTokenLeadTime), let err = await renew() {
            return FetchOutcome(id: entry.id, result: .failure(err), renewed: nil, resetCredits: nil)
        }
        do {
            let (usage, credits) = try await fetchBoth()
            return FetchOutcome(id: entry.id, result: .success(usage), renewed: renewed, resetCredits: credits)
        } catch UsageError.unauthorized where canRenew && renewed == nil {
            if let err = await renew() { return FetchOutcome(id: entry.id, result: .failure(err), renewed: nil, resetCredits: nil) }
            do {
                let (usage, credits) = try await fetchBoth()
                return FetchOutcome(id: entry.id, result: .success(usage), renewed: renewed, resetCredits: credits)
            } catch {
                return FetchOutcome(id: entry.id, result: .failure(error), renewed: renewed, resetCredits: nil)
            }
        } catch {
            return FetchOutcome(id: entry.id, result: .failure(error), renewed: renewed, resetCredits: nil)
        }
    }

    // MARK: 动作

    func switchTo(accountId: String) {
        guard !isBusy, let target = entries.first(where: { $0.id == accountId }), !target.isActive else { return }
        isBusy = true
        busyMessage = "正在切换到 \(target.email)…"
        defer { isBusy = false; busyMessage = nil }
        // 在 auth.json 改变前冻结刚出现会话的账号归属；已有映射 first-writer-wins。
        captureNewSessions(CodexProcess.activeThreads(codexHome: store.codexHome), accountId: activeEntry?.id)
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

    /// 兑换一张重置卡：先重新拉明细（以服务端为准，不用缓存），挑最早过期的那张，再 POST consume。
    /// 兑换不幂等，任何失败都不重试；结果以刷新后的额度为准。
    func redeemResetCredit(accountId: String) async {
        guard !isBusy, let entry = entries.first(where: { $0.id == accountId }), !entry.needsLogin else { return }
        isBusy = true
        busyMessage = "正在为 \(entry.email) 兑换重置卡…"
        defer { isBusy = false; busyMessage = nil }

        let snapshot = entry.snapshot
        do {
            let list = try await ResetCreditsClient.fetch(accessToken: snapshot.accessToken, accountId: snapshot.accountId)
            resetCreditCache[accountId] = list
            if let index = entries.firstIndex(where: { $0.id == accountId }) { entries[index].resetCredits = list }
            guard let credit = list.soonestExpiring else {
                statusMessage = "\(entry.email) 没有可用的重置卡"
                return
            }
            let requestId = UUID().uuidString
            AppLog.write("兑换重置卡：\(entry.email) credit=\(credit.id.suffix(8)) request=\(requestId.prefix(8))")
            let outcome = try await ResetCreditsClient.consume(
                accessToken: snapshot.accessToken, accountId: snapshot.accountId,
                creditId: credit.id, redeemRequestId: requestId
            )
            statusMessage = "\(entry.email)：\(outcome.message)"
        } catch UsageError.unauthorized {
            statusMessage = entry.isActive
                ? "\(entry.email) 的访问令牌已过期，等 Codex 续期后再试"
                : "\(entry.email) 的令牌已失效，先刷新一次再试"
        } catch {
            statusMessage = "兑换失败：\(error.localizedDescription)"
        }
        resetCreditCache[accountId] = nil
        await refreshUsage()
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
            captureNewSessions(CodexProcess.activeThreads(codexHome: store.codexHome), accountId: previous?.accountId)
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
            resetCreditCache[accountId] = nil
            needsLoginCache.remove(accountId)
            history.remove(accountId: accountId)
            if selectedAccountId == accountId { selectedAccountId = nil }
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
