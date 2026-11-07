import Foundation
import GuardPolicy
import Testing

@Suite struct StoredRulesTests {
    private let steam = AppRule(target: .macApp(bundleIdentifier: "com.valvesoftware.steam"), name: "Steam")
    private let storm = AppRule(
        target: .windowsApp(executableName: "Against the Storm.exe"), name: "Against the Storm",
        isSuppressing: false, fileURL: URL(filePath: "/Users/Shared/Against the Storm.exe"))

    @Test func roundTrip() throws {
        let stored = try [steam, storm].encoded()
        let decoded = [AppRule].decoding(stored)
        #expect(decoded.rules == [steam, storm])
        #expect(decoded.unreadableCount == 0)
    }

    @Test func oneBadEntryKeepsTheOthers() throws {
        let good = String(decoding: try [steam].encoded(), as: UTF8.self).dropFirst().dropLast()
        let data = Data("[{\"name\":\"Broken\"},\(good)]".utf8)
        let decoded = [AppRule].decoding(data)
        #expect(decoded.rules == [steam])
        #expect(decoded.unreadableCount == 1)
    }

    @Test func duplicateTargetsKeepTheFirst() throws {
        var duplicate = steam
        duplicate.isSuppressing = false
        let decoded = [AppRule].decoding(try [steam, duplicate].encoded())
        #expect(decoded.rules == [steam])
        #expect(decoded.unreadableCount == 0)
    }

    @Test func emptyList() {
        let decoded = [AppRule].decoding(Data("[]".utf8))
        #expect(decoded.rules.isEmpty)
        #expect(decoded.unreadableCount == 0)
    }

    @Test func notAListAtAll() {
        let decoded = [AppRule].decoding(Data("not json".utf8))
        #expect(decoded.rules.isEmpty)
        #expect(decoded.unreadableCount == 1)
    }
}
