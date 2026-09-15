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
}

public struct UsageSnapshot: Equatable {
    public let email: String?
    public let planType: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let limitReached: Bool
    public let fetchedAt: Date

    public init(email: String?, planType: String?, primary: UsageWindow?, secondary: UsageWindow?, limitReached: Bool, fetchedAt: Date) {
        self.email = email
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.limitReached = limitReached
        self.fetchedAt = fetchedAt
    }

    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }

    /// 菜单栏上显示的那个百分比：优先周窗（更能代表账号还剩多少），否则取第一个窗。
    public var headlineWindow: UsageWindow? {
        windows.first(where: { ($0.windowSeconds ?? 0) >= 6 * 86_400 }) ?? windows.first
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
        case .malformed: return "额度响应格式不符合预期"
        }
    }
}

/// 直接调用 ChatGPT 后端的用量接口，与 Codex CLI `/status` 使用的是同一个数据源。
public enum UsageClient {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static func fetch(accessToken: String, accountId: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.malformed }
        if http.statusCode == 401 { throw UsageError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw UsageError.http(http.statusCode, body)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformed
        }
        let rateLimit = object["rate_limit"] as? [String: Any]
        return UsageSnapshot(
            email: object["email"] as? String,
            planType: object["plan_type"] as? String,
            primary: parseWindow(rateLimit?["primary_window"]),
            secondary: parseWindow(rateLimit?["secondary_window"]),
            limitReached: (rateLimit?["limit_reached"] as? Bool) ?? false,
            fetchedAt: Date()
        )
    }

    private static func parseWindow(_ raw: Any?) -> UsageWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        let used = (dict["used_percent"] as? NSNumber)?.doubleValue ?? 0
        let seconds = (dict["limit_window_seconds"] as? NSNumber)?.intValue
        let resetAt = (dict["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(usedPercent: min(max(used, 0), 100), windowSeconds: seconds, resetAt: resetAt)
    }
}
