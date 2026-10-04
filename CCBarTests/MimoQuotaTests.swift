import XCTest
@testable import CCBar

final class MimoQuotaTests: XCTestCase {
    func testQuotaAppCapabilities() {
        XCTAssertNil(QuotaApp.mimo.usageApp, "MiMo 不作为本地用量统计 app")

        let desc = QuotaProviderDescriptor.descriptor(for: .mimo)
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc?.supportsMenuBar == true, "MiMo 支持菜单栏")
        XCTAssertTrue(desc?.supportsFloatingHUD == true, "MiMo 支持悬浮窗")

        XCTAssertTrue(QuotaProviderDescriptor.accountProviders.contains(where: { $0.app == .mimo }))
        XCTAssertTrue(QuotaProviderDescriptor.popoverProviders.contains(where: { $0.app == .mimo }))
        XCTAssertTrue(QuotaProviderDescriptor.menuBarProviders.contains(where: { $0.app == .mimo }))
        XCTAssertTrue(QuotaProviderDescriptor.floatingProviders.contains(where: { $0.app == .mimo }))
    }

    func testParseUsagePlanTotalToken() throws {
        // 依据 platform.xiaomimimo.com/api/v1/tokenPlan/usage 的实测结构：
        // data.usage.items[] 取 plan_total_token，percent 是 0~1 fraction。
        let json: [String: Any] = [
            "code": 0,
            "data": [
                "usage": [
                    "items": [
                        ["name": "compensation_total_token", "used": 0, "limit": 100_000_000, "percent": 0],
                        ["name": "plan_total_token", "used": 1_845_000_000, "limit": 4_100_000_000, "percent": 0.45],
                    ],
                ],
                "monthUsage": ["items": [["name": "month_total_token", "used": 9, "limit": 99]]],
            ],
        ]

        let snapshot = try XCTUnwrap(MimoQuotaClient.parseUsage(root: json))
        let plan = try XCTUnwrap(snapshot.primaryLimit)
        XCTAssertEqual(plan.kind, .unknown)
        XCTAssertEqual(plan.displayName, "PLAN")
        XCTAssertEqual(plan.window.usedPercent, 45, accuracy: 0.01)
        XCTAssertEqual(plan.window.remainingPercent, 55, accuracy: 0.01)
        XCTAssertNil(snapshot.secondaryLimit, "MiMo 是月度套餐单窗口")
    }

    func testParseUsageFallsBackToUsedOverLimit() throws {
        let json: [String: Any] = [
            "code": 0,
            "data": [
                "usage": [
                    "items": [
                        ["name": "plan_total_token", "used": 2_050_000_000, "limit": 4_100_000_000],
                    ],
                ],
            ],
        ]
        let snapshot = try XCTUnwrap(MimoQuotaClient.parseUsage(root: json))
        XCTAssertEqual(snapshot.primaryLimit?.window.usedPercent ?? -1, 50, accuracy: 0.01)
    }

    func testParseUsageRejectsMissingPlanItem() {
        let json: [String: Any] = [
            "code": 0,
            "data": ["usage": ["items": [["name": "compensation_total_token", "used": 0, "limit": 1, "percent": 0]]]],
        ]
        XCTAssertNil(MimoQuotaClient.parseUsage(root: json))
        XCTAssertNil(MimoQuotaClient.parseUsage(root: ["code": 401]))
    }

    func testParseDetail() {
        let json: [String: Any] = [
            "code": 0,
            "data": [
                "planName": "Standard",
                "planCode": "standard",
                "expired": false,
                "currentPeriodEnd": "2026-11-03 23:59:59",
            ],
        ]
        let detail = MimoQuotaClient.parseDetail(root: json)
        XCTAssertEqual(detail.planName, "Standard")
        let end = detail.periodEnd
        XCTAssertNotNil(end)
        if let end {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            XCTAssertEqual(calendar.component(.day, from: end), 3)
            XCTAssertEqual(calendar.component(.month, from: end), 11)
        }
        XCTAssertNil(MimoQuotaClient.parseDetail(root: [:]).planName)
    }

    func testCookieSanitization() {
        XCTAssertEqual(
            MimoAuth.sanitizeCookie("  userId=123; serviceToken=abc.def\n\r "),
            "userId=123; serviceToken=abc.def"
        )
        XCTAssertNil(MimoAuth.sanitizeCookie("short"))
        XCTAssertNil(MimoAuth.sanitizeCookie("包含中文的cookie不合法长度过短问题"))
        XCTAssertTrue(MimoAuth.looksLikeSessionCookie("a=1; serviceToken=x"))
        XCTAssertFalse(MimoAuth.looksLikeSessionCookie("a=1; b=2"))
    }
}
