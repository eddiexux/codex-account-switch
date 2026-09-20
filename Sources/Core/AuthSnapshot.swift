import Foundation

public enum AuthFileError: LocalizedError {
    case malformed
    case missingAccountId
    case notChatGPTLogin

    public var errorDescription: String? {
        switch self {
        case .malformed: return "auth.json 不是合法的 Codex 登录文件"
        case .missingAccountId: return "auth.json 缺少 account_id"
        case .notChatGPTLogin: return "auth.json 不是 ChatGPT 登录模式（可能是 API key 模式）"
        }
    }
}

/// 一份完整的 `auth.json` 内容。原始字节原样保留，所有回写都用原始字节，
/// 避免因序列化差异丢掉 Codex 未来新增的字段。
public struct AuthSnapshot {
    public let data: Data
    public let accountId: String
    public let email: String?
    public let planType: String?
    public let accessToken: String
    public let refreshToken: String
    public let accessTokenExpiresAt: Date?
    public let lastRefresh: String?
    /// ChatGPT 订阅（会员）到期时间；来自 id_token 里的 chatgpt_subscription_active_until 字段。
    /// API key 模式或旧版 token 里没有此字段时为 nil。
    public let subscriptionActiveUntil: Date?

    public init(data: Data) throws {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
            let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty
        else { throw AuthFileError.malformed }

        let idClaims = (tokens["id_token"] as? String).flatMap(JWT.claims) ?? [:]
        let accessClaims = JWT.claims(accessToken) ?? [:]
        let authClaims = idClaims["https://api.openai.com/auth"] as? [String: Any]

        let accountId = (tokens["account_id"] as? String)
            ?? (authClaims?["chatgpt_account_id"] as? String)
        guard let accountId, !accountId.isEmpty else { throw AuthFileError.missingAccountId }

        self.data = data
        self.accountId = accountId
        self.email = idClaims["email"] as? String
        self.planType = authClaims?["chatgpt_plan_type"] as? String
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = (accessClaims["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        self.lastRefresh = object["last_refresh"] as? String
        self.subscriptionActiveUntil = ISO8601.parse(authClaims?["chatgpt_subscription_active_until"])
    }

    public static func load(from url: URL) throws -> AuthSnapshot {
        try AuthSnapshot(data: Data(contentsOf: url))
    }

    /// 访问令牌是否会在 `within` 秒内过期（未知过期时间按需要刷新处理）。
    public func accessTokenExpires(within seconds: TimeInterval) -> Bool {
        guard let exp = accessTokenExpiresAt else { return true }
        return exp.timeIntervalSinceNow < seconds
    }

    /// 用一次刷新得到的新令牌替换 tokens 字段，其余字段原样保留。
    public func replacingTokens(idToken: String?, accessToken: String, refreshToken: String) throws -> AuthSnapshot {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = object["tokens"] as? [String: Any]
        else { throw AuthFileError.malformed }
        if let idToken { tokens["id_token"] = idToken }
        tokens["access_token"] = accessToken
        tokens["refresh_token"] = refreshToken
        object["tokens"] = tokens
        object["last_refresh"] = ISO8601DateFormatter.withFractionalSeconds.string(from: Date())
        let newData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return try AuthSnapshot(data: newData)
    }

    /// 用于界面展示的短名：邮箱本地部分，没有邮箱就用 account_id 前 8 位。
    public var displayName: String {
        if let email { return email }
        return String(accountId.prefix(8))
    }
}

public enum JWT {
    /// 只解码 payload，不校验签名：这里只用于读取展示信息，不用于鉴权决策。
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension ISO8601DateFormatter {
    public static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
