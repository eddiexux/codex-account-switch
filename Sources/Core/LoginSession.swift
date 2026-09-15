import Foundation

/// 一次 `codex login --device-auth` 会话。
///
/// 选设备码流程而不是浏览器流程的原因：它不自动弹默认浏览器、不占本机回调端口，
/// 用户可以把链接和一次性代码粘到任意浏览器（含隐私窗口）用不同账号登录。
public final class LoginSession {
    public struct Prompt: Equatable {
        public let url: String
        public let code: String
    }

    public enum Outcome: Equatable {
        case succeeded
        case cancelled
        case failed(status: Int32, output: String)
    }

    private let process = Process()
    private let pipe = Pipe()
    private var buffer = ""
    private var prompt: Prompt?
    private var cancelled = false
    private let lock = NSLock()

    public init() {}

    /// 启动登录进程；提示（链接 + 代码）一旦出现在输出里就回调（主线程）。
    public func start(executable: URL, onPrompt: @escaping (Prompt) -> Void) throws {
        process.executableURL = executable
        process.arguments = ["login", "--device-auth"]
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["NO_COLOR"] = "1"
        process.environment = env
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            self.lock.lock()
            self.buffer += chunk
            let found = self.prompt == nil ? Self.parsePrompt(self.buffer) : nil
            if let found { self.prompt = found }
            self.lock.unlock()
            if let found { DispatchQueue.main.async { onPrompt(found) } }
        }
        AppLog.write("启动 codex login --device-auth：\(executable.path)")
        try process.run()
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// 等待进程退出并给出结果；输出尾部只用于报错展示。
    public func waitUntilExit() async -> Outcome {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                self.process.waitUntilExit()
                self.pipe.fileHandleForReading.readabilityHandler = nil
                let rest = self.pipe.fileHandleForReading.readDataToEndOfFile()
                self.lock.lock()
                self.buffer += String(decoding: rest, as: UTF8.self)
                let output = Self.stripANSI(self.buffer)
                let cancelled = self.cancelled
                self.lock.unlock()
                let status = self.process.terminationStatus
                if cancelled { cont.resume(returning: .cancelled) }
                else if status == 0 { cont.resume(returning: .succeeded) }
                else { cont.resume(returning: .failed(status: status, output: String(output.suffix(600)))) }
            }
        }
    }

    /// 解析 Codex 的提示文本：
    /// "1. Open this link in your browser ...\n   <url>\n\n2. Enter this one-time code ...\n   <code>"
    public static func parsePrompt(_ raw: String) -> Prompt? {
        let text = stripANSI(raw)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let url = lines.first(where: { $0.hasPrefix("https://") }) else { return nil }
        guard let codeHeader = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("one-time code") }) else { return nil }
        let code = lines[(codeHeader + 1)...].first { !$0.isEmpty }
        guard let code, !code.isEmpty else { return nil }
        return Prompt(url: url, code: code)
    }

    public static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
