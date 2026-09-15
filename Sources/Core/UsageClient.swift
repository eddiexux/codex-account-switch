import Foundation

public struct UsageWindow: Equatable {
    public let usedPercent: Double
    public let windowSeconds: Int?
    public let resetAt: Date?

    public init(usedPercent: Double, windowSeconds: Int?, resetAt: Date?) {
        self.usedPercent = usedPercent
        self.windowSeconds = windowSeconds
        self.resetAt = resetAt
    }

    /// 按窗口长度给出人类可读标签：Codex 目前只有 5 小时窗和 7 天窗两种。
    public var label: String {
        guard let seconds = windowSeconds else { return "额度" }
        if seconds >= 6 * 86_400 { return "每周" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) 小时" }
        return "\(seconds / 60) 分钟"
    }

    static func parse(_ raw: Any?) -> UsageWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        let used = (dict["used_percent"] as? NSNumber)?.doubleValue ?? 0
        let seconds = (dict["limit_window_seconds"] as? NSNumber)?.intValue
        let resetAt = (dict["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(usedPercent: min(max(used, 0), 100), windowSeconds: seconds, resetAt: resetAt)
    }
}

/// `additional_rate_limits` 里按模型单独计量的额度（例如 GPT-5.3-Codex-Spark）。
public struct NamedRateLimit: Equatable, Identifiable {
    public let name: String
    public let primary: UsageWindow?
    public let secondary: UsageWindow?

    public init(name: String, primary: UsageWindow?, secondary: UsageWindow?) {
        self.name = name
        self.primary = primary
        self.secondary = secondary
    }

    public var id: String { name }
    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }

    static func parse(_ raw: Any) -> NamedRateLimit? {
        guard let dict = raw as? [String: Any], let name = dict["limit_name"] as? String else { return nil }
        let limit = dict["rate_limit"] as? [String: Any]
        return NamedRateLimit(
            name: name,
            primary: UsageWindow.parse(limit?["primary_window"]),
            secondary: UsageWindow.parse(limit?["secondary_window"])
        )
    }
}

/// usage 接口里附带的重置卡摘要：`available_count` 是名下可用张数，
/// `applicable_available_count` 是此刻真正能用上的张数（没有窗口达上限时为 0）。
public struct ResetCreditSummary: Equatable {
    public let availableCount: Int
    public let applicableCount: Int

    public init(availableCount: Int, applicableCount: Int) {
        self.availableCount = availableCount
        self.applicableCount = applicableCount
    }

    static func parse(_ raw: Any?) -> ResetCreditSummary? {
        guard let dict = raw as? [String: Any] else { return nil }
        return ResetCreditSummary(
            availableCount: max((dict["available_count"] as? NSNumber)?.intValue ?? 0, 0),
            applicableCount: max((dict["applicable_available_count"] as? NSNumber)?.intValue ?? 0, 0)
        )
    }
}

public struct UsageSnapshot: Equatable {
    public let email: String?
    public let planType: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let limitReached: Bool
    public let fetchedAt: Date
    public let additionalLimits: [NamedRateLimit]
    public let resetCredits: ResetCreditSummary?

    public init(
        email: String?, planType: String?, primary: UsageWindow?, secondary: UsageWindow?,
        limitReached: Bool, fetchedAt: Date,
        additionalLimits: [NamedRateLimit] = [], resetCredits: ResetCreditSummary? = nil
    ) {
        self.email = email
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.limitReached = limitReached
        self.fetchedAt = fetchedAt
        self.additionalLimits = additionalLimits
        self.resetCredits = resetCredits
    }

    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }

    /// 菜单栏上显示的那个百分比：优先周窗（更能代表账号还剩多少），否则取第一个窗。
    public var headlineWindow: UsageWindow? {
        windows.first(where: { ($0.windowSeconds ?? 0) >= 6 * 86_400 }) ?? windows.first
    }

    public static func parse(_ object: [String: Any], fetchedAt: Date = Date()) -> UsageSnapshot {
        let rateLimit = object["rate_limit"] as? [String: Any]
        let additional = (object["additional_rate_limits"] as? [Any])?.compactMap(NamedRateLimit.parse) ?? []
        return UsageSnapshot(
            email: object["email"] as? String,
            planType: object["plan_type"] as? String,
            primary: UsageWindow.parse(rateLimit?["primary_window"]),
            secondary: UsageWindow.parse(rateLimit?["secondary_window"]),
            limitReached: (rateLimit?["limit_reached"] as? Bool) ?? false,
            fetchedAt: fetchedAt,
            additionalLimits: additional,
            resetCredits: ResetCreditSummary.parse(object["rate_limit_reset_credits"])
        )
    }
}

public enum UsageError: LocalizedError {
    case unauthorized
    case http(Int, String)
    case network(String)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "令牌已失效（401）"
        case .http(let code, let message): return "接口返回 \(code)：\(message)"
        case .network(let message): return "网络错误：\(message)"
        case .malformed: return "响应格式不符合预期"
        }
    }
}

/// 直接调用 ChatGPT 后端的用量接口，与 Codex CLI `/status` 使用的是同一个数据源。
public enum UsageClient {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static func fetch(accessToken: String, accountId: String) async throws -> UsageSnapshot {
        let object = try await ChatGPTBackend.requestJSON(endpoint, accessToken: accessToken, accountId: accountId)
        return UsageSnapshot.parse(object)
    }
}

/// ChatGPT 后端通用请求：Bearer + chatgpt-account-id，401 → unauthorized，其余非 2xx 带上服务端错误信息。
enum ChatGPTBackend {
    static func requestJSON(
        _ url: URL, accessToken: String, accountId: String, method: String = "GET", body: Data? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.malformed }
        if http.statusCode == 401 { throw UsageError.unauthorized }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw UsageError.http(http.statusCode, errorMessage(object, fallback: data))
        }
        guard let object else { throw UsageError.malformed }
        return object
    }

    /// 服务端错误体形如 `{"error": {"code": "...", "message": "..."}}`，也可能是纯文本。
    static func errorMessage(_ object: [String: Any]?, fallback: Data) -> String {
        if let error = object?["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? (error["error_description"] as? String) ?? ""
            let code = error["code"] as? String
            switch (code, message.isEmpty) {
            case (let code?, false): return "\(message)（\(code)）"
            case (let code?, true): return code
            case (nil, false): return message
            case (nil, true): break
            }
        }
        if let error = object?["error"] as? String { return error }
        if let message = object?["message"] as? String { return message }
        return String(data: fallback.prefix(200), encoding: .utf8) ?? ""
    }
}
