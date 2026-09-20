import Foundation

/// 被存活 Codex 进程持有的会话锁。锁文件存在不代表活跃，必须由 lsof 证明仍有持有者。
public struct ActiveCodexThread: Equatable, Sendable {
    public let id: String
    public let processId: Int32

    public init(id: String, processId: Int32) {
        self.id = id
        self.processId = processId
    }
}

public struct CodexRateLimitWindow: Equatable, Sendable {
    public let windowSeconds: Int
    public let resetAt: Date

    public init(windowSeconds: Int, resetAt: Date) {
        self.windowSeconds = windowSeconds
        self.resetAt = resetAt
    }
}

/// 会话自身最后记录的额度窗口，用于给功能上线前已经存在的会话做唯一账号匹配。
public struct CodexRateLimitFingerprint: Equatable, Sendable {
    public let planType: String?
    public let windows: [CodexRateLimitWindow]

    public init(planType: String?, windows: [CodexRateLimitWindow]) {
        self.planType = planType
        self.windows = windows
    }
}

public struct CodexSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let processId: Int32
    public let createdAt: Date?
    public let updatedAt: Date?
    public let title: String
    public let latestUserMessage: String?
    public let cwd: String?
    public let rateLimitFingerprint: CodexRateLimitFingerprint?

    public init(
        id: String,
        processId: Int32,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        title: String = "",
        latestUserMessage: String? = nil,
        cwd: String? = nil,
        rateLimitFingerprint: CodexRateLimitFingerprint? = nil
    ) {
        self.id = id
        self.processId = processId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.latestUserMessage = latestUserMessage
        self.cwd = cwd
        self.rateLimitFingerprint = rateLimitFingerprint
    }
}

public enum CodexSessionError: LocalizedError {
    case appServerUnavailable
    case appServerFailed(String)
    case appServerTimedOut

    public var errorDescription: String? {
        switch self {
        case .appServerUnavailable:
            return "找不到可读取会话信息的 Codex 可执行文件"
        case .appServerFailed(let reason):
            return "读取 Codex 会话失败：\(reason)"
        case .appServerTimedOut:
            return "读取 Codex 会话超时"
        }
    }
}

public extension CodexProcess {
    /// 返回当前真正被 Codex 进程持有的会话锁。已退出进程遗留的空锁文件不会被计入。
    static func activeThreads(codexHome: URL? = nil) -> [ActiveCodexThread] {
        let home = codexHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let locksDirectory = home.appendingPathComponent("thread-writer-locks", isDirectory: true)
        let lockURLs = ((try? FileManager.default.contentsOfDirectory(
            at: locksDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "lock" }
        guard !lockURLs.isEmpty else { return [] }

        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-n", "-P", "-F", "pcfn", "--"] + lockURLs.map(\.path)
        let output = Pipe()
        lsof.standardOutput = output
        lsof.standardError = FileHandle.nullDevice
        do { try lsof.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        return parseActiveThreads(String(decoding: data, as: UTF8.self))
    }

    /// lsof 的 field output 以 p/c/f/n 分段；只接受命令名精确为 codex 且文件名是 UUID.lock 的记录。
    static func parseActiveThreads(_ output: String) -> [ActiveCodexThread] {
        var currentPID: Int32?
        var currentCommand: String?
        var found: [String: ActiveCodexThread] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                currentPID = Int32(value)
                currentCommand = nil
            case "c":
                currentCommand = value
            case "n":
                guard currentCommand == "codex", let pid = currentPID else { continue }
                let url = URL(fileURLWithPath: value)
                guard url.pathExtension == "lock" else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil else { continue }
                found[id] = ActiveCodexThread(id: id, processId: pid)
            default:
                continue
            }
        }
        return found.values.sorted { lhs, rhs in
            lhs.processId == rhs.processId ? lhs.id < rhs.id : lhs.processId < rhs.processId
        }
    }
}

/// 通过当前 Codex 二进制的 app-server 只读协议补齐会话元数据。
/// 新启动的 app-server 不代表这些会话归它所有，因此活跃性仍以会话锁为准。
public enum CodexSessionReader {
    public static func read(
        activeThreads: [ActiveCodexThread],
        executable: URL?,
        codexHome: URL,
        timeout: TimeInterval = 8
    ) async -> [CodexSession] {
        guard !activeThreads.isEmpty else { return [] }
        guard let executable else {
            return activeThreads.map { CodexSession(id: $0.id, processId: $0.processId) }
        }

        do {
            return try await withThrowingTaskGroup(of: [CodexSession].self) { group in
                group.addTask {
                    try await query(activeThreads: activeThreads, executable: executable, codexHome: codexHome)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw CodexSessionError.appServerTimedOut
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            return activeThreads.map { CodexSession(id: $0.id, processId: $0.processId) }
        }
    }

    private static func query(
        activeThreads: [ActiveCodexThread], executable: URL, codexHome: URL
    ) async throws -> [CodexSession] {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let writer = input.fileHandleForWriting
        defer {
            try? writer.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        try writeRequest(
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex-account-switch",
                    "title": "Codex Account Switch",
                    "version": "1",
                ],
                "capabilities": ["experimentalApi": true],
            ],
            to: writer
        )

        var iterator = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        var initialized = false
        while let line = try await iterator.next() {
            try Task.checkCancellation()
            guard let message = decodeObject(line) else { continue }
            if number(message["id"]) == 1 {
                if let error = message["error"] as? [String: Any] {
                    throw CodexSessionError.appServerFailed(error["message"] as? String ?? "初始化失败")
                }
                initialized = true
                break
            }
        }
        guard initialized else { throw CodexSessionError.appServerFailed("初始化响应缺失") }

        var requestToThread: [Int: (threadId: String, kind: ResponseKind)] = [:]
        for (index, thread) in activeThreads.enumerated() {
            let readId = 1_000 + index
            let turnsId = 2_000 + index
            requestToThread[readId] = (thread.id, .thread)
            requestToThread[turnsId] = (thread.id, .turn)
            try writeRequest(
                id: readId, method: "thread/read",
                params: ["threadId": thread.id, "includeTurns": false], to: writer
            )
            try writeRequest(
                id: turnsId, method: "thread/turns/list",
                params: [
                    "threadId": thread.id,
                    "limit": 1,
                    "sortDirection": "desc",
                    "itemsView": "summary",
                ],
                to: writer
            )
        }

        var metadata: [String: ThreadMetadata] = [:]
        var latestMessages: [String: String] = [:]
        var completed = Set<Int>()
        while completed.count < requestToThread.count, let line = try await iterator.next() {
            try Task.checkCancellation()
            guard let message = decodeObject(line),
                  let requestId = number(message["id"]),
                  let request = requestToThread[requestId] else { continue }
            completed.insert(requestId)
            guard message["error"] == nil, let result = message["result"] as? [String: Any] else { continue }
            switch request.kind {
            case .thread:
                if let thread = result["thread"] as? [String: Any] {
                    metadata[request.threadId] = parseThreadMetadata(thread)
                }
            case .turn:
                if let text = parseLatestUserMessage(result) { latestMessages[request.threadId] = text }
            }
        }

        return activeThreads.map { active in
            let item = metadata[active.id]
            let latest = latestMessages[active.id]
            let title = cleanTitle(item?.name) ?? cleanTitle(item?.preview) ?? cleanTitle(latest) ?? "未命名会话"
            let fingerprint = item?.path.flatMap { latestRateLimitFingerprint(in: URL(fileURLWithPath: $0)) }
            return CodexSession(
                id: active.id,
                processId: active.processId,
                createdAt: item?.createdAt,
                updatedAt: item?.updatedAt,
                title: title,
                latestUserMessage: latest ?? item?.preview,
                cwd: item?.cwd,
                rateLimitFingerprint: fingerprint
            )
        }.sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }

    private enum ResponseKind { case thread, turn }

    private struct ThreadMetadata {
        let createdAt: Date?
        let updatedAt: Date?
        let name: String?
        let preview: String?
        let cwd: String?
        let path: String?
    }

    private static func writeRequest(
        id: Int, method: String, params: [String: Any], to handle: FileHandle
    ) throws {
        let object: [String: Any] = ["id": id, "method": method, "params": params]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func decodeObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseThreadMetadata(_ object: [String: Any]) -> ThreadMetadata {
        ThreadMetadata(
            createdAt: timestamp(object["createdAt"]),
            updatedAt: timestamp(object["updatedAt"]),
            name: object["name"] as? String,
            preview: object["preview"] as? String,
            cwd: object["cwd"] as? String,
            path: object["path"] as? String
        )
    }

    private static func parseLatestUserMessage(_ result: [String: Any]) -> String? {
        guard let turns = result["data"] as? [[String: Any]], let turn = turns.first,
              let items = turn["items"] as? [[String: Any]] else { return nil }
        for item in items where item["type"] as? String == "userMessage" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// 标题只取第一条非空行，避免把长 prompt 整段塞进列表。
    public static func cleanTitle(_ value: String?) -> String? {
        guard let line = value?
            .split(whereSeparator: \Character.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return String(line.prefix(120))
    }

    /// 从文件尾向前找最近一次 token_count，只读最多 maxBytes，避免大历史会话拖慢菜单刷新。
    public static func latestRateLimitFingerprint(
        in fileURL: URL, maxBytes: Int = 8 * 1_024 * 1_024
    ) -> CodexRateLimitFingerprint? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }

        let chunkSize: UInt64 = 64 * 1_024
        let lowerBound = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        var position = end
        var carry = Data()

        while position > lowerBound {
            let start = max(lowerBound, position > chunkSize ? position - chunkSize : 0)
            let length = Int(position - start)
            do {
                try handle.seek(toOffset: start)
                guard let chunk = try handle.read(upToCount: length) else { return nil }
                var combined = chunk
                combined.append(carry)
                let parts = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
                let completeStart = start == 0 ? 0 : 1
                if parts.count > completeStart {
                    for part in parts[completeStart...].reversed() {
                        if let fingerprint = parseRateLimitLine(Data(part)) { return fingerprint }
                    }
                }
                carry = parts.first.map { Data($0) } ?? Data()
                position = start
            } catch {
                return nil
            }
        }
        if lowerBound == 0 { return parseRateLimitLine(carry) }
        return nil
    }

    private static func parseRateLimitLine(_ data: Data) -> CodexRateLimitFingerprint? {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("\"rate_limits\""), text.contains("\"token_count\""),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }

        let windows = ["primary", "secondary"].compactMap { key -> CodexRateLimitWindow? in
            guard let raw = limits[key] as? [String: Any],
                  let minutes = (raw["window_minutes"] as? NSNumber)?.intValue,
                  let reset = (raw["resets_at"] as? NSNumber)?.doubleValue,
                  minutes > 0, reset.isFinite else { return nil }
            return CodexRateLimitWindow(
                windowSeconds: minutes * 60,
                resetAt: Date(timeIntervalSince1970: reset)
            )
        }
        guard !windows.isEmpty else { return nil }
        return CodexRateLimitFingerprint(planType: limits["plan_type"] as? String, windows: windows)
    }
}
