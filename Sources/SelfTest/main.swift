import Foundation
import CodexAccountSwitchCore

// 极简断言框架：Command Line Tools 环境没有 XCTest。
var failures = 0
var passed = 0
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ msg: String = "", file: String = #fileID, line: Int = #line) {
    do { let x = try a(), y = try b(); if x == y { passed += 1 } else { failures += 1; print("FAIL \(file):\(line) \(msg) — \(x) != \(y)") } }
    catch { failures += 1; print("FAIL \(file):\(line) \(msg) — threw \(error)") }
}
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ msg: String = "", file: String = #fileID, line: Int = #line) {
    do { let x = try a(), y = try b(); if x != y { passed += 1 } else { failures += 1; print("FAIL \(file):\(line) \(msg) — both \(x)") } }
    catch { failures += 1; print("FAIL \(file):\(line) \(msg) — threw \(error)") }
}
func XCTAssertTrue(_ a: @autoclosure () throws -> Bool, _ msg: String = "", file: String = #fileID, line: Int = #line) { XCTAssertEqual(try a(), true, msg, file: file, line: line) }
func XCTAssertFalse(_ a: @autoclosure () throws -> Bool, _ msg: String = "", file: String = #fileID, line: Int = #line) { XCTAssertEqual(try a(), false, msg, file: file, line: line) }
func XCTAssertNil<T>(_ a: @autoclosure () throws -> T?, _ msg: String = "", file: String = #fileID, line: Int = #line) {
    do { if try a() == nil { passed += 1 } else { failures += 1; print("FAIL \(file):\(line) \(msg) — expected nil") } }
    catch { failures += 1; print("FAIL \(file):\(line) \(msg) — threw \(error)") }
}
func XCTAssertThrowsError<T>(_ a: @autoclosure () throws -> T, _ msg: String = "", file: String = #fileID, line: Int = #line) {
    do { _ = try a(); failures += 1; print("FAIL \(file):\(line) \(msg) — expected throw") } catch { passed += 1 }
}
func XCTAssertNoThrow<T>(_ a: @autoclosure () throws -> T, _ msg: String = "", file: String = #fileID, line: Int = #line) {
    do { _ = try a(); passed += 1 } catch { failures += 1; print("FAIL \(file):\(line) \(msg) — threw \(error)") }
}
struct UnwrapFailure: Error {}
func XCTUnwrap<T>(_ a: @autoclosure () throws -> T?, file: String = #fileID, line: Int = #line) throws -> T {
    if let v = try a() { return v }
    failures += 1; print("FAIL \(file):\(line) — unexpected nil"); throw UnwrapFailure()
}
func XCTAssertEqual(_ a: @autoclosure () throws -> Double, _ b: @autoclosure () throws -> Double, accuracy: Double, file: String = #fileID, line: Int = #line) {
    do { let x = try a(), y = try b(); if abs(x - y) <= accuracy { passed += 1 } else { failures += 1; print("FAIL \(file):\(line) — \(x) !≈ \(y)") } }
    catch { failures += 1; print("FAIL \(file):\(line) — threw \(error)") }
}
class XCTestCase {
    required init() {}
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
func run<T: XCTestCase>(_ type: T.Type, _ cases: [(String, (T) throws -> Void)]) {
    for (name, body) in cases {
        let t = T()
        do { try t.setUpWithError(); try body(t); try t.tearDownWithError(); print("ok   \(T.self).\(name)") }
        catch { failures += 1; print("FAIL \(T.self).\(name) threw \(error)") }
    }
}


final class AuthSnapshotTests: XCTestCase {
    func testJWTClaimsDecodesBase64URLWithoutPadding() throws {
        let token = TestAuth.jwt(["email": "a@b.c", "n": 1])
        let claims = JWT.claims(token)
        XCTAssertEqual(claims?["email"] as? String, "a@b.c")
        XCTAssertNil(JWT.claims("not-a-jwt"))
    }

    func testParsesIdentityPlanAndExpiry() throws {
        let exp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let data = TestAuth.authJSON(accountId: "acc-1", email: "one@example.com", plan: "pro", accessExp: exp)
        let snap = try AuthSnapshot(data: data)
        XCTAssertEqual(snap.accountId, "acc-1")
        XCTAssertEqual(snap.email, "one@example.com")
        XCTAssertEqual(snap.planType, "pro")
        XCTAssertEqual(snap.displayName, "one@example.com")
        XCTAssertFalse(snap.accessTokenExpires(within: 60))
        XCTAssertTrue(snap.accessTokenExpires(within: 7200))
        XCTAssertEqual(snap.data, data, "原始字节必须原样保留")
    }

    func testFallsBackToIdTokenAccountIdWhenTokensLackIt() throws {
        var object = TestAuth.authObject(accountId: "acc-2", email: "x@y.z", plan: "plus", accessExp: 0)
        var tokens = object["tokens"] as! [String: Any]
        tokens.removeValue(forKey: "account_id")
        object["tokens"] = tokens
        let snap = try AuthSnapshot(data: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(snap.accountId, "acc-2")
    }

    func testRejectsFilesWithoutTokens() throws {
        let apiKeyOnly = try! JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "sk-x"])
        XCTAssertThrowsError(try AuthSnapshot(data: apiKeyOnly))
    }

    func testReplacingTokensKeepsUnknownFieldsAndRotatesRefreshToken() throws {
        var object = TestAuth.authObject(accountId: "acc-3", email: "r@e.f", plan: "pro", accessExp: 0)
        object["future_field"] = ["nested": true]
        var tokens = object["tokens"] as! [String: Any]
        tokens["future_token_field"] = "keep-me"
        object["tokens"] = tokens
        let original = try AuthSnapshot(data: JSONSerialization.data(withJSONObject: object))

        let newAccess = TestAuth.jwt(["exp": Date().addingTimeInterval(864_000).timeIntervalSince1970])
        let rotated = try original.replacingTokens(idToken: nil, accessToken: newAccess, refreshToken: "rt-new")

        XCTAssertEqual(rotated.accountId, "acc-3")
        XCTAssertEqual(rotated.accessToken, newAccess)
        XCTAssertEqual(rotated.refreshToken, "rt-new")
        XCTAssertEqual(rotated.email, "r@e.f", "未传 id_token 时沿用旧的")
        let reparsed = try JSONSerialization.jsonObject(with: rotated.data) as! [String: Any]
        XCTAssertEqual((reparsed["future_field"] as? [String: Bool])?["nested"], true)
        XCTAssertEqual((reparsed["tokens"] as? [String: Any])?["future_token_field"] as? String, "keep-me")
        XCTAssertEqual(reparsed["auth_mode"] as? String, "chatgpt")
        XCTAssertNotEqual(reparsed["last_refresh"] as? String, object["last_refresh"] as? String)
    }
}

final class AccountStoreTests: XCTestCase {
    var codexHome: URL!
    var slots: URL!
    var store: AccountStore!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cas-tests-\(UUID().uuidString)", isDirectory: true)
        codexHome = base.appendingPathComponent("codex", isDirectory: true)
        slots = base.appendingPathComponent("slots", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        store = AccountStore(codexHome: codexHome, slotsDirectory: slots)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: codexHome.deletingLastPathComponent())
    }

    private func writeLive(_ data: Data) throws {
        try data.write(to: codexHome.appendingPathComponent("auth.json"))
    }

    private func posixMode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
    }

    func testSyncLiveIntoSlotStoresExactBytesWithPrivatePermissions() throws {
        let live = TestAuth.authJSON(accountId: "A", email: "a@x", plan: "pro", accessExp: 0)
        try writeLive(live)
        let snap = try store.syncLiveIntoSlot()
        XCTAssertEqual(snap?.accountId, "A")
        let slotURL = store.slotURL(for: "A")
        XCTAssertEqual(try Data(contentsOf: slotURL), live)
        XCTAssertEqual(try posixMode(slotURL), 0o600)
        XCTAssertEqual(store.loadSlots().map(\.accountId), ["A"])
    }

    func testSyncWithoutLiveFileIsNoop() throws {
        XCTAssertNil(try store.syncLiveIntoSlot())
        XCTAssertTrue(store.loadSlots().isEmpty)
    }

    func testActivateSavesBackCurrentLiveBeforeReplacingIt() throws {
        // 先登记 B 的旧快照，再让 live 是 A；A 的 live 版本比槽位里的新（模拟 Codex 已续期）。
        let bOld = TestAuth.authJSON(accountId: "B", email: "b@x", plan: "pro", accessExp: 0, refresh: "rt-b")
        try store.writeSlot(try AuthSnapshot(data: bOld))
        let aStale = TestAuth.authJSON(accountId: "A", email: "a@x", plan: "pro", accessExp: 0, refresh: "rt-a-old")
        try store.writeSlot(try AuthSnapshot(data: aStale))
        let aLive = TestAuth.authJSON(accountId: "A", email: "a@x", plan: "pro", accessExp: 0, refresh: "rt-a-rotated")
        try writeLive(aLive)

        try store.activate(accountId: "B")

        let liveNow = try Data(contentsOf: codexHome.appendingPathComponent("auth.json"))
        XCTAssertEqual(liveNow, bOld, "auth.json 应是 B 的完整原始字节")
        XCTAssertEqual(try Data(contentsOf: store.slotURL(for: "A")), aLive, "切换前必须把 A 的最新 live 回写，否则旧 refresh_token 会被复用")
        XCTAssertEqual(try posixMode(codexHome.appendingPathComponent("auth.json")), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: codexHome.path).filter { $0.hasPrefix(".") }
        XCTAssertTrue(leftovers.isEmpty, "不应残留临时文件：\(leftovers)")
    }

    func testActivateUnknownAccountThrowsAndLeavesLiveUntouched() throws {
        let live = TestAuth.authJSON(accountId: "A", email: "a@x", plan: "pro", accessExp: 0)
        try writeLive(live)
        XCTAssertThrowsError(try store.activate(accountId: "nope"))
        XCTAssertEqual(try Data(contentsOf: codexHome.appendingPathComponent("auth.json")), live)
    }

    func testActivateRefusesWhenLiveIsMalformed() throws {
        try store.writeSlot(try AuthSnapshot(data: TestAuth.authJSON(accountId: "B", email: "b@x", plan: "pro", accessExp: 0)))
        try writeLive(Data("{\"tokens\": {".utf8))
        XCTAssertThrowsError(try store.activate(accountId: "B"), "live 损坏时不能覆盖，否则会丢失可能已续期的令牌")
        XCTAssertEqual(try String(contentsOf: codexHome.appendingPathComponent("auth.json"), encoding: .utf8), "{\"tokens\": {")
    }

    func testRemoveSlot() throws {
        try store.writeSlot(try AuthSnapshot(data: TestAuth.authJSON(accountId: "B", email: "b@x", plan: "pro", accessExp: 0)))
        try store.removeSlot(accountId: "B")
        XCTAssertTrue(store.loadSlots().isEmpty)
        XCTAssertNoThrow(try store.removeSlot(accountId: "B"))
    }
}

final class UsageModelTests: XCTestCase {
    func testWindowLabels() throws {
        XCTAssertEqual(UsageWindow(usedPercent: 1, windowSeconds: 604_800, resetAt: nil).label, "每周")
        XCTAssertEqual(UsageWindow(usedPercent: 1, windowSeconds: 18_000, resetAt: nil).label, "5 小时")
        XCTAssertEqual(UsageWindow(usedPercent: 1, windowSeconds: nil, resetAt: nil).label, "额度")
    }

    func testHeadlinePrefersWeeklyWindow() throws {
        let fiveHour = UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil)
        let weekly = UsageWindow(usedPercent: 70, windowSeconds: 604_800, resetAt: nil)
        let usage = UsageSnapshot(email: nil, planType: "pro", primary: fiveHour, secondary: weekly, limitReached: false, fetchedAt: Date())
        XCTAssertEqual(usage.headlineWindow, weekly)
        let onlyFive = UsageSnapshot(email: nil, planType: "pro", primary: fiveHour, secondary: nil, limitReached: false, fetchedAt: Date())
        XCTAssertEqual(onlyFive.headlineWindow, fiveHour)
    }
}

final class LoginPromptTests: XCTestCase {
    func testParsesDeviceCodePromptWithANSI() throws {
        let raw = "\nWelcome to Codex [v\u{1B}[90m0.154.0\u{1B}[0m]\n\nFollow these steps to sign in with ChatGPT using device code authorization:\n\n1. Open this link in your browser and sign in to your account\n   \u{1B}[34mhttps://auth.openai.com/codex/device\u{1B}[0m\n\n2. Enter this one-time code \u{1B}[90m(expires in 15 minutes)\u{1B}[0m\n   \u{1B}[34mABCD-EFGH\u{1B}[0m\n\n\u{1B}[90mContinue only if you started this login in Codex.\u{1B}[0m\n"
        let prompt = LoginSession.parsePrompt(raw)
        XCTAssertEqual(prompt?.url, "https://auth.openai.com/codex/device")
        XCTAssertEqual(prompt?.code, "ABCD-EFGH")
    }

    func testIncompleteOutputYieldsNoPrompt() throws {
        XCTAssertNil(LoginSession.parsePrompt("1. Open this link in your browser\n   https://auth.openai.com/codex/device\n"))
        XCTAssertNil(LoginSession.parsePrompt("Error logging in: something"))
    }
}

final class WeeklyPaceTests: XCTestCase {
    // 7 天窗口，已过去 2 天（计划 28.6%），实际用 40%。
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var window: UsageWindow { UsageWindow(usedPercent: 40, windowSeconds: 604_800, resetAt: now.addingTimeInterval(5 * 86_400)) }

    func testLinearBaselineAndGap() throws {
        let pace = try XCTUnwrap(WeeklyPace(window: window, samples: [], now: now))
        XCTAssertEqual(Int(pace.plannedPercent.rounded()), 29)
        XCTAssertEqual(Int(pace.gapPercent.rounded()), 11)
        XCTAssertEqual(pace.verdict, .ahead)
        XCTAssertEqual(Int(pace.remainingPercent), 60)
        XCTAssertEqual(pace.sustainablePercentPerDay, 12, accuracy: 0.01)
        XCTAssertNil(pace.recentRatePerHour, "没有采样不做速度预测")
    }

    func testRecentRateProjectsExhaustionBeforeReset() throws {
        let reset = window.resetAt!
        let samples = [
            UsageSample(at: now.addingTimeInterval(-3 * 3600), usedPercent: 25, resetAt: reset),
            UsageSample(at: now, usedPercent: 40, resetAt: reset),
        ]  // 5%/小时 → 剩 60% 只能撑 12 小时，远早于 5 天后的重置
        let pace = try XCTUnwrap(WeeklyPace(window: window, samples: samples, now: now))
        XCTAssertEqual(try XCTUnwrap(pace.recentRatePerHour), 5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(pace.projectedExhaustionAt), now.addingTimeInterval(12 * 3600))
        XCTAssertTrue(try XCTUnwrap(pace.projectedPercentAtReset) > 100)
    }

    func testSlowRateProjectsNoExhaustion() throws {
        let reset = window.resetAt!
        let samples = [
            UsageSample(at: now.addingTimeInterval(-6 * 3600), usedPercent: 39, resetAt: reset),
            UsageSample(at: now, usedPercent: 40, resetAt: reset),
        ]  // 1%/6h → 5 天再用 20%，到重置约 60%
        let pace = try XCTUnwrap(WeeklyPace(window: window, samples: samples, now: now))
        XCTAssertNil(pace.projectedExhaustionAt)
        XCTAssertEqual(Int(try XCTUnwrap(pace.projectedPercentAtReset).rounded()), 60)
    }

    func testIgnoresSamplesFromPreviousWindowAndTooShortSpan() throws {
        let reset = window.resetAt!
        let previousWindow = [UsageSample(at: now.addingTimeInterval(-3600), usedPercent: 90, resetAt: reset.addingTimeInterval(-604_800))]
        XCTAssertNil(try XCTUnwrap(WeeklyPace(window: window, samples: previousWindow, now: now)).recentRatePerHour)
        let tooShort = [
            UsageSample(at: now.addingTimeInterval(-600), usedPercent: 30, resetAt: reset),
            UsageSample(at: now, usedPercent: 40, resetAt: reset),
        ]
        XCTAssertNil(try XCTUnwrap(WeeklyPace(window: window, samples: tooShort, now: now)).recentRatePerHour)
    }

    func testHistoryStoreDedupesWithinMinuteAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cas-hist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageHistoryStore(fileURL: url)
        store.record(accountId: "A", window: window, at: now)
        store.record(accountId: "A", window: window, at: now.addingTimeInterval(30))
        store.record(accountId: "A", window: window, at: now.addingTimeInterval(120))
        XCTAssertEqual(store.samples(for: "A").count, 2)
        let reloaded = UsageHistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.samples(for: "A").map(\.usedPercent), [40, 40])
        reloaded.remove(accountId: "A")
        XCTAssertTrue(UsageHistoryStore(fileURL: url).samples(for: "A").isEmpty)
    }
}

enum TestAuth {
    static func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJSUzI1NiJ9.\(b64).sig"
    }

    static func authObject(accountId: String, email: String, plan: String, accessExp: Double, refresh: String = "rt") -> [String: Any] {
        let idToken = jwt([
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_account_id": accountId, "chatgpt_plan_type": plan],
        ])
        let accessToken = jwt(["exp": accessExp, "sub": "user"])
        return [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "id_token": idToken,
                "access_token": accessToken,
                "refresh_token": refresh,
                "account_id": accountId,
            ],
            "last_refresh": "2026-01-01T00:00:00.000000Z",
        ]
    }

    static func authJSON(accountId: String, email: String, plan: String, accessExp: Double, refresh: String = "rt") -> Data {
        try! JSONSerialization.data(
            withJSONObject: authObject(accountId: accountId, email: email, plan: plan, accessExp: accessExp, refresh: refresh),
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}

// MARK: 运行
run(AuthSnapshotTests.self, [
    ("testJWTClaimsDecodesBase64URLWithoutPadding", { try $0.testJWTClaimsDecodesBase64URLWithoutPadding() }),
    ("testParsesIdentityPlanAndExpiry", { try $0.testParsesIdentityPlanAndExpiry() }),
    ("testFallsBackToIdTokenAccountIdWhenTokensLackIt", { try $0.testFallsBackToIdTokenAccountIdWhenTokensLackIt() }),
    ("testRejectsFilesWithoutTokens", { try $0.testRejectsFilesWithoutTokens() }),
    ("testReplacingTokensKeepsUnknownFieldsAndRotatesRefreshToken", { try $0.testReplacingTokensKeepsUnknownFieldsAndRotatesRefreshToken() }),
])
run(AccountStoreTests.self, [
    ("testSyncLiveIntoSlotStoresExactBytesWithPrivatePermissions", { try $0.testSyncLiveIntoSlotStoresExactBytesWithPrivatePermissions() }),
    ("testSyncWithoutLiveFileIsNoop", { try $0.testSyncWithoutLiveFileIsNoop() }),
    ("testActivateSavesBackCurrentLiveBeforeReplacingIt", { try $0.testActivateSavesBackCurrentLiveBeforeReplacingIt() }),
    ("testActivateUnknownAccountThrowsAndLeavesLiveUntouched", { try $0.testActivateUnknownAccountThrowsAndLeavesLiveUntouched() }),
    ("testActivateRefusesWhenLiveIsMalformed", { try $0.testActivateRefusesWhenLiveIsMalformed() }),
    ("testRemoveSlot", { try $0.testRemoveSlot() }),
])
run(LoginPromptTests.self, [
    ("testParsesDeviceCodePromptWithANSI", { try $0.testParsesDeviceCodePromptWithANSI() }),
    ("testIncompleteOutputYieldsNoPrompt", { try $0.testIncompleteOutputYieldsNoPrompt() }),
])
run(WeeklyPaceTests.self, [
    ("testLinearBaselineAndGap", { try $0.testLinearBaselineAndGap() }),
    ("testRecentRateProjectsExhaustionBeforeReset", { try $0.testRecentRateProjectsExhaustionBeforeReset() }),
    ("testSlowRateProjectsNoExhaustion", { try $0.testSlowRateProjectsNoExhaustion() }),
    ("testIgnoresSamplesFromPreviousWindowAndTooShortSpan", { try $0.testIgnoresSamplesFromPreviousWindowAndTooShortSpan() }),
    ("testHistoryStoreDedupesWithinMinuteAndPersists", { try $0.testHistoryStoreDedupesWithinMinuteAndPersists() }),
])
run(UsageModelTests.self, [
    ("testWindowLabels", { try $0.testWindowLabels() }),
    ("testHeadlinePrefersWeeklyWindow", { try $0.testHeadlinePrefersWeeklyWindow() }),
])
print("\n\(passed) assertions passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
