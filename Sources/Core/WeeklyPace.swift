import Foundation

/// 一次用量采样：某账号某个窗口在某时刻的已用百分比。用于估算最近消耗速度。
public struct UsageSample: Codable, Equatable {
    public let at: Date
    public let usedPercent: Double
    /// 窗口重置时间，用来识别跨窗口的采样（重置后百分比归零，不能和上一窗口做差）。
    public let resetAt: Date?

    public init(at: Date, usedPercent: Double, resetAt: Date?) {
        self.at = at
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }
}

/// 每周积分节奏：把"已用百分比"放到时间轴上看，回答"我现在是快了还是慢了、照这个速度撑不撑得到重置"。
///
/// 计划基准线是线性的：窗口过去了 40% 的时间，就应当只用掉 40% 的额度。
/// 最近速度取历史采样里最近 `paceLookback` 内的首尾差；采样不足时只给基准线，不做预测。
public struct WeeklyPace: Equatable {
    public let usedPercent: Double
    /// 线性计划到当前时刻应当用掉的百分比。
    public let plannedPercent: Double
    /// used - planned；正数表示超前消耗。
    public let gapPercent: Double
    public let remainingPercent: Double
    public let remainingSeconds: TimeInterval
    /// 最近速度（百分点/小时），采样不足为 nil。
    public let recentRatePerHour: Double?
    /// 按最近速度，到重置时预计会用到的百分比（可超过 100）。
    public let projectedPercentAtReset: Double?
    /// 按最近速度预计耗尽的时刻；预计不会耗尽为 nil。
    public let projectedExhaustionAt: Date?
    /// 想刚好撑到重置，每天最多能用的百分点。
    public let sustainablePercentPerDay: Double

    public static let paceLookback: TimeInterval = 6 * 3600
    public static let minimumSampleSpan: TimeInterval = 20 * 60

    public init?(window: UsageWindow, samples: [UsageSample], now: Date = Date()) {
        guard let seconds = window.windowSeconds, seconds > 0, let resetAt = window.resetAt else { return nil }
        let windowStart = resetAt.addingTimeInterval(-Double(seconds))
        let elapsed = min(max(now.timeIntervalSince(windowStart), 0), Double(seconds))
        let remaining = max(resetAt.timeIntervalSince(now), 0)

        usedPercent = window.usedPercent
        plannedPercent = elapsed / Double(seconds) * 100
        gapPercent = usedPercent - plannedPercent
        remainingPercent = max(100 - usedPercent, 0)
        remainingSeconds = remaining
        sustainablePercentPerDay = remaining > 0 ? remainingPercent / (remaining / 86_400) : 0

        // 只用同一窗口、最近 lookback 内的采样；首尾跨度太短时速度噪声太大，放弃预测。
        let recent = samples
            .filter { $0.resetAt == resetAt && now.timeIntervalSince($0.at) <= Self.paceLookback }
            .sorted { $0.at < $1.at }
        if let first = recent.first, let last = recent.last,
           last.at.timeIntervalSince(first.at) >= Self.minimumSampleSpan {
            let hours = last.at.timeIntervalSince(first.at) / 3600
            let rate = max((last.usedPercent - first.usedPercent) / hours, 0)
            recentRatePerHour = rate
            projectedPercentAtReset = usedPercent + rate * (remaining / 3600)
            if rate > 0, let projected = projectedPercentAtReset, projected > 100 {
                projectedExhaustionAt = now.addingTimeInterval(remainingPercent / rate * 3600)
            } else {
                projectedExhaustionAt = nil
            }
        } else {
            recentRatePerHour = nil
            projectedPercentAtReset = nil
            projectedExhaustionAt = nil
        }
    }

    public enum Verdict: Equatable { case ahead, onTrack, behind }

    /// 超前 5 个百分点以上算"快了"，落后 5 个百分点以上算"有富余"。
    public var verdict: Verdict {
        if gapPercent > 5 { return .ahead }
        if gapPercent < -5 { return .behind }
        return .onTrack
    }
}

/// 用量历史落盘：`<App Support>/CodexAccountSwitch/usage-history.json`，按 account_id 分组，
/// 只保留最近 7 天且最多 2000 条，避免无限增长。
public final class UsageHistoryStore {
    public let fileURL: URL
    private var samples: [String: [UsageSample]]
    public static let retention: TimeInterval = 7 * 86_400
    public static let maxSamplesPerAccount = 2000

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = support
                .appendingPathComponent("CodexAccountSwitch", isDirectory: true)
                .appendingPathComponent("usage-history.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder.iso.decode([String: [UsageSample]].self, from: data) {
            samples = decoded
        } else {
            samples = [:]
        }
    }

    public func samples(for accountId: String) -> [UsageSample] {
        samples[accountId] ?? []
    }

    /// 记录一次采样并落盘。同一分钟内的重复采样会被合并，避免刷新按钮连点把历史撑大。
    public func record(accountId: String, window: UsageWindow, at now: Date = Date()) {
        var list = samples[accountId] ?? []
        if let last = list.last, now.timeIntervalSince(last.at) < 60 { list.removeLast() }
        list.append(UsageSample(at: now, usedPercent: window.usedPercent, resetAt: window.resetAt))
        list = list.filter { now.timeIntervalSince($0.at) <= Self.retention }
        if list.count > Self.maxSamplesPerAccount { list.removeFirst(list.count - Self.maxSamplesPerAccount) }
        samples[accountId] = list
        persist()
    }

    public func remove(accountId: String) {
        samples[accountId] = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder.iso.encode(samples) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? AccountStore.atomicWrite(data, to: fileURL)
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
