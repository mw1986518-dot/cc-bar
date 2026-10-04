import Foundation

enum MimoQuotaClient {
    private static let usageURL = URL(string: "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage")!
    private static let detailURL = URL(string: "https://platform.xiaomimimo.com/api/v1/tokenPlan/detail")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    struct FetchResult: Sendable {
        var snapshot: QuotaSnapshot
        var planName: String?
    }

    /// 套餐额度只在小米开放平台控制台，鉴权是网页会话 Cookie。
    /// usage 是主链路；detail 的失败不阻塞主额度展示（只是没有重置时刻与套餐名）。
    static func fetch(
        cookie: String,
        session: URLSession = .shared
    ) async -> Result<FetchResult, QuotaError> {
        let usageData: Data
        switch await request(url: usageURL, cookie: cookie, session: session) {
        case .success(let data):
            usageData = data
        case .failure(let error):
            return .failure(error)
        }

        guard let usageJson = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any] else {
            return .failure(.decode("mimo usage: not a json object"))
        }
        if let code = usageJson["code"] as? Int, code == 401 {
            return .failure(.http(401, "mimo session expired"))
        }
        guard var snapshot = parseUsage(root: usageJson, fetchedAt: Date()) else {
            return .failure(.decode("mimo usage: missing plan_total_token"))
        }

        var planName: String?
        if case .success(let detailData) = await request(url: detailURL, cookie: cookie, session: session),
           let detailJson = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any]
        {
            let detail = parseDetail(root: detailJson)
            planName = detail.planName
            if let resetsAt = detail.periodEnd {
                snapshot.primaryLimit?.window.resetsAt = resetsAt
            }
        }

        snapshot.planType = planName
        return .success(FetchResult(snapshot: snapshot, planName: planName))
    }

    private static func request(
        url: URL,
        cookie: String,
        session: URLSession
    ) async -> Result<Data, QuotaError> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("non-http response"))
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
                return .failure(.http(http.statusCode, msg))
            }
            return .success(data)
        } catch {
            return .failure(.from(transport: error))
        }
    }

    /// 解析 /tokenPlan/usage。纯函数，可单测。
    ///
    /// `data.usage.items[]` 里取 `name == "plan_total_token"`（套餐本体）；
    /// `compensation_total_token`（补偿积分）与 `data.monthUsage`（月总）忽略。
    /// `percent` 是 0~1 的 fraction（0.44 = 已用 44%），没有 percent 时用 used/limit 兜底。
    /// MiMo 是月度套餐单窗口，归 unknown 槽位，标签展示 PLAN。
    static func parseUsage(root: [String: Any], fetchedAt: Date = Date()) -> QuotaSnapshot? {
        guard (root["code"] as? Int) == 0,
              let data = root["data"] as? [String: Any],
              let usage = data["usage"] as? [String: Any],
              let items = usage["items"] as? [[String: Any]],
              let item = items.first(where: { $0["name"] as? String == "plan_total_token" })
        else { return nil }

        let usedFraction: Double
        if let percent = parseNumber(item["percent"]) {
            usedFraction = percent
        } else if let used = parseNumber(item["used"]),
                  let limit = parseNumber(item["limit"]),
                  limit > 0
        {
            usedFraction = used / limit
        } else {
            return nil
        }

        let planLimit = QuotaLimit(
            id: "mimo-plan",
            kind: .unknown,
            displayName: "PLAN",
            window: QuotaWindow(
                usedPercent: min(100, max(0, usedFraction * 100)),
                resetsAt: nil,
                windowSeconds: 30 * 86_400
            )
        )

        return QuotaSnapshot(
            app: .mimo,
            primaryLimit: planLimit,
            secondaryLimit: nil,
            auxiliaryLimits: [],
            modelLimits: [],
            planType: nil,
            fetchedAt: fetchedAt
        )
    }

    /// 解析 /tokenPlan/detail：`planName` 展示用；`currentPeriodEnd` 是 UTC 朴素时间
    /// "YYYY-MM-DD HH:mm:ss"，作为套餐重置时刻。
    static func parseDetail(root: [String: Any]) -> (planName: String?, periodEnd: Date?) {
        guard (root["code"] as? Int) == 0,
              let data = root["data"] as? [String: Any]
        else { return (nil, nil) }

        let planName = (data["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var periodEnd: Date?
        if let raw = data["currentPeriodEnd"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            periodEnd = formatter.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (planName?.isEmpty == false ? planName : nil, periodEnd)
    }

    // MARK: - 辅助解析

    private static func parseNumber(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }
}
