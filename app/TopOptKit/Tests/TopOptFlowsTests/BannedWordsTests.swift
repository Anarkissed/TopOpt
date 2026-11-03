// BannedWordsTests — B2, U4 (approved design 2026-11-02, design-system §3 and §6: "no screen string in a banned list").
//
// One word per thing. Every string literal the app can put on the screen (TopOptFlows' sources, minus logs, diagnostics,
// identifiers and comments) is checked against the words the vocabulary table rules out. (The offscreen window's
// accessibility tree carries only a few menu values, so the strings are read where they are written.)
#if canImport(AppKit)
import XCTest
@testable import TopOptFlows

final class BannedWordsTests: XCTestCase {

    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/TopOptFlows")

    /// A banned word, the word that replaces it, and the batch whose screens dropped it. Each batch adds the words its rebuilt
    /// screens drop; B10's sweep holds the whole §3 list.
    struct Banned { let pattern: String; let use: String; let batch: String }
    static let banned: [Banned] = [
        Banned(pattern: #"\b[Dd]esign primitives\b"#, use: "Allow growth here", batch: "B2"),
        Banned(pattern: #"\bVersion (\d|\\\()"#, use: "a · Just safe, b · +10 %, c · +20 %", batch: "B2"),
    ]

    /// Lines that never reach the screen: logs, diagnostics, identifiers, assertions.
    static let offScreen = try! NSRegularExpression(pattern:
        #"NSLog|print\(|diag\(|DIAG|signpost|emitEvent|os_log|Logger|accessibilityIdentifier|fatalError|assert|precondition"#)
    static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)

    /// The banned words in `lines` ("file:line: the string · the word to use").
    static func scan(_ lines: [String], file: String) -> [String] {
        var out: [String] = []
        for (n, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            let whole = NSRange(line.startIndex..., in: line)
            guard !t.hasPrefix("//"), offScreen.firstMatch(in: line, range: whole) == nil else { continue }
            for m in literal.matches(in: line, range: whole) {
                guard let r = Range(m.range(at: 1), in: line) else { continue }
                let s = String(line[r])
                for b in banned where s.range(of: b.pattern, options: .regularExpression) != nil {
                    out.append("\(file):\(n + 1): \"\(s)\" · use \(b.use) (\(b.batch))")
                }
            }
        }
        return out
    }

    func testTheScannerCatchesABannedWord() {
        // ★ RED CONTROL: a planted screen string is caught; the same words in a log line are not
        XCTAssertEqual(Self.scan(["        Text(\"Version 2 · +10%\")"], file: "x").count, 1)
        XCTAssertEqual(Self.scan(["        viewModeButton(\"cube\", label: \"Design primitives\", on: x)"], file: "x").count, 1)
        XCTAssertEqual(Self.scan(["        NSLog(\"Version 2 done\")", "        // \"Design primitives\""], file: "x"), [])
    }

    func testNoScreenStringUsesABannedWord() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 100, "the app's sources are where they should be")
        var hits: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            hits += Self.scan(text.components(separatedBy: "\n"), file: f.lastPathComponent)
        }
        XCTAssertTrue(hits.isEmpty, "★ banned words on the screen:\n" + hits.joined(separator: "\n"))
    }
}
#endif
