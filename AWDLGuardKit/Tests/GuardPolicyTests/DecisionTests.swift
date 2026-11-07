import GuardPolicy
import Testing

private let againstTheStorm = ForegroundApp(
    name: "Against the Storm.exe", bundleIdentifier: nil,
    executableName: "Against the Storm.exe", isGame: false)
private let geForceNow = ForegroundApp(
    name: "GeForce NOW", bundleIdentifier: "com.nvidia.gfnpc.mall",
    executableName: "GeForceNOW", isGame: true)
private let safari = ForegroundApp(
    name: "Safari", bundleIdentifier: "com.apple.Safari", executableName: "Safari", isGame: false)
private let stormRule = AppRule(
    target: .windowsApp(executableName: "Against the Storm.exe"), name: "Against the Storm")

@Suite struct DecisionTests {
    @Test func manualModesIgnoreAppAndNetwork() {
        #expect(Decision(mode: .allow, app: geForceNow, rules: [], isOnWiFi: true)
            == Decision(reason: .allowedByMode))
        #expect(Decision(mode: .suppress, app: safari, rules: [], isOnWiFi: false)
            == Decision(reason: .suppressedByMode))
    }

    @Test func detectedGameSuppressesOnWiFi() {
        #expect(Decision(mode: .automatic, app: geForceNow, rules: [], isOnWiFi: true)
            == Decision(reason: .game(appName: "GeForce NOW")))
    }

    @Test func triggerOffWiFiIsAllowedWithReason() {
        #expect(Decision(mode: .automatic, app: geForceNow, rules: [], isOnWiFi: false)
            == Decision(reason: .notOnWiFi))
    }

    @Test func windowsExecutableMatchesRuleWithoutBundle() {
        #expect(Decision(mode: .automatic, app: againstTheStorm, rules: [stormRule], isOnWiFi: true)
            == Decision(reason: .rule(appName: "Against the Storm")))
    }

    @Test func windowsExecutableMatchIgnoresCase() {
        var app = againstTheStorm
        app.executableName = "AGAINST THE STORM.EXE"
        #expect(Decision(mode: .automatic, app: app, rules: [stormRule], isOnWiFi: true).isSuppressed)
    }

    @Test func unmatchedWindowsAppIsNotATrigger() {
        #expect(Decision(mode: .automatic, app: againstTheStorm, rules: [], isOnWiFi: true)
            == Decision(reason: .noTrigger))
    }

    @Test func ruleTurnedOffExcludesDetectedGame() {
        let rule = AppRule(
            target: .macApp(bundleIdentifier: "com.nvidia.gfnpc.mall"), name: "GeForce NOW",
            isSuppressing: false)
        #expect(Decision(mode: .automatic, app: geForceNow, rules: [rule], isOnWiFi: true)
            == Decision(reason: .excludedByRule(appName: "GeForce NOW")))
    }

    @Test func windowsRuleDoesNotMatchMacAppWithSameExecutable() {
        let rule = AppRule(target: .windowsApp(executableName: "Safari.exe"), name: "Safari")
        var app = safari
        app.executableName = "Safari.exe"
        #expect(!Decision(mode: .automatic, app: app, rules: [rule], isOnWiFi: true).isSuppressed)
    }

    @Test func ruleTurnedOffStaysExcludedOffWiFi() {
        let rule = AppRule(
            target: .macApp(bundleIdentifier: "com.nvidia.gfnpc.mall"), name: "GeForce NOW",
            isSuppressing: false)
        #expect(Decision(mode: .automatic, app: geForceNow, rules: [rule], isOnWiFi: false)
            == Decision(reason: .excludedByRule(appName: "GeForce NOW")))
    }

    @Test func ruleTurnsOnNonGameApp() {
        let rule = AppRule(target: .macApp(bundleIdentifier: "com.apple.Safari"), name: "Safari")
        #expect(Decision(mode: .automatic, app: safari, rules: [rule], isOnWiFi: true)
            == Decision(reason: .rule(appName: "Safari")))
    }

    @Test func windowsRuleIgnoresBundledAppRunningAnExe() {
        let bundled = ForegroundApp(
            name: "Against the Storm", bundleIdentifier: "com.example.wrapper",
            executableName: "Against the Storm.exe", isGame: false)
        #expect(!Decision(mode: .automatic, app: bundled, rules: [stormRule], isOnWiFi: true).isSuppressed)
    }

    @Test func suppressionFollowsReason() {
        let suppressing: [Decision.Reason] = [.suppressedByMode, .rule(appName: "A"), .game(appName: "A")]
        let allowing: [Decision.Reason] = [.allowedByMode, .excludedByRule(appName: "A"), .notOnWiFi, .noTrigger]
        #expect(suppressing.allSatisfy { Decision(reason: $0).isSuppressed })
        #expect(allowing.allSatisfy { !Decision(reason: $0).isSuppressed })
    }

    @Test func noForegroundAppIsNotATrigger() {
        #expect(Decision(mode: .automatic, app: nil, rules: [], isOnWiFi: true)
            == Decision(reason: .noTrigger))
    }
}

@Suite struct AppTargetTests {
    @Test func targetFromRunningApps() {
        #expect(AppTarget(againstTheStorm) == .windowsApp(executableName: "against the storm.exe"))
        #expect(AppTarget(geForceNow) == .macApp(bundleIdentifier: "com.nvidia.gfnpc.mall"))
        let unbundled = ForegroundApp(name: "tool", bundleIdentifier: nil, executableName: "tool", isGame: false)
        #expect(AppTarget(unbundled) == nil)
    }

    @Test func switchForAppInFrontStartsFromDetectionAndSavesARule() {
        var rules: [AppRule] = []
        #expect(rules.suppresses(geForceNow))
        #expect(!rules.suppresses(againstTheStorm))

        rules.setSuppresses(false, for: geForceNow)
        #expect(!rules.suppresses(geForceNow))
        #expect(rules.count == 1)

        rules.setSuppresses(true, for: againstTheStorm)
        #expect(rules.suppresses(againstTheStorm))
        #expect(rules.last?.name == "Against the Storm")
    }

    @Test func runningAppsListFirstThenAlphabetical() {
        let rules = [
            AppRule(target: .macApp(bundleIdentifier: "com.valvesoftware.steam"), name: "Steam"),
            stormRule,
            AppRule(target: .macApp(bundleIdentifier: "com.nvidia.gfnpc.mall"), name: "GeForce NOW"),
            AppRule(target: .macApp(bundleIdentifier: "com.example.alto"), name: "Alto"),
        ]
        let running = Set([againstTheStorm, geForceNow].compactMap(AppTarget.init))
        let order = rules.displayOrder(running: running).map(\.name)
        #expect(order == ["Against the Storm", "GeForce NOW", "Alto", "Steam"])
    }

    @Test func addingRunningWindowsAppDropsExe() {
        var rules: [AppRule] = []
        rules.add(againstTheStorm)
        #expect(rules == [AppRule(target: .windowsApp(executableName: "Against the Storm.exe"), name: "Against the Storm")])
    }

    @Test func equalNamesKeepAStableOrder() {
        let first = AppRule(target: .macApp(bundleIdentifier: "com.example.a"), name: "Same")
        let second = AppRule(target: .macApp(bundleIdentifier: "com.example.b"), name: "Same")
        #expect([second, first].displayOrder(running: []) == [first, second])
        #expect([first, second].displayOrder(running: []) == [first, second])
    }

    @Test func windowsAppNameDropsExeInAnyCase() {
        #expect(AppTarget.windowsAppName("Game.EXE") == "Game")
        #expect(AppTarget.windowsAppName(".exe") == ".exe")
        #expect(AppTarget.windowsAppName("Game") == "Game")
    }

    @Test func addingExistingTargetReenablesInsteadOfDuplicating() {
        var rules = [AppRule(target: stormRule.target, name: "Against the Storm", isSuppressing: false)]
        rules.add(.windowsApp(executableName: "AGAINST THE STORM.exe"), name: "Against the Storm")
        #expect(rules.count == 1)
        #expect(rules[0].isSuppressing)
    }
}
