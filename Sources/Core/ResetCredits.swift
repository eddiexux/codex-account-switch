import Foundation

/// 一张"用量限额重置卡"（rate limit reset credit）。OpenAI 会不定期赠送，兑换后把已达上限的额度窗口清零。
/// 字段与 `GET /backend-api/wham/rate-limit-reset-credits` 一致；Codex TUI 与 codex-lb 都走这个接口。
public struct ResetCredit: Equatable, Identifiable {
    public let id: String
    public let resetType: String?
    public let status: String?
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let title: String?
    public let description: String?
    public let isSupportedByPlan: Bool

    public init(
        id: String, resetType: String?, status: String?, grantedAt: Date?, expiresAt: Date?,
        title: String?, description: String?, isSupportedByPlan: Bool
    ) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
        self.isSupportedByPlan = isSupportedByPlan
    }

    public var isAvailable: Bool { status == "available" }

    static func parse(_ raw: Any) -> ResetCredit? {
        guard let dict = raw as? [String: Any], let id = dict["id"] as? String, !id.isEmpty else { return nil }
        return ResetCredit(
            id: id,
            resetType: dict["reset_type"] as? String,
            status: dict["status"] as? String,
            grantedAt: ISO8601.parse(dict["granted_at"]),
            expiresAt: ISO8601.parse(dict["expires_at"]),
            title: dict["title"] as? String,
            description: dict["description"] as? String,
            isSupportedByPlan: (dict["is_supported_by_plan"] as? Bool) ?? true
        )
    }
}

/// 某账号名下的全部重置卡。
public struct ResetCreditList: Equatable {
    public let credits: [ResetCredit]
    /// 接口给的可用张数；以它为准，`credits` 里的 status 只用来挑选具体哪一张。
    public let availableCount: Int
    public let fetchedAt: Date

    public init(credits: [ResetCredit], availableCount: Int, fetchedAt: Date = Date()) {
        self.credits = credits
        self.availableCount = availableCount
        self.fetchedAt = fetchedAt
    }

    public var available: [ResetCredit] { credits.filter(\.isAvailable) }

    /// 兑换时优先用最早过期的那张（与 codex-lb 一致），避免卡在手里白白过期。
    public var soonestExpiring: ResetCredit? {
        guard availableCount > 0 else { return nil }
        return available.min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    public var nearestExpiresAt: Date? { soonestExpiring?.expiresAt }

    public static func parse(_ object: [String: Any], fetchedAt: Date = Date()) throws -> ResetCreditList {
        guard let rawCredits = object["credits"] as? [Any] else { throw UsageError.malformed }
        let credits = rawCredits.compactMap(ResetCredit.parse)
        let count = (object["available_count"] as? NSNumber)?.intValue ?? credits.filter(\.isAvailable).count
        return ResetCreditList(credits: credits, availableCount: max(count, 0), fetchedAt: fetchedAt)
    }
}

/// `POST …/rate-limit-reset-credits/consume` 的结果。`code` 取值来自 Codex 二进制里的枚举。
public struct ResetCreditConsumeOutcome: Equatable {
    public enum Code: Equatable {
        case reset
        case nothingToReset
        case noCredit
        case alreadyRedeemed
        case other(String)

        init(raw: String) {
            switch raw {
            case "reset": self = .reset
            case "nothing_to_reset": self = .nothingToReset
            case "no_credit": self = .noCredit
            case "already_redeemed": self = .alreadyRedeemed
            default: self = .other(raw)
            }
        }
    }

    public let code: Code
    public let windowsReset: Int

    public init(code: Code, windowsReset: Int) {
        self.code = code
        self.windowsReset = windowsReset
    }

    /// 与 Codex TUI 的提示语义对齐。
    public var message: String {
        switch code {
        case .reset: return windowsReset > 0 ? "已重置 \(windowsReset) 个额度窗口" : "已兑换，但额度未变化"
        case .nothingToReset: return "当前用量不需要重置（没有已达上限的窗口），重置卡未消耗"
        case .noCredit: return "没有可用的重置卡"
        case .alreadyRedeemed: return "这张重置卡已经用过了，刷新后再看"
        case .other(let raw): return "兑换结果：\(raw)"
        }
    }

    public static func parse(_ object: [String: Any]) throws -> ResetCreditConsumeOutcome {
        guard let raw = object["code"] as? String else { throw UsageError.malformed }
        return ResetCreditConsumeOutcome(
            code: Code(raw: raw),
            windowsReset: (object["windows_reset"] as? NSNumber)?.intValue ?? 0
        )
    }
}

/// 重置卡接口。与 `UsageClient` 同一鉴权方式（Bearer + chatgpt-account-id）。
public enum ResetCreditsClient {
    public static let listEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    public static let consumeEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!

    public static func fetch(accessToken: String, accountId: String) async throws -> ResetCreditList {
        let object = try await ChatGPTBackend.requestJSON(listEndpoint, accessToken: accessToken, accountId: accountId)
        return try ResetCreditList.parse(object)
    }

    /// 兑换不是幂等操作，失败不重试；`redeemRequestId` 由调用方生成，服务端据此去重。
    public static func consume(
        accessToken: String, accountId: String, creditId: String, redeemRequestId: String = UUID().uuidString
    ) async throws -> ResetCreditConsumeOutcome {
        let body = try JSONSerialization.data(withJSONObject: [
            "credit_id": creditId,
            "redeem_request_id": redeemRequestId,
        ])
        let object = try await ChatGPTBackend.requestJSON(
            consumeEndpoint, accessToken: accessToken, accountId: accountId, method: "POST", body: body
        )
        return try ResetCreditConsumeOutcome.parse(object)
    }
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}
