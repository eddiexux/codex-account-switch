import Foundation

enum CodexProcessError: LocalizedError {
    case executableNotFound

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到 codex 可执行文件（查找了 ChatGPT.app 内置、/opt/homebrew/bin、/usr/local/bin、~/.local/bin 和 PATH）"
        }
    }
}

public enum CodexProcess {
    /// 正在运行的 Codex 主进程数（app-server / TUI / exec），用来提示"切换只对新会话生效"。
    /// 排除 codex-lb、codex-hud、codex-code-mode-host 这类同前缀但无关的进程。
    public static func runningCount() -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return lines.filter { line in
            guard let first = line.split(separator: " ", maxSplits: 1).first else { return false }
            return URL(fileURLWithPath: String(first)).lastPathComponent == "codex"
        }.count
    }

    /// 优先用真正的原生二进制（ChatGPT.app 内置），避免 codex-hud / npm 这类包装器：
    /// 包装器被终止时其子进程会残留，曾造成登录回调端口被长期占用。
    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public static func requireExecutable() throws -> URL {
        guard let exe = executable() else { throw CodexProcessError.executableNotFound }
        return exe
    }
}
