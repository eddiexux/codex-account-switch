import Foundation

public enum AccountStoreError: LocalizedError {
    case liveAuthMissing
    case slotMissing(String)
    case verificationFailed(expected: String, found: String?)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .liveAuthMissing: return "~/.codex/auth.json 不存在，请先 codex login"
        case .slotMissing(let id): return "没有找到账号快照 \(id.prefix(8))…"
        case .verificationFailed(let expected, let found):
            return "切换后校验失败：期望 \(expected.prefix(8))…，实际 \(found?.prefix(8) ?? "无")"
        case .writeFailed(let reason): return "写入失败：\(reason)"
        }
    }
}

/// 账号快照存储。
///
/// 业务不变量：
/// 1. `~/.codex/auth.json`（live）永远是它所属账号的权威数据；Codex 会在续期时轮换 refresh_token，
///    旧副本一旦复用就永久失效，所以任何切换前都必须先把 live 回写到对应槽位。
/// 2. 只替换 auth.json 这一个文件，绝不触碰 config.toml 或其他配置。
/// 3. 写 auth.json 走同目录临时文件 + rename，保证 Codex 任何时刻读到的都是完整文件。
public final class AccountStore {
    public let codexHome: URL
    public let slotsDirectory: URL

    public var liveAuthURL: URL { codexHome.appendingPathComponent("auth.json") }

    /// 默认读 `$CODEX_HOME`（缺省 `~/.codex`）和 `~/Library/Application Support/CodexAccountSwitch/accounts`；
    /// 测试时可注入临时目录。
    public init(codexHome: URL? = nil, slotsDirectory: URL? = nil) {
        if let codexHome {
            self.codexHome = codexHome
        } else if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            self.codexHome = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            self.codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        if let slotsDirectory {
            self.slotsDirectory = slotsDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.slotsDirectory = support
                .appendingPathComponent("CodexAccountSwitch", isDirectory: true)
                .appendingPathComponent("accounts", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.slotsDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: 读取

    public func loadLive() throws -> AuthSnapshot? {
        guard FileManager.default.fileExists(atPath: liveAuthURL.path) else { return nil }
        // Codex 自己写 auth.json 是 truncate + write，不是原子的；撞上写入中途就等一下再读一次。
        do {
            return try AuthSnapshot.load(from: liveAuthURL)
        } catch {
            Thread.sleep(forTimeInterval: 0.2)
            return try AuthSnapshot.load(from: liveAuthURL)
        }
    }

    public func loadSlots() -> [AuthSnapshot] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: slotsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? AuthSnapshot.load(from: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func slotURL(for accountId: String) -> URL {
        slotsDirectory.appendingPathComponent("\(accountId).json")
    }

    // MARK: 写入

    public func writeSlot(_ snapshot: AuthSnapshot) throws {
        try Self.atomicWrite(snapshot.data, to: slotURL(for: snapshot.accountId))
    }

    public func removeSlot(accountId: String) throws {
        let url = slotURL(for: accountId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 删除 live auth.json。`codex login` 开始前会对现有登录态执行 logout_with_revoke，
    /// 把当前账号的令牌在服务端作废；先回写槽位再删文件，登录流程就无东西可撤销。
    public func removeLive() throws {
        if FileManager.default.fileExists(atPath: liveAuthURL.path) {
            try FileManager.default.removeItem(at: liveAuthURL)
        }
    }

    /// 把 live auth.json 回写到它所属账号的槽位（不存在则新建）。返回 live 快照。
    @discardableResult
    public func syncLiveIntoSlot() throws -> AuthSnapshot? {
        guard let live = try loadLive() else { return nil }
        try writeSlot(live)
        return live
    }

    /// 切换到指定账号：先回写 live，再原子替换 auth.json，最后回读校验。
    public func activate(accountId: String) throws {
        let slotURL = slotURL(for: accountId)
        guard FileManager.default.fileExists(atPath: slotURL.path) else {
            throw AccountStoreError.slotMissing(accountId)
        }
        try syncLiveIntoSlot()
        let target = try AuthSnapshot.load(from: slotURL)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Self.atomicWrite(target.data, to: liveAuthURL)
        let verified = try loadLive()
        guard verified?.accountId == accountId else {
            throw AccountStoreError.verificationFailed(expected: accountId, found: verified?.accountId)
        }
    }

    /// 同目录临时文件 + rename，权限 0600。
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]
        ) else { throw AccountStoreError.writeFailed("无法创建临时文件 \(tmp.lastPathComponent)") }
        if rename(tmp.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw AccountStoreError.writeFailed(reason)
        }
    }
}
