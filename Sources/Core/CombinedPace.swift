import Foundation

/// 全局节奏：把所有账号的周窗放进同一个池子看，回答"几个账号加起来是快了还是慢了、总共还撑多久"。
///
/// 口径：每个账号的周额度算 1 份（100 点），不区分套餐的绝对量；所有百分比都是"池子口径"，
/// 即各账号百分比的平均值。单账号 5%/时的消耗在两账号池子里就是 2.5%/时，与"池子剩余 55%"直接可比。
/// 各账号的重置时间互不相同，所以只预测到**最早**那次重置；重置后池子会回补该账号已用的份额。
public struct CombinedPace: Equatable {
    public struct Member: Equatable, Identifiable {
        public let accountId: String
        public let label: String
        public let pace: WeeklyPace

        public init(accountId: String, label: String, pace: WeeklyPace) {
            self.accountId = accountId
            self.label = label
            self.pace = pace
        }

        public var id: String { accountId }
    }

    /// 按重置时间从早到晚排序。
    public let members: [Member]
    /// 没有节奏数据（需重新登录、额度未加载）而被排除在池子外的账号数。
    public let excludedCount: Int
    public let usedPercent: Double
    public let plannedPercent: Double
    public let gapPercent: Double
    public let remainingPercent: Double
    /// 池子口径的最近速度（百分点/小时）：有采样的账号速度之和 ÷ 账号数；没有任何账号有采样时为 nil。
    public let recentRatePerHour: Double?
    /// 速度里覆盖了几个账号；小于账号数说明有账号还在采样中，合计速度偏低。
    public let rateSampledCount: Int
    /// 想让每个账号都刚好撑到各自的重置，每天合计最多能用的池子百分点。
    public let sustainablePercentPerDay: Double
    /// 最早重置的账号。
    public let nextReset: Member
    /// 按合计速度，到最早重置时池子预计用到的百分比（可超过 100）。
    public let projectedPercentAtNextReset: Double?
    /// 按合计速度，池子在最早重置**之前**耗尽的时刻；撑得到下次重置为 nil。
    public let projectedExhaustionAt: Date?

    public var accountCount: Int { members.count }

    public init?(members: [Member], excludedCount: Int = 0, now: Date = Date()) {
        guard !members.isEmpty else { return nil }
        let sorted = members.sorted { $0.pace.resetAt < $1.pace.resetAt }
        let count = Double(sorted.count)
        self.members = sorted
        self.excludedCount = excludedCount
        usedPercent = sorted.map(\.pace.usedPercent).reduce(0, +) / count
        plannedPercent = sorted.map(\.pace.plannedPercent).reduce(0, +) / count
        gapPercent = usedPercent - plannedPercent
        remainingPercent = sorted.map(\.pace.remainingPercent).reduce(0, +) / count
        sustainablePercentPerDay = sorted.map(\.pace.sustainablePercentPerDay).reduce(0, +) / count
        nextReset = sorted[0]

        let rates = sorted.compactMap(\.pace.recentRatePerHour)
        rateSampledCount = rates.count
        if rates.isEmpty {
            recentRatePerHour = nil
            projectedPercentAtNextReset = nil
            projectedExhaustionAt = nil
        } else {
            let rate = rates.reduce(0, +) / count
            recentRatePerHour = rate
            let hoursToNextReset = max(nextReset.pace.resetAt.timeIntervalSince(now), 0) / 3600
            projectedPercentAtNextReset = usedPercent + rate * hoursToNextReset
            if rate > 0, let projected = projectedPercentAtNextReset, projected > 100 {
                projectedExhaustionAt = now.addingTimeInterval(remainingPercent / rate * 3600)
            } else {
                projectedExhaustionAt = nil
            }
        }
    }

    public var verdict: WeeklyPace.Verdict {
        if gapPercent > 5 { return .ahead }
        if gapPercent < -5 { return .behind }
        return .onTrack
    }

    /// 按重置顺序累计到某账号重置之后（假设期间不再消耗），池子剩余会回到多少。
    public func remainingPercentAfterResets(through member: Member) -> Double {
        guard let index = members.firstIndex(of: member) else { return remainingPercent }
        let restored = members[...index].map(\.pace.usedPercent).reduce(0, +)
        return remainingPercent + restored / Double(members.count)
    }
}
