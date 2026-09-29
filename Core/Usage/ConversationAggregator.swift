import Foundation
import Observation

/// 与现有按日聚合并行的对话聚合器；列表按范围查询，详情始终聚合完整生命周期。
@MainActor
@Observable
final class ConversationAggregator {
    private var infos: [String: ConversationInfo] = [:]
    private var buckets: [BucketKey: ConversationUsageBucket] = [:]
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private var cachedQuery: (request: ConversationQueryRequest, result: ConversationQueryResult)?
    @ObservationIgnored private var cachedDetail: (revision: UInt64, key: String, detail: ConversationDetail)?
    @ObservationIgnored private var cachedOverview: (request: ConversationOverviewRequest, result: ConversationOverviewResult)?
    @ObservationIgnored private var cachedProjectDetail: (request: ProjectDetailRequest, detail: ProjectDetail?)?
    /// worktree → 主仓库的只读识别，按路径缓存；只影响统计口径，不改写已保存的项目身份。
    @ObservationIgnored private let worktreeResolver: ProjectWorktreeResolver
    @ObservationIgnored private var identityCache: [IdentityCacheKey: ResolvedIdentity] = [:]

    private struct BucketKey: Hashable {
        let conversationKey: String
        let day: Date
        let model: String
        let speed: UsageSpeed
    }

    private struct ProjectAccumulator {
        var identity: StatsProjectIdentity
        var conversationCount: Int
        var lastAt: Date
    }

    private struct IdentityCacheKey: Hashable {
        let projectKey: String
        let status: ConversationProjectStatus
    }

    private struct ResolvedIdentity {
        let identity: StatsProjectIdentity
        /// 非 nil 表示该对话的项目路径是一个 worktree。
        let worktree: ProjectWorktreeLink?
    }

    init(worktreeResolver: ProjectWorktreeResolver = ProjectWorktreeResolver()) {
        self.worktreeResolver = worktreeResolver
    }

    var isEmpty: Bool { buckets.isEmpty }

    func load(infos: [ConversationInfo], buckets: [ConversationUsageBucket]) {
        self.infos = Dictionary(uniqueKeysWithValues: infos.map { ($0.key, $0) })
        self.buckets = Dictionary(uniqueKeysWithValues: buckets.map {
            (BucketKey(conversationKey: $0.conversationKey, day: $0.day, model: $0.model, speed: $0.speed), $0)
        })
        markChanged()
    }

    @discardableResult
    func ingest(entries: [UsageEntry], seeds: [ConversationSeed]) -> Bool {
        var changed = false
        var conversationKeysWithUsage = Set(buckets.keys.map(\.conversationKey))
        conversationKeysWithUsage.formUnion(entries.map(\.conversationKey))
        for seed in seeds where conversationKeysWithUsage.contains(seed.key) {
            changed = merge(seed: seed) || changed
        }

        for entry in entries {
            changed = true
            let key = BucketKey(
                conversationKey: entry.conversationKey,
                day: entry.day,
                model: entry.model,
                speed: entry.speed
            )
            let breakdown = entry.costBreakdown
            if var bucket = buckets[key] {
                bucket.inputTokens += entry.inputTokens
                bucket.outputTokens += entry.outputTokens
                bucket.cacheReadTokens += entry.cacheReadTokens
                bucket.cacheCreationTokens += entry.cacheCreationTokens
                bucket.requestCount += entry.requestCount
                bucket.firstAt = min(bucket.firstAt, entry.timestamp)
                bucket.lastAt = max(bucket.lastAt, entry.timestamp)
                bucket.costUSD += breakdown?.total ?? 0
                bucket.inputCostUSD += breakdown?.input ?? 0
                bucket.outputCostUSD += breakdown?.output ?? 0
                bucket.cacheReadCostUSD += breakdown?.cacheRead ?? 0
                bucket.cacheCreationCostUSD += breakdown?.cacheCreation ?? 0
                bucket.hasUnpricedUsage = bucket.hasUnpricedUsage || breakdown == nil
                buckets[key] = bucket
            } else {
                buckets[key] = ConversationUsageBucket(
                    conversationKey: entry.conversationKey,
                    app: entry.app,
                    day: entry.day,
                    model: entry.model,
                    speed: entry.speed,
                    firstAt: entry.timestamp,
                    lastAt: entry.timestamp,
                    inputTokens: entry.inputTokens,
                    outputTokens: entry.outputTokens,
                    cacheReadTokens: entry.cacheReadTokens,
                    cacheCreationTokens: entry.cacheCreationTokens,
                    requestCount: entry.requestCount,
                    costUSD: breakdown?.total ?? 0,
                    inputCostUSD: breakdown?.input ?? 0,
                    outputCostUSD: breakdown?.output ?? 0,
                    cacheReadCostUSD: breakdown?.cacheRead ?? 0,
                    cacheCreationCostUSD: breakdown?.cacheCreation ?? 0,
                    hasUnpricedUsage: breakdown == nil
                )
            }

            if var info = infos[entry.conversationKey] {
                info.firstAt = min(info.firstAt, entry.timestamp)
                info.lastAt = max(info.lastAt, entry.timestamp)
                infos[entry.conversationKey] = info
            }
        }

        conversationKeysWithUsage = Set(buckets.keys.map(\.conversationKey))
        for key in Array(infos.keys) where !conversationKeysWithUsage.contains(key) {
            infos.removeValue(forKey: key)
            changed = true
        }

        if changed { markChanged() }
        return changed
    }

    /// 用完整重算过的结果替换同一 app 的对话档案与对话桶，其他 app 的分区原样保留。
    ///
    /// DSH 的对话视图每次都从逐会话贡献重新归根（草案 §3.3、§4.1），走这里而不是
    /// `ingest(entries:seeds:)`——父文件后到、父链改变、generation 切换都会改变归根结果，
    /// 增量合并无法把已经记错 key 的历史迁走。
    @discardableResult
    func replaceLocal(
        app: UsageApp,
        infos newInfos: [ConversationInfo],
        buckets newBuckets: [ConversationUsageBucket]
    ) -> Bool {
        var keptInfos = infos.filter { $0.value.app != app }
        var keptBuckets = buckets.filter { $0.value.app != app }
        var changed = keptInfos.count != infos.count || keptBuckets.count != buckets.count

        for info in newInfos where info.app == app {
            if keptInfos[info.key] != info { changed = true }
            keptInfos[info.key] = info
        }
        for bucket in newBuckets where bucket.app == app {
            let key = BucketKey(
                conversationKey: bucket.conversationKey,
                day: bucket.day,
                model: bucket.model,
                speed: bucket.speed
            )
            if keptBuckets[key] != bucket { changed = true }
            keptBuckets[key] = bucket
        }

        infos = keptInfos
        buckets = keptBuckets
        if changed { markChanged() }
        return changed
    }

    func snapshot() -> (infos: [ConversationInfo], buckets: [ConversationUsageBucket]) {
        (Array(infos.values), Array(buckets.values))
    }

    func query(_ rawRequest: ConversationQueryRequest) -> ConversationQueryResult {
        var request = rawRequest
        request.revision = revision
        request.search = request.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cachedQuery, cachedQuery.request == request { return cachedQuery.result }

        var grouped: [String: [ConversationUsageBucket]] = [:]
        for bucket in buckets.values where bucket.day >= request.from && bucket.day < request.to {
            if let app = request.app, bucket.app != app { continue }
            grouped[bucket.conversationKey, default: []].append(bucket)
        }

        var allSummaries: [ConversationSummary] = []
        var projects: [String: ProjectAccumulator] = [:]
        allSummaries.reserveCapacity(grouped.count)
        for (key, values) in grouped {
            guard let info = infos[key] else { continue }
            let item = aggregate(values)
            var rangeLastAt = Date.distantPast
            var modelNames: Set<String> = []
            for value in values {
                rangeLastAt = max(rangeLastAt, value.lastAt)
                modelNames.insert(value.model)
            }
            let summary = ConversationSummary(
                info: info,
                totals: item.totals,
                costs: item.costs,
                speed: item.speed,
                models: modelNames.sorted(),
                rangeLastAt: rangeLastAt
            )
            allSummaries.append(summary)
            let identity = resolvedIdentity(for: info).identity
            if var project = projects[identity.key] {
                project.conversationCount += 1
                project.lastAt = max(project.lastAt, rangeLastAt)
                projects[identity.key] = project
            } else {
                projects[identity.key] = ProjectAccumulator(
                    identity: identity,
                    conversationCount: 1,
                    lastAt: rangeLastAt
                )
            }
        }

        let projectOptions = projects.values.map {
            ConversationProjectOption(
                key: $0.identity.key,
                name: $0.identity.name,
                path: $0.identity.path,
                status: $0.identity.status,
                conversationCount: $0.conversationCount,
                lastAt: $0.lastAt
            )
        }
        let duplicateNames = Dictionary(grouping: projectOptions.filter {
            $0.status.isPathBased
        }, by: \.name)
            .compactMap { $0.value.count > 1 ? $0.key : nil }

        var rows = allSummaries.filter { summary in
            if let projectKey = request.projectKey,
               resolvedIdentity(for: summary.info).identity.key != projectKey { return false }
            if !request.search.isEmpty {
                let info = summary.info
                let haystack = [info.title ?? "", info.projectName, info.projectPath, info.conversationID]
                    .joined(separator: " ").lowercased()
                if !haystack.contains(request.search) { return false }
            }
            return true
        }
        rows.sort { lhs, rhs in
            switch request.sort {
            case .recent: return lhs.rangeLastAt > rhs.rangeLastAt
            case .tokens:
                return lhs.totals.totalTokens == rhs.totals.totalTokens
                    ? lhs.rangeLastAt > rhs.rangeLastAt
                    : lhs.totals.totalTokens > rhs.totals.totalTokens
            case .cost:
                return lhs.costs.total == rhs.costs.total
                    ? lhs.rangeLastAt > rhs.rangeLastAt
                    : lhs.costs.total > rhs.costs.total
            }
        }
        let result = ConversationQueryResult(
            rows: rows,
            projectOptions: projectOptions,
            projectConversationCount: allSummaries.count,
            projectKeys: Set(projectOptions.map(\.key)),
            duplicateProjectNames: Set(duplicateNames)
        )
        cachedQuery = (request, result)
        return result
    }

    /// 概览「用量构成 · 项目」「高消耗对话」与项目列表共用的汇总。范围内的桶只遍历一次。
    /// 缺对话档案的桶不计入任何项目，由调用方算进「未归属」残差。
    func overviewBreakdown(_ rawRequest: ConversationOverviewRequest) -> ConversationOverviewResult {
        var request = rawRequest
        request.revision = revision
        if let cachedOverview, cachedOverview.request == request { return cachedOverview.result }

        struct ProjectBuilder {
            var identity: StatsProjectIdentity
            var totals = UsageTotals.zero
            var speed = UsageSpeedBreakdown()
            var byApp: [UsageApp: UsageTotals] = [:]
            var conversationCount = 0
            var lastAt = Date.distantPast
            var worktrees: Set<String> = []
        }

        var grouped: [String: [ConversationUsageBucket]] = [:]
        var attributedByDayApp: [UsageDayAppKey: UsageTotals] = [:]
        for bucket in buckets.values where bucket.day >= request.from && bucket.day < request.to {
            guard request.apps.contains(bucket.app), infos[bucket.conversationKey] != nil else { continue }
            grouped[bucket.conversationKey, default: []].append(bucket)
            attributedByDayApp[UsageDayAppKey(day: bucket.day, app: bucket.app), default: .zero]
                .add(Self.totals(of: bucket))
        }

        var projects: [String: ProjectBuilder] = [:]
        var attributedByApp: [UsageApp: UsageTotals] = [:]
        var conversations: [TopConversationRow] = []
        conversations.reserveCapacity(grouped.count)
        for (key, values) in grouped {
            guard let info = infos[key] else { continue }
            let item = aggregate(values)
            var rangeLastAt = Date.distantPast
            var modelNames: Set<String> = []
            for value in values {
                rangeLastAt = max(rangeLastAt, value.lastAt)
                modelNames.insert(value.model)
            }
            let resolved = resolvedIdentity(for: info)
            var project = projects[resolved.identity.key] ?? ProjectBuilder(identity: resolved.identity)
            project.totals.add(item.totals)
            project.speed.merge(item.speed)
            project.byApp[info.app, default: .zero].add(item.totals)
            project.conversationCount += 1
            project.lastAt = max(project.lastAt, rangeLastAt)
            if resolved.worktree != nil { project.worktrees.insert(info.projectPath) }
            projects[resolved.identity.key] = project
            attributedByApp[info.app, default: .zero].add(item.totals)
            conversations.append(TopConversationRow(
                summary: ConversationSummary(
                    info: info,
                    totals: item.totals,
                    costs: item.costs,
                    speed: item.speed,
                    models: modelNames.sorted(),
                    rangeLastAt: rangeLastAt
                ),
                project: resolved.identity
            ))
        }

        let rows = projects.values.map {
            ProjectUsageRow(
                key: $0.identity.key,
                name: $0.identity.name,
                path: $0.identity.path,
                status: $0.identity.status,
                totals: $0.totals,
                speed: $0.speed,
                totalsByApp: $0.byApp,
                conversationCount: $0.conversationCount,
                lastAt: $0.lastAt,
                worktreeCount: $0.worktrees.count
            )
        }
        .sorted(by: Self.projectOrder)

        conversations.sort { lhs, rhs in
            if lhs.summary.costs.total == rhs.summary.costs.total {
                return lhs.summary.rangeLastAt > rhs.summary.rangeLastAt
            }
            return lhs.summary.costs.total > rhs.summary.costs.total
        }
        let result = ConversationOverviewResult(
            projects: rows,
            attributedByApp: attributedByApp,
            attributedByDayApp: attributedByDayApp,
            topConversations: Array(conversations.prefix(max(0, request.topConversationLimit)))
        )
        cachedOverview = (request, result)
        return result
    }

    /// 项目页右侧详情：所选范围的明细 + 全部时间合计。服务过滤与列表一致。
    func projectDetail(_ rawRequest: ProjectDetailRequest) -> ProjectDetail? {
        var request = rawRequest
        request.revision = revision
        if let cachedProjectDetail, cachedProjectDetail.request == request { return cachedProjectDetail.detail }

        var identity: StatsProjectIdentity?
        var totals = UsageTotals.zero
        var previousTotals = UsageTotals.zero
        var allTime = UsageTotals.zero
        var firstDay: Date?
        var daily: [UsageDayAppKey: UsageTotals] = [:]
        var byApp: [UsageApp: UsageTotals] = [:]
        var models: [String: ProjectModelUsage] = [:]
        var activeDays: Set<Date> = []
        var inRange: [String: [ConversationUsageBucket]] = [:]
        var worktreeLinks: [String: ProjectWorktreeLink?] = [:]

        for bucket in buckets.values where request.apps.contains(bucket.app) {
            guard let info = infos[bucket.conversationKey] else { continue }
            let resolved = resolvedIdentity(for: info)
            guard resolved.identity.key == request.projectKey else { continue }
            identity = identity ?? resolved.identity
            let bucketTotals = Self.totals(of: bucket)
            allTime.add(bucketTotals)
            firstDay = min(firstDay ?? bucket.day, bucket.day)
            if let previous = request.previous, previous.contains(bucket.day) {
                previousTotals.add(bucketTotals)
            }
            guard bucket.day >= request.from && bucket.day < request.to else { continue }
            totals.add(bucketTotals)
            daily[UsageDayAppKey(day: bucket.day, app: bucket.app), default: .zero].add(bucketTotals)
            byApp[bucket.app, default: .zero].add(bucketTotals)
            var model = models[bucket.model] ?? ProjectModelUsage(model: bucket.model, apps: [], totals: .zero)
            model.apps.insert(bucket.app)
            model.totals.add(bucketTotals)
            models[bucket.model] = model
            activeDays.insert(bucket.day)
            inRange[bucket.conversationKey, default: []].append(bucket)
            if worktreeLinks[info.projectPath] == nil {
                worktreeLinks[info.projectPath] = .some(resolved.worktree)
            }
        }

        guard let identity else {
            cachedProjectDetail = (request, nil)
            return nil
        }

        var branches: [String: ProjectBranchUsage] = [:]
        var worktreeTotals: [String: UsageTotals] = [:]
        var conversations: [TopConversationRow] = []
        for (key, values) in inRange {
            guard let info = infos[key] else { continue }
            let item = aggregate(values)
            var rangeLastAt = Date.distantPast
            var modelNames: Set<String> = []
            for value in values {
                rangeLastAt = max(rangeLastAt, value.lastAt)
                modelNames.insert(value.model)
            }
            let branch = info.gitBranch.flatMap { $0.isEmpty ? nil : $0 }
            var branchUsage = branches[branch ?? ""] ?? ProjectBranchUsage(branch: branch, conversationCount: 0, totals: .zero)
            branchUsage.conversationCount += 1
            branchUsage.totals.add(item.totals)
            branches[branch ?? ""] = branchUsage
            worktreeTotals[info.projectPath, default: .zero].add(item.totals)
            conversations.append(TopConversationRow(
                summary: ConversationSummary(
                    info: info,
                    totals: item.totals,
                    costs: item.costs,
                    speed: item.speed,
                    models: modelNames.sorted(),
                    rangeLastAt: rangeLastAt
                ),
                project: identity
            ))
        }
        conversations.sort { lhs, rhs in
            if lhs.summary.costs.total == rhs.summary.costs.total {
                return lhs.summary.rangeLastAt > rhs.summary.rangeLastAt
            }
            return lhs.summary.costs.total > rhs.summary.costs.total
        }

        var worktrees: [ProjectWorktreeUsage] = []
        if worktreeLinks.values.contains(where: { $0 != nil }) {
            var mainTotals = UsageTotals.zero
            for (path, link) in worktreeLinks {
                let pathTotals = worktreeTotals[path] ?? .zero
                if let link {
                    worktrees.append(ProjectWorktreeUsage(path: path, branch: link.branch, isMain: false, totals: pathTotals))
                } else {
                    mainTotals.add(pathTotals)
                }
            }
            worktrees.sort { lhs, rhs in
                lhs.totals.costUSD == rhs.totals.costUSD ? lhs.path < rhs.path : lhs.totals.costUSD > rhs.totals.costUSD
            }
            worktrees.insert(ProjectWorktreeUsage(
                path: identity.path,
                branch: worktreeResolver.currentBranch(ofRepository: identity.path),
                isMain: true,
                totals: mainTotals
            ), at: 0)
        }

        let detail = ProjectDetail(
            project: identity,
            totals: totals,
            previousTotals: request.previous == nil ? nil : previousTotals,
            conversationCount: inRange.count,
            activeDays: activeDays.count,
            dailyByApp: daily,
            totalsByApp: byApp,
            models: models.values.sorted { lhs, rhs in
                lhs.totals.costUSD == rhs.totals.costUSD ? lhs.model < rhs.model : lhs.totals.costUSD > rhs.totals.costUSD
            },
            branches: branches.values.sorted { lhs, rhs in
                if (lhs.branch == nil) != (rhs.branch == nil) { return lhs.branch != nil }
                if lhs.totals.costUSD == rhs.totals.costUSD { return (lhs.branch ?? "") < (rhs.branch ?? "") }
                return lhs.totals.costUSD > rhs.totals.costUSD
            },
            topConversations: conversations,
            worktrees: worktrees,
            allTimeTotals: allTime,
            firstUsedDay: firstDay
        )
        cachedProjectDetail = (request, detail)
        return detail
    }

    /// 对话在统计页里的项目身份（worktree 折算到主仓库）。对话页的项目菜单与筛选也用它。
    func statsProjectIdentity(for info: ConversationInfo) -> StatsProjectIdentity {
        resolvedIdentity(for: info).identity
    }

    /// 该路径下是否为 Git 仓库；受保护路径返回 nil（未检查）。
    func isGitRepository(_ path: String) -> Bool? {
        worktreeResolver.isGitRepository(path)
    }

    /// 周期拆分用：对话 key → 统计页项目身份；缺档案时返回 nil。
    func statsProjectIdentity(forConversationKey key: String) -> StatsProjectIdentity? {
        infos[key].map { resolvedIdentity(for: $0).identity }
    }

    /// 项目排序：API 等值降序，同值按名称；无明确项目与系统任务固定在最后。
    nonisolated static func projectOrder(_ lhs: ProjectUsageRow, _ rhs: ProjectUsageRow) -> Bool {
        if lhs.isSpecial != rhs.isSpecial { return !lhs.isSpecial }
        if lhs.totals.costUSD == rhs.totals.costUSD {
            if lhs.name == rhs.name { return lhs.key < rhs.key }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return lhs.totals.costUSD > rhs.totals.costUSD
    }

    private func resolvedIdentity(for info: ConversationInfo) -> ResolvedIdentity {
        let cacheKey = IdentityCacheKey(projectKey: info.projectKey, status: info.projectStatus)
        if let cached = identityCache[cacheKey] { return cached }
        let base = StatsProjectIdentity(
            key: info.projectKey,
            name: info.projectName,
            path: info.projectPath,
            status: info.projectStatus
        )
        let resolved: ResolvedIdentity
        if info.projectStatus == .available, let link = worktreeResolver.link(forProjectPath: info.projectPath) {
            resolved = ResolvedIdentity(
                identity: StatsProjectIdentity(
                    key: "path:\(link.mainPath)",
                    name: URL(fileURLWithPath: link.mainPath).lastPathComponent,
                    path: link.mainPath,
                    status: .available
                ),
                worktree: link
            )
        } else {
            resolved = ResolvedIdentity(identity: base, worktree: nil)
        }
        identityCache[cacheKey] = resolved
        return resolved
    }

    private nonisolated static func totals(of bucket: ConversationUsageBucket) -> UsageTotals {
        var totals = UsageTotals.zero
        totals.inputTokens = bucket.inputTokens
        totals.outputTokens = bucket.outputTokens
        totals.cacheReadTokens = bucket.cacheReadTokens
        totals.cacheCreationTokens = bucket.cacheCreationTokens
        totals.costUSD = bucket.costUSD
        totals.requestCount = bucket.requestCount
        totals.hasUnpricedUsage = bucket.hasUnpricedUsage
        return totals
    }

    func detail(key: String) -> ConversationDetail? {
        if let cachedDetail, cachedDetail.revision == revision, cachedDetail.key == key {
            return cachedDetail.detail
        }
        guard let info = infos[key] else { return nil }
        let values = buckets.values.filter { $0.conversationKey == key }
        let overall = aggregate(Array(values))
        var perModel: [String: [ConversationUsageBucket]] = [:]
        for value in values { perModel[value.model, default: []].append(value) }
        var models: [ConversationModelSummary] = []
        for (model, modelBuckets) in perModel {
            let item = aggregate(modelBuckets)
            models.append(ConversationModelSummary(model: model, totals: item.totals, costs: item.costs, speed: item.speed))
        }
        models.sort { lhs, rhs in
            if lhs.costs.total == rhs.costs.total { return lhs.model < rhs.model }
            return lhs.costs.total > rhs.costs.total
        }
        let detail = ConversationDetail(
            info: info,
            totals: overall.totals,
            costs: overall.costs,
            speed: overall.speed,
            models: models
        )
        cachedDetail = (revision, key, detail)
        return detail
    }

    private func merge(seed: ConversationSeed) -> Bool {
        if var info = infos[seed.key] {
            let original = info
            if let title = seed.title, !title.isEmpty { info.title = title }
            let sameProject = info.projectKey == seed.project.key
            let shouldReplaceProject = info.projectStatus == .unassigned
                || seed.project.source.priority > info.projectSource.priority
            if sameProject || (seed.project.status != .unassigned && shouldReplaceProject) {
                info.projectKey = seed.project.key
                info.projectName = seed.project.name
                info.projectPath = seed.project.path
                info.projectStatus = seed.project.status
                info.projectSource = seed.project.source
            }
            if info.gitBranch == nil { info.gitBranch = seed.gitBranch }
            if !info.sourcePaths.contains(seed.sourcePath) { info.sourcePaths.append(seed.sourcePath) }
            info.includesSubtasks = info.includesSubtasks || seed.includesSubtasks
            info.cacheCreationAvailable = info.cacheCreationAvailable || seed.cacheCreationAvailable
            guard info != original else { return false }
            infos[seed.key] = info
            return true
        } else {
            let now = Date.distantFuture
            infos[seed.key] = ConversationInfo(
                key: seed.key,
                conversationID: seed.id,
                app: seed.app,
                title: seed.title,
                projectKey: seed.project.key,
                projectName: seed.project.name,
                projectPath: seed.project.path,
                projectStatus: seed.project.status,
                projectSource: seed.project.source,
                gitBranch: seed.gitBranch,
                sourcePaths: [seed.sourcePath],
                firstAt: now,
                lastAt: .distantPast,
                includesSubtasks: seed.includesSubtasks,
                cacheCreationAvailable: seed.cacheCreationAvailable
            )
            return true
        }
    }

    private func aggregate(_ values: [ConversationUsageBucket]) -> (
        totals: UsageTotals,
        costs: ConversationCostTotals,
        speed: UsageSpeedBreakdown
    ) {
        var totals = UsageTotals.zero
        var costs = ConversationCostTotals()
        var speed = UsageSpeedBreakdown()
        for value in values {
            totals.inputTokens += value.inputTokens
            totals.outputTokens += value.outputTokens
            totals.cacheReadTokens += value.cacheReadTokens
            totals.cacheCreationTokens += value.cacheCreationTokens
            totals.costUSD += value.costUSD
            totals.requestCount += value.requestCount
            totals.hasUnpricedUsage = totals.hasUnpricedUsage || value.hasUnpricedUsage
            costs.input += value.inputCostUSD
            costs.output += value.outputCostUSD
            costs.cacheRead += value.cacheReadCostUSD
            costs.cacheCreation += value.cacheCreationCostUSD
            costs.hasUnpricedUsage = costs.hasUnpricedUsage || value.hasUnpricedUsage

            var bucketTotals = UsageTotals.zero
            bucketTotals.inputTokens = value.inputTokens
            bucketTotals.outputTokens = value.outputTokens
            bucketTotals.cacheReadTokens = value.cacheReadTokens
            bucketTotals.cacheCreationTokens = value.cacheCreationTokens
            bucketTotals.costUSD = value.costUSD
            bucketTotals.requestCount = value.requestCount
            speed.add(
                speed: value.speed,
                totals: bucketTotals,
                app: value.app,
                model: value.model,
                hasUnpricedCost: value.hasUnpricedUsage
            )
        }
        return (totals, costs, speed)
    }

    private func markChanged() {
        revision &+= 1
        cachedQuery = nil
        cachedDetail = nil
        cachedOverview = nil
        cachedProjectDetail = nil
        // 路径状态（worktree 新建 / 删除）可能随扫描变化；身份映射随数据版本一起重算。
        identityCache.removeAll(keepingCapacity: true)
    }
}
