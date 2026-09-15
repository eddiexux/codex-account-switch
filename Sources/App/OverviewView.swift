import SwiftUI
import Charts
import CodexAccountSwitchCore

/// 全部账号总览：把各账号的周窗合成一个池子看节奏，再逐账号并排对比，附重置时间线与合并用量曲线。
struct OverviewView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let pool = state.combinedPace {
                    DetailSection("合计节奏", systemImage: "speedometer") { CombinedPaceSection(pool: pool) }
                    DetailSection("逐账号对比", systemImage: "rectangle.split.2x1") { comparison(pool) }
                    DetailSection("重置时间线", systemImage: "calendar.badge.clock") { timeline(pool) }
                } else {
                    Text("还没有任何账号拿到周额度数据，刷新后再看。").font(.caption).foregroundStyle(.secondary)
                }
                historySection
                ActivityFooter(state: state)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("全部账号").font(.title2.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        guard let pool = state.combinedPace else { return "\(state.entries.count) 个账号" }
        var text = "\(pool.accountCount) 个账号合池，每个账号的周额度按 100% 等权（套餐不同时绝对额度并不相同）"
        if pool.excludedCount > 0 { text += "；另有 \(pool.excludedCount) 个账号没有周额度数据，未计入" }
        return text
    }

    // MARK: 逐账号对比

    private func comparison(_ pool: CombinedPace) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(["账号", "已用", "计划", "差距", "最近速度", "每天可用", "重置"], id: \.self) { Text($0) }
            }
            .font(.caption2).foregroundStyle(.secondary)
            Divider()
            ForEach(pool.members) { member in
                GridRow {
                    HStack(spacing: 5) {
                        if let entry = state.entries.first(where: { $0.id == member.accountId }) {
                            Circle().fill(entry.isActive ? Color.green : Color.gray).frame(width: 6, height: 6)
                        }
                        Text(member.label).lineLimit(1).truncationMode(.middle)
                    }
                    Text("\(Int(member.pace.usedPercent.rounded()))%")
                        .foregroundStyle(UsageTint.color(member.pace.usedPercent))
                    Text("\(Int(member.pace.plannedPercent.rounded()))%")
                    Text(PaceFormat.gapText(member.pace.gapPercent, verdict: member.pace.verdict))
                        .foregroundStyle(PaceFormat.gapColor(member.pace.verdict))
                    Text(member.pace.recentRatePerHour.map(PaceFormat.rate) ?? "采样中")
                        .foregroundStyle(member.pace.recentRatePerHour == nil ? .tertiary : .primary)
                    Text(String(format: "≤ %.1f%%", member.pace.sustainablePercentPerDay))
                    Text(ResetFormatter.relative(member.pace.resetAt)).foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
            Divider()
            GridRow {
                Text("合计（池子口径）").fontWeight(.semibold)
                Text("\(Int(pool.usedPercent.rounded()))%").foregroundStyle(UsageTint.color(pool.usedPercent))
                Text("\(Int(pool.plannedPercent.rounded()))%")
                Text(PaceFormat.gapText(pool.gapPercent, verdict: pool.verdict))
                    .foregroundStyle(PaceFormat.gapColor(pool.verdict))
                Text(pool.recentRatePerHour.map(PaceFormat.rate) ?? "采样中")
                    .foregroundStyle(pool.recentRatePerHour == nil ? .tertiary : .primary)
                Text(String(format: "≤ %.1f%%", pool.sustainablePercentPerDay))
                Text("最早 \(ResetFormatter.relative(pool.nextReset.pace.resetAt))").foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: 重置时间线

    private func timeline(_ pool: CombinedPace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pool.members) { member in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.secondary)
                    Text(ResetFormatter.absolute(member.pace.resetAt)).font(.caption.monospacedDigit())
                    Text(ResetFormatter.relative(member.pace.resetAt)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(member.label).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text("回补 \(Int(member.pace.usedPercent.rounded()))% → 池子约 \(Int(pool.remainingPercentAfterResets(through: member).rounded()))%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Text("「池子约 N%」按此刻剩余量累计各次重置回补，不含期间的消耗。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: 合并用量曲线

    private var historySection: some View {
        DetailSection("用量历史（最近 7 天，各账号叠放）", systemImage: "chart.xyaxis.line") {
            let total = state.entries.reduce(0) { $0 + state.usageSamples(for: $1.id).count }
            if total < 2 {
                Text("采样不足，每次刷新会记录一次各账号的周额度用量。").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(state.entries) { entry in
                        ForEach(state.usageSamples(for: entry.id), id: \.at) { sample in
                            LineMark(
                                x: .value("时间", sample.at),
                                y: .value("已用", sample.usedPercent),
                                series: .value("段", "\(entry.id)@\(sample.resetAt?.timeIntervalSince1970 ?? 0)")
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(by: .value("账号", entry.email))
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0.0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day().hour())
                } }
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 170)
                Text("每条线是一个账号；百分比归零处是该账号的窗口重置。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// 合计节奏：池子进度条（带计划基准线）+ 四格统计 + 合计速度预测与建议。
struct CombinedPaceSection: View {
    let pool: CombinedPace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WindowRow(
                window: UsageWindow(usedPercent: pool.usedPercent, windowSeconds: nil, resetAt: nil),
                baselinePercent: pool.plannedPercent, label: "合计已用（\(pool.accountCount) 个账号）"
            )
            HStack(spacing: 6) {
                StatTile(title: "合计已用", value: "\(Int(pool.usedPercent.rounded()))%")
                StatTile(title: "计划截至当前", value: "\(Int(pool.plannedPercent.rounded()))%")
                StatTile(
                    title: "节奏差距",
                    value: PaceFormat.gapText(pool.gapPercent, verdict: pool.verdict),
                    color: PaceFormat.gapColor(pool.verdict)
                )
                StatTile(title: "合计剩余", value: "\(Int(pool.remainingPercent.rounded()))%")
            }
            VStack(alignment: .leading, spacing: 3) {
                let next = pool.nextReset
                if let rate = pool.recentRatePerHour, let projected = pool.projectedPercentAtNextReset {
                    if let exhaustion = pool.projectedExhaustionAt {
                        Label(
                            "合计 \(PaceFormat.rate(rate))，预计 \(ResetFormatter.relative(exhaustion).replacingOccurrences(of: "重置", with: "耗尽"))，早于最早的重置（\(next.label)）",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.red)
                    } else {
                        Label(
                            "合计 \(PaceFormat.rate(rate))，按此速度到 \(next.label) 重置前池子约用到 \(Int(projected.rounded()))%",
                            systemImage: "speedometer"
                        )
                        .foregroundStyle(.secondary)
                    }
                    if pool.rateSampledCount < pool.accountCount {
                        Label(
                            "\(pool.accountCount - pool.rateSampledCount) 个账号的速度还在采样中，合计速度暂时偏低",
                            systemImage: "info.circle"
                        )
                        .foregroundStyle(.tertiary)
                    }
                } else {
                    Label("速度采样中，约 20 分钟后给出预测", systemImage: "speedometer").foregroundStyle(.tertiary)
                }
                Label(
                    "要让每个账号都撑到各自的重置：每天合计 ≤ \(pool.sustainablePercentPerDay, specifier: "%.1f")%",
                    systemImage: "gauge.with.needle"
                )
                .foregroundStyle(.secondary)
                Label(
                    "最早重置：\(next.label) \(ResetFormatter.relative(next.pace.resetAt))，届时池子回到约 \(Int(pool.remainingPercentAfterResets(through: next).rounded()))%",
                    systemImage: "clock"
                )
                .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
        .padding(.top, 2)
    }
}
