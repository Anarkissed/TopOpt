import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ MAINTAINER, 2026-10-03, RULING 6: "Default Grade and Stepped previews carry one plain line
/// saying the run currently builds core's own (coarser) layout. Show it only while the plan isn't
/// sent." The line and the job read ONE predicate, so it cannot show while a plan rides, nor hide
/// while one does not.
final class LatticePlanNotSentLineTests: XCTestCase {

    private func spec(_ algorithm: String) -> LatticeSpec {
        var s = LatticeSpec(topologyID: "octet", cellMM: 12, strutRadiusMM: 0.5,
                            generateRelativeDensity: 0.3, minRelativeDensity: 0.1, maxRelativeDensity: 0.5)
        s.algorithm = algorithm
        s.steppedCells = [LatticeSteppedCellWire(regionID: 1, originMM: .zero, sizeMM: 12)]
        return s
    }

    private func banner(_ algorithm: String, label: String = "octet · 8.00 mm",
                        enabled: Bool = false, wired: Bool = true) throws -> LatticePreviewBanner {
        try XCTUnwrap(LatticePreviewBanner.make(
            previewOn: true, hasModel: true,
            scene: LatticePreviewSummaryValues(interiorVoxelCount: 1, previewLabel: label,
                                               algorithmName: algorithm),
            plansWired: wired, plansEnabled: enabled))
    }

    /// The line's condition IS the job's: shown ⇔ a plan-preview algorithm whose job would
    /// carry no plan — for every algorithm × wired × enabled.
    func testTheLineIsExactlyWhenTheJobCarriesNoPlan() {
        for a in ["doubled", "stepped", "organic", "", "bogus"] {
            for wired in [false, true] {
                for enabled in [false, true] {
                    let carries = LatticeSteppedCellWire.blockValue(for: spec(a), wired: wired, enabled: enabled) != nil
                    XCTAssertEqual(
                        LatticeSteppedCellWire.runBuildsCoresOwnLayout(algorithm: a, wired: wired, enabled: enabled),
                        LatticeSteppedCellWire.planPreviewAlgorithms.contains(a) && !carries,
                        "\(a) wired \(wired) enabled \(enabled)")
                }
            }
        }
    }

    /// Production: plans are OFF, so both plan previews carry the line; Stepped keeps it even
    /// with the switch on (it never sends a plan); organic and an unstated algorithm never do.
    func testProductionCarriesTheLineOnDefaultGradeAndStepped() {
        XCTAssertFalse(LatticeSteppedCellWire.defaultGradePlansEnabled)
        let wired = TopOptKit.steppedCellsWired
        XCTAssertTrue(LatticeSteppedCellWire.runBuildsCoresOwnLayout(algorithm: "doubled", wired: wired))
        XCTAssertTrue(LatticeSteppedCellWire.runBuildsCoresOwnLayout(algorithm: "stepped", wired: wired))
        XCTAssertTrue(LatticeSteppedCellWire.runBuildsCoresOwnLayout(algorithm: "stepped", wired: true, enabled: true),
                      "★ Stepped never sends a plan")
        XCTAssertFalse(LatticeSteppedCellWire.runBuildsCoresOwnLayout(algorithm: "organic", wired: wired))
        XCTAssertFalse(LatticeSteppedCellWire.runBuildsCoresOwnLayout(algorithm: "", wired: wired))
        XCTAssertEqual(LatticeSteppedCellWire.planPreviewAlgorithms, WorkspacePlaceholder.perRegionCellAlgorithms,
                       "the line's algorithms are the per-region bake's")
    }

    /// The banner: one short plain caption, the full sentence behind the (i), and the
    /// controls — the switch on, organic, unstated, and a mismatch, which still wins.
    func testTheBannerSaysItInOneLine() throws {
        for a in ["doubled", "stepped"] {
            let b = try banner(a)
            XCTAssertEqual(b.caption, LatticePreviewBanner.planNotSentCaption, a)
            XCTAssertLessThanOrEqual(b.caption.count, 34, "one line in the Selections column")
            XCTAssertFalse(b.caption.contains("—")); XCTAssertFalse(b.caption.contains("\n"))
            XCTAssertTrue(b.text.contains(LatticePreviewBanner.planNotSentSentence), a)
            XCTAssertTrue(b.text.hasPrefix("octet · 8.00 mm"), "the preview's own label stays first")
        }
        // CONTROLS
        let on = try banner("doubled", enabled: true)
        XCTAssertEqual(on.caption, "Lattice preview · not the export", "★ the plan rides: no line")
        XCTAssertFalse(on.text.contains(LatticePreviewBanner.planNotSentSentence))
        XCTAssertEqual(try banner("stepped", enabled: true).caption, LatticePreviewBanner.planNotSentCaption)
        for a in ["organic", ""] {
            XCTAssertFalse(try banner(a).text.contains(LatticePreviewBanner.planNotSentSentence), a)
        }
        XCTAssertEqual(try banner("doubled", label: "★ PREVIEW DOES NOT MATCH THE RUN — x  octet").caption,
                       "★ Preview differs from run", "a mismatch still wins")
    }

    /// The call site passes no seam: production reads core's probe and the switch.
    func testTheNoticeUsesTheProductionSwitch() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let ws = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"),
                            encoding: .utf8)
        let call = try XCTUnwrap(ws.range(of: "LatticePreviewBanner.make(previewOn: showStrutPreview,"))
        let window = String(ws[call.lowerBound...].prefix(300))
        XCTAssertFalse(window.contains("plansEnabled:") || window.contains("plansWired:"))
    }
}
