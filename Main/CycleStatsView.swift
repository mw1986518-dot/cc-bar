import SwiftUI

/// 额度页「当前周期」：Codex / Claude × 5 小时 / 周的周期卡，宽画布一行四张。
/// 进度条的已用部分按项目分段（估算，见 `CycleProjectSplit`）；剩余状态由「官方 N%」的颜色表达。
struct QuotaCycleCardsSection: View {
    @Environment(AppState.self) private var appState
    /// 受侧栏服务筛选约束：全部 → Codex + Claude；单选时只含该服务。
    let apps: [UsageApp]
    let isWide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr("Current cycles", "当前周期"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr("Split by project is an estimate", "按项目拆分为估算"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if appState.usageService.isCycleRebuilding {
                    ProgressView().controlSize(.small)
                    Text(tr("Rebuilding current cycle data…", "正在补算当前周期数据…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                    count: isWide ? max(1, cards.count) : min(2, max(1, cards.count))
                ),
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(cards, id: \.self) { card in
                    currentCycleCard(app: card.app, kind: card.kind)
                }
            }
        }
    }

    private struct CardKey: Hashable {
        let app: UsageApp
        let kind: QuotaLimitKind
    }

    /// 固定顺序：Codex 5 小时、Codex 周、Claude 5 小时、Claude 周。
    private var cards: [CardKey] {
        [UsageApp.codex, .claude]
            .filter { apps.contains($0) }
            .flatMap { app in [CardKey(app: app, kind: .fiveHour), CardKey(app: app, kind: .weekly)] }
    }

    private func currentCycleCard(app: UsageApp, kind: QuotaLimitKind) -> some View {
        Group {
            if let summary = currentSummary(app: app, kind: kind) {
                cycleCardBody(summary, app: app, kind: kind)
            } else {
                cycleCardEmptyState(app: app, kind: kind)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: 188)
        .ccPanel(cornerRadius: 10)
    }

    /// 卡主体：标签行 → 用满预估 → 已用 + 官方比例 → 按项目分段的进度条 → 图例 → 倒计时。
    private func cycleCardBody(
        _ summary: CycleUsageSummary,
        app: UsageApp,
        kind: QuotaLimitKind
    ) -> some View {
        let usedPercent = max(0, min(100, summary.cycle.latestUsedPercent))
        let segments = projectSegments(summary, usedPercent: usedPercent)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ServiceTile(app: app, size: 12)
                Text("\(app.displayName) · \(cycleKindShort(kind))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let confidence = summary.forecastConfidence {
                    Text(forecastConfidenceText(confidence))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Full-use estimate", "用满预估"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(fullUseLine(summary))
                    .font(.system(size: 22, weight: .semibold))
                    .kerning(-0.5)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("\(tr("Used", "已用")) \(StatsFormatter.compactToken(summary.totals.totalTokens)) · \(StatsFormatter.tierCostWhole(summary.totals.costUSD, hasUnpricedUsage: summary.totals.hasUnpricedUsage))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                // 剩余状态由数字颜色表达：≥20% 石墨灰、<20% 橙、=0 红（统一走 statusColor）。
                Text("\(tr("Official", "官方")) \(String(format: "%.0f%%", usedPercent))")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(officialColor(remaining: 100 - usedPercent))
                    .lineLimit(1)
            }

            CycleProjectBar(segments: segments)
                .padding(.top, 2)

            HStack(spacing: 10) {
                ForEach(segments) { segment in
                    HStack(spacing: 4) {
                        CompositionSwatch(role: segment.role, size: 8)
                        Text(segment.name)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 14)

            Spacer(minLength: 0)

            ResetTimeText(resetsAt: summary.cycle.endAt)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }

    private func officialColor(remaining: Double) -> Color {
        statusColor(remainingPercent: remaining, tint: .primary)
    }

    /// 空态卡：标签行固定在顶部，下方提示内容在剩余空间垂直居中。
    private func cycleCardEmptyState(app: UsageApp, kind: QuotaLimitKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ServiceTile(app: app, size: 12)
                Text("\(app.displayName) · \(cycleKindShort(kind))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(hasAccount(app)
                     ? tr("Waiting for the current cycle", "等待当前周期")
                     : tr("Account not detected", "未检测到账号"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(hasAccount(app)
                 ? tr(
                    "A successful quota refresh will establish this reset cycle.",
                    "额度刷新成功后会建立该重置周期。"
                 )
                 : tr(
                    "Connect this service and refresh quota to start recording cycles.",
                    "连接该服务并刷新额度后开始记录周期。"
                 ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
    }

    // MARK: - 数据

    private func projectSegments(_ summary: CycleUsageSummary, usedPercent: Double) -> [CycleProjectSegment] {
        let usage = appState.usageService.cycleAggregator.usageByConversation(cycleID: summary.cycle.id)
        let conversations = appState.usageService.conversationAggregator
        return CycleProjectSplit.segments(
            usage: usage,
            usedPercent: usedPercent,
            identity: { conversations.statsProjectIdentity(forConversationKey: $0) },
            restName: tr("Other", "其他")
        )
    }

    private func currentSummary(
        app: UsageApp,
        kind: QuotaLimitKind
    ) -> CycleUsageSummary? {
        guard let accountKey = accountKey(for: app) else { return nil }
        return summaries(kind: kind, app: app)
            .filter { $0.cycle.isCurrent() && $0.cycle.accountKey == accountKey }
            .sorted { lhs, rhs in
                let lhsLastSample = lhs.cycle.lastSampleAt ?? .distantPast
                let rhsLastSample = rhs.cycle.lastSampleAt ?? .distantPast
                if lhsLastSample != rhsLastSample { return lhsLastSample > rhsLastSample }
                if lhs.cycle.boundaryQuality != rhs.cycle.boundaryQuality {
                    return lhs.cycle.boundaryQuality == .observed
                }
                return lhs.cycle.endAt > rhs.cycle.endAt
            }
            .first
    }

    private func summaries(
        kind: QuotaLimitKind,
        app: UsageApp?
    ) -> [CycleUsageSummary] {
        appState.usageService.cycleAggregator.summaries(
            cycles: appState.quotaCycles.records,
            kind: kind,
            app: app
        )
    }

    private func accountKey(for app: UsageApp) -> String? {
        switch app {
        case .codex:
            guard appState.codexAccount != nil else { return nil }
            return QuotaHistoryAccountKey.codexPrimary(accountId: appState.codexAccount?.accountId)
        case .claude:
            guard appState.claudeAccount != nil else { return nil }
            return QuotaHistoryAccountKey.claudePrimary(email: appState.claudeAccount?.email)
        case .cursor:
            return nil
        case .pi, .opencode:
            return nil
        case .dsh:
            // DSH 没有额度周期，额度页不出现该服务。
            return nil
        }
    }

    private func hasAccount(_ app: UsageApp) -> Bool {
        accountKey(for: app) != nil
    }
}

// MARK: - 周期按项目拆分

struct CycleProjectSegment: Identifiable, Equatable {
    let id: String
    let name: String
    let role: CompositionColorRole
    /// 占官方额度的估算百分比（0~100）。
    let percent: Double
    let tokens: Int
}

/// 周期进度条的项目估算（需求 §5）：
/// `项目占用 ≈ 该项目本周期 API 等值 ÷ 该服务本周期 API 等值合计 × 官方已用比例`。
/// 只用本机能归属到项目的用量；无明确项目、系统任务、旧版本没有对话信息的桶和第 3 名以后的项目并入「其他」。
/// 本周期没有本机用量但官方已用 > 0（例如在其他设备上使用）时，整段显示为「其他」。
/// 全部无价时按 Tokens 估算。各段之和恒等于官方已用比例。
enum CycleProjectSplit {
    static let namedLimit = 2

    static func segments(
        usage: [String?: UsageTotals],
        usedPercent: Double,
        identity: (String) -> StatsProjectIdentity?,
        restName: String
    ) -> [CycleProjectSegment] {
        let used = max(0, min(100, usedPercent))
        guard used > 0 else { return [] }

        var projects: [String: (identity: StatsProjectIdentity, totals: UsageTotals)] = [:]
        var total = UsageTotals.zero
        var restTokens = 0
        for (key, totals) in usage {
            total.add(totals)
            if let key, let project = identity(key), project.status.isPathBased {
                var entry = projects[project.key] ?? (identity: project, totals: UsageTotals.zero)
                entry.totals.add(totals)
                projects[project.key] = entry
            } else {
                restTokens += totals.totalTokens
            }
        }

        let useCost = total.costUSD > 0
        func weight(_ totals: UsageTotals) -> Double {
            useCost ? NSDecimalNumber(decimal: totals.costUSD).doubleValue : Double(totals.totalTokens)
        }
        let totalWeight = weight(total)
        guard totalWeight > 0 else {
            return [CycleProjectSegment(id: "rest", name: restName, role: .rest, percent: used, tokens: total.totalTokens)]
        }

        let ranked = projects.values
            .filter { weight($0.totals) > 0 }
            .sorted { lhs, rhs in
                let l = weight(lhs.totals)
                let r = weight(rhs.totals)
                return l == r ? lhs.identity.name < rhs.identity.name : l > r
            }
        var segments: [CycleProjectSegment] = []
        var namedPercent = 0.0
        for (index, entry) in ranked.prefix(namedLimit).enumerated() {
            let percent = used * weight(entry.totals) / totalWeight
            namedPercent += percent
            segments.append(CycleProjectSegment(
                id: entry.identity.key,
                name: entry.identity.name,
                role: .rank(index),
                percent: percent,
                tokens: entry.totals.totalTokens
            ))
        }
        let restPercent = max(0, used - namedPercent)
        if restPercent > 0.0001 {
            let otherTokens = restTokens + ranked.dropFirst(namedLimit).reduce(0) { $0 + $1.totals.totalTokens }
            segments.append(CycleProjectSegment(id: "rest", name: restName, role: .rest, percent: restPercent, tokens: otherTokens))
        }
        return segments
    }
}

/// 周期卡进度条：轨道底色 + 已用部分按项目分段，悬停分段显示项目名、估算比例与本周期 Tokens。
private struct CycleProjectBar: View {
    let segments: [CycleProjectSegment]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                HStack(spacing: 1) {
                    ForEach(segments) { segment in
                        CompositionFill(role: segment.role)
                            .frame(width: max(1, proxy.size.width * segment.percent / 100))
                            .help(tr(
                                "\(segment.name) · ≈\(String(format: "%.1f", segment.percent))% · \(StatsFormatter.compactToken(segment.tokens)) tokens this cycle",
                                "\(segment.name) · 约 \(String(format: "%.1f", segment.percent))% · 本周期 \(StatsFormatter.compactToken(segment.tokens)) Tokens"
                            ))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 6)
    }
}

// MARK: - 周期卡共享的纯函数

/// 周期类型短标签：5 小时 / 周，用于周期卡标签。
private func cycleKindShort(_ kind: QuotaLimitKind) -> String {
    switch kind {
    case .fiveHour: return tr("5-hour", "5 小时")
    case .weekly: return tr("Weekly", "周")
    default: return tr("Cycle", "周期")
    }
}

/// 周期卡主数字：用满预估 `Tokens · 费用`，无依据的一侧显示 `—`。
private func fullUseLine(_ summary: CycleUsageSummary) -> String {
    let tokens = summary.projectedFullCycleTokens
        .map { StatsFormatter.compactToken($0) } ?? "—"
    let cost = summary.projectedFullCycleCostUSD
        .map { StatsFormatter.tierCostWhole($0, hasUnpricedUsage: false) } ?? "—"
    return "\(tokens) · \(cost)"
}

private func forecastConfidenceText(_ confidence: CycleForecastConfidence) -> String {
    switch confidence {
    case .early: return tr("Early estimate", "早期估算")
    case .rough: return tr("Rough estimate", "粗略估算")
    case .reference: return tr("Reference", "参考")
    case .reliable: return tr("More reliable", "较可靠")
    }
}
