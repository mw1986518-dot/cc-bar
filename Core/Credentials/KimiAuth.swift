import Foundation

/// Kimi（kimi-code）登录态：读取 Kimi Code CLI 的凭据文件，
/// 访问令牌 15 分钟过期，刷新后必须把轮换出的新令牌写回文件
/// （旧 refresh_token 立即作废），否则 CLI 侧的续期会失效。
struct KimiAuthSession: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case kimiCodeCLI = "kimicode"

        var displayName: String {
            switch self {
            case .kimiCodeCLI: return "Kimi Code CLI"
            }
        }
    }

    var accessToken: String
    var refreshToken: String
    var expiresAt: Date?
    var nickname: String?
    var userID: String?
    var source: Source

    var accountKey: String {
        if let userID, !userID.isEmpty { return "user:\(userID)" }
        let prefix = String(accessToken.prefix(8))
        let suffix = String(accessToken.suffix(6))
        return "token:\(prefix)...\(suffix)"
    }

    var accessTokenExpired: Bool {
        // 提前 60 秒视为过期，避免请求在飞行途中过期。
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

enum KimiAuth {
    private static let credentialsRelativePath = "credentials/kimi-code.json"

    /// 依次探测：KIMI_CODE_HOME 环境变量 → ~/.kimi-code → ~/.kimi-code-*（按名称排序）。
    /// 返回第一个结构完整的凭据；多账号目录由用户通过环境变量显式指定。
    static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> KimiAuthSession? {
        for home in candidateHomes(homeDirectory: homeDirectory, environment: environment) {
            if let session = readCredentials(at: home.appendingPathComponent(credentialsRelativePath)) {
                return session
            }
        }
        return nil
    }

    static func candidateHomes(
        homeDirectory: URL,
        environment: [String: String]
    ) -> [URL] {
        var homes: [URL] = []
        if let custom = environment["KIMI_CODE_HOME"], !custom.isEmpty {
            homes.append(URL(fileURLWithPath: custom, isDirectory: true))
            return homes
        }
        homes.append(homeDirectory.appendingPathComponent(".kimi-code", isDirectory: true))
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: homeDirectory.path) {
            for name in entries.sorted() where name.hasPrefix(".kimi-code-") {
                homes.append(homeDirectory.appendingPathComponent(name, isDirectory: true))
            }
        }
        return homes
    }

    static func readCredentials(at url: URL) -> KimiAuthSession? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty
        else { return nil }
        var expiresAt: Date?
        if let ts = (json["expires_at"] as? Double) ?? (json["expires_at"] as? Int).map(Double.init) {
            expiresAt = Date(timeIntervalSince1970: ts)
        }
        return KimiAuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            nickname: json["nickname"] as? String,
            userID: json["user_id"] as? String,
            source: .kimiCodeCLI
        )
    }

    /// 刷新成功后将轮换令牌写回凭据文件（保留其它字段，原子写）。
    /// 返回更新后的会话；文件不可写时返回内存态（本次仍可用，但 CLI 下次续期会失效）。
    @discardableResult
    static func persist(_ session: KimiAuthSession, homeDirectory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> KimiAuthSession {
        for home in candidateHomes(homeDirectory: homeDirectory, environment: environment) {
            let url = home.appendingPathComponent(credentialsRelativePath)
            guard var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] else { continue }
            json["access_token"] = session.accessToken
            json["refresh_token"] = session.refreshToken
            if let expiresAt = session.expiresAt {
                json["expires_at"] = expiresAt.timeIntervalSince1970
            }
            if let nickname = session.nickname { json["nickname"] = nickname }
            if let userID = session.userID { json["user_id"] = userID }
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { continue }
            do {
                try data.write(to: url, options: [.atomic])
                return session
            } catch {
                continue
            }
        }
        return session
    }
}

/// 串行化的 Kimi 令牌续期：同一时刻只允许一个刷新请求，
/// 避免与 CLI 并发刷新造成 refresh_token 互相作废。
actor KimiTokenRefresher {
    static let shared = KimiTokenRefresher()

    private static let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    /// 返回可用的 access_token：未过期直接返回；过期则刷新并写回凭据文件。
    func validAccessToken(for session: KimiAuthSession) async -> Result<KimiAuthSession, QuotaError> {
        guard session.accessTokenExpired else { return .success(session) }
        return await refresh(session)
    }

    /// 强制刷新（401 重试链路用）。先重读文件：CLI 可能刚刷新过，
    /// 文件的 refresh_token 已轮换，此时应以文件里的新凭据为准。
    func refresh(_ session: KimiAuthSession) async -> Result<KimiAuthSession, QuotaError> {
        var current = session
        if let reloaded = KimiAuth.load(), reloaded.refreshToken != session.refreshToken {
            if !reloaded.accessTokenExpired { return .success(reloaded) }
            current = reloaded
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(current.refreshToken)&client_id=\(Self.clientID)"
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("non-http response"))
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
                return .failure(.tokenRefreshFailed("http \(http.statusCode): \(msg)"))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String, !accessToken.isEmpty,
                  let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty
            else {
                return .failure(.tokenRefreshFailed("missing tokens in response"))
            }
            let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 900
            let refreshed = KimiAuthSession(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(expiresIn),
                nickname: current.nickname,
                userID: current.userID,
                source: current.source
            )
            return .success(KimiAuth.persist(refreshed, homeDirectory: FileManager.default.homeDirectoryForCurrentUser))
        } catch {
            return .failure(.from(transport: error))
        }
    }
}
