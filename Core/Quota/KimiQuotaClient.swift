import Foundation

enum KimiQuotaClient {
    private static let usagesURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private static let meURL = URL(string: "https://api.kimi.com/coding/v1/me")!

    struct FetchResult: Sendable {
        var snapshot: QuotaSnapshot
        var session: KimiAuthSession
    }

    /// 完整取数：确保令牌有效（必要时刷新并写回）→ 拉额度 → 尽力拉账号昵称。
    /// 401 时刷新一次重试一次（CLI 并发刷新可能令手头令牌提前作废）。
    static func fetch(
        session initialSession: KimiAuthSession,
        urlSession: URLSession = .shared
    ) async -> Result<FetchResult, QuotaError> {
        var session = initialSession
        switch await KimiTokenRefresher.shared.validAccessToken(for: session) {
        case .success(let refreshed):
            session = refreshed
        case .failure(let error):
            return .failure(error)
        }

        var usagesData: Data
        switch await request(url: usagesURL, accessToken: session.accessToken, session: urlSession) {
        case .success(let data):
            usagesData = data
        case .failure(let error) where error.httpStatusCode == 401 && !error.looksLikeInterceptedResponse:
            switch await KimiTokenRefresher.shared.refresh(session) {
            case .success(let refreshed):
                session = refreshed
            case .failure(let refreshError):
                return .failure(refreshError)
            }
            switch await request(url: usagesURL, accessToken: session.accessToken, session: urlSession) {
            case .success(let data):
                usagesData = data
            case .failure(let retryError):
                return .failure(retryError)
            }
        case .failure(let error):
            return .failure(error)
        }

        // 昵称 / user_id 只用于展示，失败不阻塞额度。
        if case .success(let meData) = await request(url: meURL, accessToken: session.accessToken, session: urlSession),
           let meJson = try? JSONSerialization.jsonObject(with: meData) as? [String: Any]
        {
            session.nickname = meJson["nickname"] as? String ?? session.nickname
            session.userID = meJson["user_id"] as? String ?? session.userID
        }

        guard let json = try? JSONSerialization.jsonObject(with: usagesData) as? [String: Any] else {
            return .failure(.decode("kimi usages: not a json object"))
        }
        guard let snapshot = parse(root: json, fetchedAt: Date()) else {
            return .failure(.decode("kimi usages: missing usage detail"))
        }
        return .success(FetchResult(snapshot: snapshot, session: session))
    }

    private static func request(
        url: URL,
        accessToken: String,
        session: URLSession
    ) async -> Result<Data, QuotaError> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
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

    /// 解析 /v1/usages 为额度快照。纯函数，可单测。
    ///
    /// 顶层 `usage` 是会员套餐额度（百分比字符串）；`limits[]` 第一项是
    /// 5 小时窗口（window.duration=300, timeUnit=MINUTE）。主条用套餐额度
    /// （用户关心的"还剩多少"），5 小时窗口放副条。
    static func parse(root: [String: Any], fetchedAt: Date = Date()) -> QuotaSnapshot? {
        guard let usage = root["usage"] as? [String: Any],
              let limitRaw = parseNumber(usage["limit"]),
              limitRaw > 0,
              let usedRaw = parseNumber(usage["used"])
        else { return nil }

        let usedPercent = min(100, max(0, (usedRaw / limitRaw) * 100))
        let planLimit = QuotaLimit(
            id: "kimi-plan",
            kind: .weekly,
            displayName: nil,
            window: QuotaWindow(
                usedPercent: usedPercent,
                resetsAt: parseDate(usage["resetTime"]),
                windowSeconds: 7 * 86_400
            )
        )

        var fiveHourLimit: QuotaLimit?
        if let limits = root["limits"] as? [[String: Any]],
           let first = limits.first,
           let detail = first["detail"] as? [String: Any],
           let cap = parseNumber(detail["limit"]),
           cap > 0
        {
            let remaining = parseNumber(detail["remaining"]) ?? cap
            let used = min(100, max(0, ((cap - remaining) / cap) * 100))
            fiveHourLimit = QuotaLimit(
                id: "kimi-five-hour",
                kind: .fiveHour,
                displayName: nil,
                window: QuotaWindow(
                    usedPercent: used,
                    resetsAt: parseDate(detail["resetTime"]),
                    windowSeconds: 5 * 3_600
                )
            )
        }

        return QuotaSnapshot(
            app: .kimi,
            primaryLimit: planLimit,
            secondaryLimit: fiveHourLimit,
            auxiliaryLimits: [],
            modelLimits: [],
            planType: nil,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - 辅助解析

    private static func parseNumber(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let str = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: str), d.timeIntervalSince1970 > 0 { return d }
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: str), d.timeIntervalSince1970 > 0 { return d }
        return nil
    }
}
