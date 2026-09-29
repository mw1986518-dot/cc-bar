import Foundation

/// 用于对账的用量向量：完整键 + 四类 Tokens + 请求数。金额刻意不参与相等门槛
/// （价格目录变化正是重算要处理的情况），也不做总量兜底（总量相等不能证明覆盖完整）。
nonisolated struct UsageVectorCounts: Sendable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var requestCount: Int

    static let zero = UsageVectorCounts(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        requestCount: 0
    )
}

nonisolated struct UsageVectorKey: Sendable, Hashable {
    var app: UsageApp
    var day: Date
    var model: String
    var speed: UsageSpeed
}

nonisolated struct ConversationVectorKey: Sendable, Hashable {
    var conversationKey: String
    var day: Date
    var model: String
    var speed: UsageSpeed
}

nonisolated struct CycleVectorKey: Sendable, Hashable {
    var cycleID: String
    var allowanceSegmentID: String?
    var app: UsageApp
    var model: String
    var speed: UsageSpeed
    var quality: CycleUsageQuality
}

/// 候选与基准的差异摘要。只保留数量级信息，不含路径、标题或任何正文。
nonisolated struct UsageRebuildMismatch: Sendable, Equatable {
    var usageKeysBaseline = 0
    var usageKeysCandidate = 0
    var usageKeysMissing = 0
    var usageKeysAdded = 0
    var usageKeysChanged = 0
    var conversationKeysBaseline = 0
    var conversationKeysCandidate = 0
    var conversationKeysMissing = 0
    var conversationKeysAdded = 0
    var conversationKeysChanged = 0
    var conversationsRemoved = 0
    var conversationsAdded = 0
    var conversationAttributionChanged = 0
    var cycleKeysBaseline = 0
    var cycleKeysCandidate = 0
    var cycleKeysMissing = 0
    var cycleKeysAdded = 0
    var cycleKeysChanged = 0

    var hasUsageDifference: Bool {
        usageKeysMissing > 0 || usageKeysAdded > 0 || usageKeysChanged > 0
            || conversationKeysMissing > 0 || conversationKeysAdded > 0 || conversationKeysChanged > 0
            || conversationsRemoved > 0 || conversationsAdded > 0 || conversationAttributionChanged > 0
    }

    var hasCycleDifference: Bool {
        cycleKeysMissing > 0 || cycleKeysAdded > 0 || cycleKeysChanged > 0
    }

    /// 脱敏摘要，写日志与 UI 提示用。
    var summary: String {
        var parts: [String] = []
        if usageKeysMissing > 0 { parts.append("day_keys_missing=\(usageKeysMissing)") }
        if usageKeysAdded > 0 { parts.append("day_keys_added=\(usageKeysAdded)") }
        if usageKeysChanged > 0 { parts.append("day_keys_changed=\(usageKeysChanged)") }
        if conversationKeysMissing > 0 { parts.append("conversation_keys_missing=\(conversationKeysMissing)") }
        if conversationKeysAdded > 0 { parts.append("conversation_keys_added=\(conversationKeysAdded)") }
        if conversationKeysChanged > 0 { parts.append("conversation_keys_changed=\(conversationKeysChanged)") }
        if conversationsRemoved > 0 { parts.append("conversations_removed=\(conversationsRemoved)") }
        if conversationsAdded > 0 { parts.append("conversations_added=\(conversationsAdded)") }
        if conversationAttributionChanged > 0 {
            parts.append("conversation_attribution_changed=\(conversationAttributionChanged)")
        }
        if cycleKeysMissing > 0 { parts.append("cycle_keys_missing=\(cycleKeysMissing)") }
        if cycleKeysAdded > 0 { parts.append("cycle_keys_added=\(cycleKeysAdded)") }
        if cycleKeysChanged > 0 { parts.append("cycle_keys_changed=\(cycleKeysChanged)") }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }
}

/// 重算对账。首版门槛只有一种通过方式：候选的完整用量向量与基准逐一相等。
/// 不接受「总量不减少」「键集合是超集」「没有报错」这类弱证明。
nonisolated enum UsageHistoryConsistency {
    nonisolated static func dayVector(_ buckets: [UsageBucket]) -> [UsageVectorKey: UsageVectorCounts] {
        var result: [UsageVectorKey: UsageVectorCounts] = [:]
        for bucket in buckets where bucket.app != .cursor {
            let key = UsageVectorKey(
                app: bucket.app,
                day: bucket.day,
                model: bucket.model,
                speed: bucket.speed
            )
            var counts = result[key] ?? .zero
            counts.inputTokens += bucket.inputTokens
            counts.outputTokens += bucket.outputTokens
            counts.cacheReadTokens += bucket.cacheReadTokens
            counts.cacheCreationTokens += bucket.cacheCreationTokens
            counts.requestCount += bucket.requestCount
            result[key] = counts
        }
        return result
    }

    nonisolated static func conversationVector(
        _ buckets: [ConversationUsageBucket]
    ) -> [ConversationVectorKey: UsageVectorCounts] {
        var result: [ConversationVectorKey: UsageVectorCounts] = [:]
        for bucket in buckets where bucket.app != .cursor {
            let key = ConversationVectorKey(
                conversationKey: bucket.conversationKey,
                day: bucket.day,
                model: bucket.model,
                speed: bucket.speed
            )
            var counts = result[key] ?? .zero
            counts.inputTokens += bucket.inputTokens
            counts.outputTokens += bucket.outputTokens
            counts.cacheReadTokens += bucket.cacheReadTokens
            counts.cacheCreationTokens += bucket.cacheCreationTokens
            counts.requestCount += bucket.requestCount
            result[key] = counts
        }
        return result
    }

    nonisolated static func cycleVector(
        _ buckets: [CycleUsageBucket]
    ) -> [CycleVectorKey: UsageVectorCounts] {
        var result: [CycleVectorKey: UsageVectorCounts] = [:]
        for bucket in buckets {
            let key = CycleVectorKey(
                cycleID: bucket.cycleID,
                allowanceSegmentID: bucket.allowanceSegmentID,
                app: bucket.app,
                model: bucket.model,
                speed: bucket.speed,
                quality: bucket.quality
            )
            var counts = result[key] ?? .zero
            counts.inputTokens += bucket.inputTokens
            counts.outputTokens += bucket.outputTokens
            counts.cacheReadTokens += bucket.cacheReadTokens
            counts.cacheCreationTokens += bucket.cacheCreationTokens
            counts.requestCount += bucket.requestCount
            result[key] = counts
        }
        return result
    }

    nonisolated static func compare<V: Hashable>(
        baseline: [V: UsageVectorCounts],
        candidate: [V: UsageVectorCounts],
        into mismatch: inout UsageRebuildMismatch,
        missing: WritableKeyPath<UsageRebuildMismatch, Int>,
        added: WritableKeyPath<UsageRebuildMismatch, Int>,
        changed: WritableKeyPath<UsageRebuildMismatch, Int>
    ) {
        mismatch[keyPath: missing] = baseline.keys.filter { candidate[$0] == nil }.count
        mismatch[keyPath: added] = candidate.keys.filter { baseline[$0] == nil }.count
        mismatch[keyPath: changed] = baseline.reduce(into: 0) { count, pair in
            guard let candidateCounts = candidate[pair.key], candidateCounts != pair.value else { return }
            count += 1
        }
    }

    /// 用量对账：日桶 + 对话桶 + 会话归属。基准里没有的投影（例如对话历史在迁移时被丢弃）
    /// 不纳入比较，但必须由 `degradeReasons` 说明。
    nonisolated static func compareUsage(
        baseline: [UsageBucket],
        candidateDay: [UsageBucket],
        baselineConversation: [ConversationUsageBucket],
        candidateConversation: [ConversationUsageBucket],
        baselineInfos: [ConversationInfo],
        candidateInfos: [ConversationInfo]
    ) -> UsageRebuildMismatch {
        var mismatch = UsageRebuildMismatch()
        let baselineDay = dayVector(baseline)
        let candidateDayVector = dayVector(candidateDay)
        mismatch.usageKeysBaseline = baselineDay.count
        mismatch.usageKeysCandidate = candidateDayVector.count
        if !baselineDay.isEmpty {
            compare(
                baseline: baselineDay,
                candidate: candidateDayVector,
                into: &mismatch,
                missing: \.usageKeysMissing,
                added: \.usageKeysAdded,
                changed: \.usageKeysChanged
            )
        }

        if !baselineConversation.isEmpty || !baselineInfos.isEmpty {
            let baselineVector = conversationVector(baselineConversation)
            let candidateVector = conversationVector(candidateConversation)
            mismatch.conversationKeysBaseline = baselineVector.count
            mismatch.conversationKeysCandidate = candidateVector.count
            compare(
                baseline: baselineVector,
                candidate: candidateVector,
                into: &mismatch,
                missing: \.conversationKeysMissing,
                added: \.conversationKeysAdded,
                changed: \.conversationKeysChanged
            )

            // 会话归属：键集合与 app / 项目归组必须一致，标题之类的展示字段不参与。
            let baselineKeys = Set(baselineInfos.map(\.key))
            let candidateKeys = Set(candidateInfos.map(\.key))
            mismatch.conversationsRemoved = baselineKeys.subtracting(candidateKeys).count
            mismatch.conversationsAdded = candidateKeys.subtracting(baselineKeys).count
            var baselineByKey: [String: ConversationInfo] = [:]
            for info in baselineInfos { baselineByKey[info.key] = info }
            mismatch.conversationAttributionChanged = candidateInfos.reduce(into: 0) { count, info in
                guard let old = baselineByKey[info.key] else { return }
                if old.app != info.app || old.projectKey != info.projectKey { count += 1 }
            }
        }
        return mismatch
    }

    /// 周期对账。上下文变化时调用方按已有规则独立处理，不在这里放宽。
    nonisolated static func compareCycle(
        baseline: [CycleUsageBucket],
        candidate: [CycleUsageBucket],
        into mismatch: inout UsageRebuildMismatch
    ) {
        let baselineVector = cycleVector(baseline)
        let candidateVector = cycleVector(candidate)
        mismatch.cycleKeysBaseline = baselineVector.count
        mismatch.cycleKeysCandidate = candidateVector.count
        compare(
            baseline: baselineVector,
            candidate: candidateVector,
            into: &mismatch,
            missing: \.cycleKeysMissing,
            added: \.cycleKeysAdded,
            changed: \.cycleKeysChanged
        )
    }
}

/// 一次运行的结果状态。UI 与日志据此区分「成功」「保留旧历史的拒绝」「提交失败」「恢复受限」，
/// 不靠字符串前缀判断。
nonisolated enum UsageRebuildOutcome: Sendable, Equatable {
    /// 用量向量与基准一致，新费用已提交。
    case replaced(cycleVerified: Bool)
    /// 数据发生变化或覆盖无法确认，原历史原样保留。
    case rejectedUsageChanged
    /// 来源读取 / 解码不完整或 DSH 冲突，本轮不作为。
    case rejectedIncompleteSources(String)
    /// 候选持久化失败，基准仍未改变。
    case commitFailed(String)
    /// 第一轮已经提交，缺价第二轮被拒 / 失败：保留第一轮有效结果，不宣称整轮完整成功。
    case partiallyCommitted(String)
    /// 受限恢复的一次核对：向量一致，已据此采纳进度。
    case recoveredFromRestrictedHistory
    /// 受限恢复的核对无法确认，保留历史、停止自动全量重扫。
    case restrictedRecoveryRejected
}

/// 受限恢复（历史可用但没有可信进度）的状态。
nonisolated enum UsageHistoryRecoveryState: Sendable, Equatable {
    /// 正常：历史与进度同代。
    case complete
    /// 历史可用但进度不可信；尚未做核对。
    case pendingVerification
    /// 核对未通过：保留历史展示，不再自动全量重扫。
    case verificationRejected
    /// 没有可展示的有效历史，不能自动当成首装。
    case unavailable
}

/// 仅供 Codex 标识迁移使用；普通重算仍按原始完整模型键严格对账。
/// 金额和时间范围也按旧键比较，不能用全局总额相等替代逐桶守恒。
nonisolated extension UsageHistoryConsistency {
    struct MigrationBalance: Equatable {
        var cost: Decimal = 0
        var input: Decimal = 0
        var output: Decimal = 0
        var read: Decimal = 0
        var creation: Decimal = 0
        var unpriced = false
        var incomplete = false
        var firstAt: Date?
        var lastAt: Date?
    }

    struct MigrationCycleKey: Hashable {
        var key: CycleVectorKey
        var conversationKey: String?
    }

    static func migrationDayBalances(_ buckets: [UsageBucket]) -> [UsageVectorKey: MigrationBalance] {
        var result: [UsageVectorKey: MigrationBalance] = [:]
        for b in buckets {
            let key = UsageVectorKey(app: b.app, day: b.day, model: b.model, speed: b.speed)
            var balance = result[key] ?? MigrationBalance()
            balance.cost += b.costUSD
            balance.unpriced = balance.unpriced || b.hasUnpricedUsage
            balance.incomplete = balance.incomplete || b.costIncomplete
            result[key] = balance
        }
        return result
    }

    private static func migrationConversationBalances(
        _ buckets: [ConversationUsageBucket]
    ) -> [ConversationVectorKey: MigrationBalance] {
        var result: [ConversationVectorKey: MigrationBalance] = [:]
        for b in buckets {
            let key = ConversationVectorKey(conversationKey: b.conversationKey, day: b.day, model: b.model, speed: b.speed)
            var balance = result[key] ?? MigrationBalance()
            balance.cost += b.costUSD
            balance.input += b.inputCostUSD
            balance.output += b.outputCostUSD
            balance.read += b.cacheReadCostUSD
            balance.creation += b.cacheCreationCostUSD
            balance.unpriced = balance.unpriced || b.hasUnpricedUsage
            balance.firstAt = min(balance.firstAt ?? b.firstAt, b.firstAt)
            balance.lastAt = max(balance.lastAt ?? b.lastAt, b.lastAt)
            result[key] = balance
        }
        return result
    }

    private static func migrationCycleVectors(
        _ buckets: [CycleUsageBucket]
    ) -> [MigrationCycleKey: UsageVectorCounts] {
        var result: [MigrationCycleKey: UsageVectorCounts] = [:]
        for b in buckets {
            let key = migrationCycleKey(b)
            var counts = result[key] ?? .zero
            counts.inputTokens += b.inputTokens
            counts.outputTokens += b.outputTokens
            counts.cacheReadTokens += b.cacheReadTokens
            counts.cacheCreationTokens += b.cacheCreationTokens
            counts.requestCount += b.requestCount
            result[key] = counts
        }
        return result
    }

    private static func migrationCycleKey(_ b: CycleUsageBucket) -> MigrationCycleKey {
        MigrationCycleKey(key: CycleVectorKey(cycleID: b.cycleID, allowanceSegmentID: b.allowanceSegmentID,
                                              app: b.app, model: b.model, speed: b.speed, quality: b.quality),
                          conversationKey: b.conversationKey)
    }

    private static func migrationCycleBalances(_ buckets: [CycleUsageBucket]) -> [MigrationCycleKey: MigrationBalance] {
        var result: [MigrationCycleKey: MigrationBalance] = [:]
        for b in buckets {
            let key = migrationCycleKey(b)
            var balance = result[key] ?? MigrationBalance()
            balance.cost += b.costUSD
            balance.unpriced = balance.unpriced || b.hasUnpricedUsage
            result[key] = balance
        }
        return result
    }

    /// origins 仅由迁移器根据原始调用产生，不能由裸模型名推测。
    static func validateCodexIdentityMigration(
        baseline: UsageSnapshot, candidate: UsageSnapshot, origins: [String: String]
    ) -> Bool {
        guard origins.allSatisfy({ Pricing.normalize(model: $0.key) == $0.value }),
              baseline.scanState == candidate.scanState,
              baseline.conversationRollup.infos == candidate.conversationRollup.infos,
              baseline.usageRollup.buckets.filter({ $0.app != .codex }) == candidate.usageRollup.buckets.filter({ $0.app != .codex }),
              baseline.conversationRollup.buckets.filter({ $0.app != .codex }) == candidate.conversationRollup.buckets.filter({ $0.app != .codex }),
              baseline.cycleRollup.buckets.filter({ $0.app != .codex }) == candidate.cycleRollup.buckets.filter({ $0.app != .codex })
        else { return false }
        let day = candidate.usageRollup.buckets.map { bucket -> UsageBucket in
            var b = bucket
            if b.app == .codex { b.model = origins[b.model] ?? b.model }
            return b
        }
        let conversation = candidate.conversationRollup.buckets.map { bucket -> ConversationUsageBucket in
            var b = bucket
            if b.app == .codex { b.model = origins[b.model] ?? b.model }
            return b
        }
        let cycle = candidate.cycleRollup.buckets.map { bucket -> CycleUsageBucket in
            var b = bucket
            if b.app == .codex { b.model = origins[b.model] ?? b.model }
            return b
        }
        return dayVector(baseline.usageRollup.buckets) == dayVector(day)
            && conversationVector(baseline.conversationRollup.buckets) == conversationVector(conversation)
            && migrationCycleVectors(baseline.cycleRollup.buckets) == migrationCycleVectors(cycle)
            && migrationDayBalances(baseline.usageRollup.buckets) == migrationDayBalances(day)
            && migrationConversationBalances(baseline.conversationRollup.buckets) == migrationConversationBalances(conversation)
            && migrationCycleBalances(baseline.cycleRollup.buckets) == migrationCycleBalances(cycle)
    }
}
