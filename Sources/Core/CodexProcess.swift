import Foundation

public enum CodexProcessError: LocalizedError {
    case executableNotFound
    case loginFailed(status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到 codex 可执行文件（查找了 ~/.local/bin、/opt/homebrew/bin、/usr/local/bin 和 PATH）"
        case .loginFailed(let status, let output):
            return "codex login 退出码 \(status)\n\(output)"
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

    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// 运行 `codex login`（浏览器 OAuth 流程）。成功后 Codex 自己会写入 auth.json。
    /// 在后台线程阻塞等待进程退出；失败时把输出尾部带回给界面。
    public static func runLogin() async throws {
        guard let exe = executable() else { throw CodexProcessError.executableNotFound }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = exe
                proc.arguments = ["login"]
                var env = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                proc.environment = env
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                proc.standardInput = FileHandle.nullDevice
                do { try proc.run() } catch {
                    cont.resume(throwing: error)
                    return
                }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let text = String(decoding: output, as: UTF8.self)
                    cont.resume(throwing: CodexProcessError.loginFailed(
                        status: proc.terminationStatus, output: String(text.suffix(600))
                    ))
                }
            }
        }
    }
}
