import XCTest
@testable import CCBar

final class KimiQuotaTests: XCTestCase {
    func testQuotaAppCapabilities() {
        XCTAssertNil(QuotaApp.kimi.usageApp, "Kimi 不作为本地用量统计 app")

        let desc = QuotaProviderDescriptor.descriptor(for: .kimi)
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc?.supportsMenuBar == true, "Kimi 支持菜单栏")
        XCTAssertTrue(desc?.supportsFloatingHUD == true, "Kimi 支持悬浮窗")

        XCTAssertTrue(QuotaProviderDescriptor.accountProviders.contains(where: { $0.app == .kimi }))
        XCTAssertTrue(QuotaProviderDescriptor.popoverProviders.contains(where: { $0.app == .kimi }))
        XCTAssertTrue(QuotaProviderDescriptor.menuBarProviders.contains(where: { $0.app == .kimi }))
        XCTAssertTrue(QuotaProviderDescriptor.floatingProviders.contains(where: { $0.app == .kimi }))
    }

    func testParseUsagesRealShape() throws {
        // 真实响应样本（docs/fixtures-kimi-mimo/kimi-usages.json）的关键结构。
        let json: [String: Any] = [
            "usage": [
                "limit": "100",
                "used": "91",
                "remaining": "9",
                "resetTime": "2026-10-06T12:40:48.291460Z",
            ],
            "limits": [
                [
                    "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                    "detail": [
                        "limit": "100",
                        "remaining": "100",
                        "resetTime": "2026-10-04T12:40:48.291460Z",
                    ],
                ],
            ],
        ]

        let snapshot = try XCTUnwrap(KimiQuotaClient.parse(root: json))

        let plan = try XCTUnwrap(snapshot.primaryLimit)
        XCTAssertEqual(plan.kind, .weekly)
        XCTAssertEqual(plan.window.usedPercent, 91, accuracy: 0.01)
        XCTAssertEqual(plan.window.remainingPercent, 9, accuracy: 0.01)
        XCTAssertNotNil(plan.window.resetsAt)

        let fiveHour = try XCTUnwrap(snapshot.secondaryLimit)
        XCTAssertEqual(fiveHour.kind, .fiveHour)
        XCTAssertEqual(fiveHour.window.usedPercent, 0, accuracy: 0.01)
        XCTAssertEqual(fiveHour.window.windowSeconds, 5 * 3600)
    }

    func testParseUsagesRejectsGarbage() {
        XCTAssertNil(KimiQuotaClient.parse(root: [:]))
        XCTAssertNil(KimiQuotaClient.parse(root: ["usage": ["limit": "0", "used": "0"]]))
        XCTAssertNil(KimiQuotaClient.parse(root: ["usage": ["limit": "abc"]]))
    }

    func testCredentialFileParsing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentialsDir = tempDir.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "access_token": "at-test-token",
            "refresh_token": "rt-test-token",
            "expires_at": Date().addingTimeInterval(600).timeIntervalSince1970,
            "user_id": "u-test",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: credentialsDir.appendingPathComponent("kimi-code.json"))

        let session = try XCTUnwrap(KimiAuth.readCredentials(
            at: credentialsDir.appendingPathComponent("kimi-code.json")
        ))
        XCTAssertEqual(session.accessToken, "at-test-token")
        XCTAssertEqual(session.refreshToken, "rt-test-token")
        XCTAssertEqual(session.userID, "u-test")
        XCTAssertEqual(session.accountKey, "user:u-test")
        XCTAssertFalse(session.accessTokenExpired)
    }

    func testAccessTokenExpiry() {
        var session = KimiAuthSession(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(30), source: .kimiCodeCLI
        )
        XCTAssertTrue(session.accessTokenExpired, "剩余 30 秒按提前 60 秒视为过期")
        session.expiresAt = Date().addingTimeInterval(600)
        XCTAssertFalse(session.accessTokenExpired)
        session.expiresAt = nil
        XCTAssertFalse(session.accessTokenExpired, "无 expires_at 时按未过期处理")
    }
}
