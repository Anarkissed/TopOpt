// FlexibleSquishCopyTests — round 7, batch R7-D1, item 5. His answer (2026-10-14, on the mockup's open questions): "The
// Settings page is renamed 'Squish': [Lattice | Squish] under ● Flexible." So no user-facing word in the Flexible copy names
// that page "Settings" any more. The accessibility ids stay (flexible-settings-*), and the words "settings" for HIS settings
// (a filament's, a print's) are not the page. RED CONTROL inside: today's [Prisms] (i) text ("…as you set it in Settings…").
import XCTest
@testable import TopOptFlows

final class FlexibleSquishCopyTests: XCTestCase {

    /// The Flexible copy tables and the places that put words on the screen.
    static let files = ["FlexibleRowCopy.swift", "FlexibleRowCopy+Edges.swift", "FlexibleRowCopy+FacePrisms.swift",
                        "FlexibleRowCopy+Sections.swift", "FlexibleRowCopy+Views.swift", "FlexibleRowCopy+X1.swift",
                        "FlexibleReadiness.swift", "FlexibleLatticeUnder.swift", "FlexibleLatticeUnderViews.swift",
                        "FlexibleStageChrome.swift", "FlexibleCoreHold.swift", "FlexibleCoreRun.swift",
                        "FlexibleMainLatticeView.swift", "FlexibleSquishFollowUps.swift", "FlexibleSettingsReset.swift",
                        "FlexibleNoFacePrismFlow.swift", "FlexibleExportSheet.swift", "FlexibleExportRows.swift",
                        "FlexibleStageCapsule.swift", "FlexibleCornerPair.swift", "FlexibleSetupTray.swift",
                        "FlexibleLatticeButton.swift", "FlexibleLatticeCard.swift", "FlexibleBlockerCallout.swift",
                        "FlexibleMainStatusPill.swift", "FlexibleR7ReviewFixes.swift"]

    /// The string literals of a source (comments stripped) that name the page "Settings" (a whole word, capitalised): ids
    /// and storage keys are not words he reads.
    static func offenders(_ code: String) -> [String] {
        let lit = try! NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")
        let word = try! NSRegularExpression(pattern: "\\bSettings\\b")
        let ns = code as NSString
        return lit.matches(in: code, range: NSRange(location: 0, length: ns.length)).compactMap { m -> String? in
            let s = ns.substring(with: m.range(at: 1))
            if s.hasPrefix("flexible-") || s.hasPrefix("flexible.") || s.contains("Settings.swift") { return nil }
            return word.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) == nil ? nil : s
        }
    }

    func testNoUserFacingSettingsNamesTheFlexiblePage() throws {
        var found: [String] = []
        for f in Self.files {
            guard FileManager.default.fileExists(atPath: FlexibleSource.url(f).path) else { continue }
            found += Self.offenders(try FlexibleSource.code(f)).map { "\(f): \($0.prefix(90))" }
        }
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
        // the copy tables' live values
        XCTAssertFalse(FlexibleRowCopy.Info.mainPrisms.contains("Settings"), "the [Prisms] (i) names the Squish page")
        XCTAssertTrue(FlexibleRowCopy.Info.mainPrisms.contains("Squish page"))
        // RED CONTROL: today's (i) text is caught by the same check
        let today = "let x = \"Each pressed face's squish as you set it in Settings, drawn as a faint prism\""
        XCTAssertEqual(Self.offenders(today).count, 1, "★ RED CONTROL: 'as you set it in Settings' is caught")
    }

    /// The ids stay: the hosted tests and his VoiceOver landmarks find the page by them.
    func testTheAccessibilityIdsStay() throws {
        let page = try FlexibleSource.text("FlexibleStagePage.swift") + (try FlexibleSource.text("FlexibleSettingsPanel.swift"))
        XCTAssertTrue(page.contains("\"flexible-settings-legend-tab\""))
        XCTAssertTrue(page.contains("flexible-exit"))
    }
}
