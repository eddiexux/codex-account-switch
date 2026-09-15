import Foundation

public enum TokenRefreshError: LocalizedError {
    /// refresh_token 已过期 / 已被复用 / 被撤销，只能重新登录。
    case permanent(String)
    case transient(String)

    public var errorDescription: String? {
        switch self {
        case .permanent(let m): return "令牌无法续期，需要重新登录：\(m)"
        case .transient(let m): return "续期暂时失败：\(m)"
        }
    }
}

/// 只给**待机**账号续期。活跃账号的 auth.json 由 Codex 自己维护，工具绝不替它刷新，
/// 否则会和 Codex 进程的续期竞争同一条 refresh_token 链。
/// 端点、client_id 与请求体和 Codex CLI（codex-rs/login/src/auth/manager.rs）完全一致。
public enum TokenRefresher {
    public static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!
    public static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"

    public static func refresh(_ snapshot: AuthSnapshot) async throws -> AuthSnapshot {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": snapshot.refreshToken,
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TokenRefreshError.transient(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TokenRefreshError.transient("无 HTTP 响应")
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

        guard (200..<300).contains(http.statusCode) else {
            let code = (body["error"] as? String)
                ?? ((body["error"] as? [String: Any])?["code"] as? String)
                ?? ""
            let message = code.isEmpty ? "HTTP \(http.statusCode)" : code
            // 与 Codex 的判定一致：401，或 400 + invalid_grant / refresh_token_* 都是终态。
            let isPermanent = http.statusCode == 401
                || (http.statusCode == 400 && code.lowercased() == "invalid_grant")
                || code.lowercased().hasPrefix("refresh_token_")
            throw isPermanent ? TokenRefreshError.permanent(message) : TokenRefreshError.transient(message)
        }

        guard let accessToken = body["access_token"] as? String, !accessToken.isEmpty else {
            throw TokenRefreshError.transient("响应缺少 access_token")
        }
        // 服务端可能不轮换 refresh_token；缺省时沿用旧值。
        let refreshToken = (body["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.refreshToken
        return try snapshot.replacingTokens(
            idToken: body["id_token"] as? String,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }
}
