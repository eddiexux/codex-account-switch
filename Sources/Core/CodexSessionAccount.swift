import Foundation

public struct CodexAccountUsageEvidence: Equatable {
    public let accountId: String
    public let planType: String?
    public let currentWindows: [UsageWindow]
    public let historicalWeeklyResetDates: [Date]

    public init(
        accountId: String,
        planType: String?,
        currentWindows: [UsageWindow],
        historicalWeeklyResetDates: [Date]
    ) {
        self.accountId = accountId
        self.planType = planType
        self.currentWindows = currentWindows
        self.historicalWeeklyResetDates = historicalWeeklyResetDates
    }
}

public enum CodexSessionAccountMatcher {
    /// 只有一个账号的窗口指纹命中时才返回；两个账号重置时间碰巧相同必须降级为未知。
    public static func uniqueAccountId(
        fingerprint: CodexRateLimitFingerprint?,
        accounts: [CodexAccountUsageEvidence]
    ) -> String? {
        guard let fingerprint else { return nil }
        var matches = Set<String>()
        for account in accounts {
            if let plan = fingerprint.planType, let accountPlan = account.planType,
               plan.caseInsensitiveCompare(accountPlan) != .orderedSame { continue }

            let matchesCurrent = fingerprint.windows.contains { sessionWindow in
                account.currentWindows.contains { accountWindow in
                    guard accountWindow.windowSeconds == sessionWindow.windowSeconds,
                          let reset = accountWindow.resetAt else { return false }
                    return abs(reset.timeIntervalSince(sessionWindow.resetAt)) <= 1
                }
            }
            let matchesHistory = fingerprint.windows.contains { sessionWindow in
                guard sessionWindow.windowSeconds >= 6 * 86_400 else { return false }
                return account.historicalWeeklyResetDates.contains {
                    abs($0.timeIntervalSince(sessionWindow.resetAt)) <= 1
                }
            }
            if matchesCurrent || matchesHistory { matches.insert(account.accountId) }
        }
        return matches.count == 1 ? matches.first : nil
    }
}

public struct CodexSessionAccountBinding: Codable, Equatable, Sendable {
    public let accountId: String
    public let observedAt: Date

    public init(accountId: String, observedAt: Date) {
        self.accountId = accountId
        self.observedAt = observedAt
    }
}

/// 只保存创建时亲眼观察到的账号归属；额度匹配属于可重新计算的推断，不写入这里。
public final class CodexSessionAccountStore {
    public let fileURL: URL
    private var bindings: [String: CodexSessionAccountBinding]

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = support
                .appendingPathComponent("CodexAccountSwitch", isDirectory: true)
                .appendingPathComponent("session-accounts.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder.iso.decode([String: CodexSessionAccountBinding].self, from: data) {
            bindings = decoded
        } else {
            bindings = [:]
        }
    }

    public func binding(for sessionId: String) -> CodexSessionAccountBinding? {
        bindings[sessionId]
    }

    /// first-writer-wins：已确认会话绝不能在之后的账号切换中被重绑。
    public func bindIfAbsent(sessionIds: Set<String>, accountId: String, at now: Date = Date()) {
        guard !accountId.isEmpty else { return }
        var changed = false
        for sessionId in sessionIds where bindings[sessionId] == nil {
            bindings[sessionId] = CodexSessionAccountBinding(accountId: accountId, observedAt: now)
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder.iso.encode(bindings) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? AccountStore.atomicWrite(data, to: fileURL)
    }
}
