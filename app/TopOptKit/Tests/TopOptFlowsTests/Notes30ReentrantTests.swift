// Notes30ReentrantTests — ★ notes30 X2, the item X1 found: Re-entrant is selectable on the Lattice page (his screenshot, Manual)
// and the Settings sample sat at "Building the sample…"; CoreBuildIdentityTests reads core's OLD catalog
// (why("reentrant") = "Not buildable or strength-checked yet"). Measured on organic-1 (core 73886b47539b): core's NEW engine —
// the one the Lattice stage and its sample lay with — builds Re-entrant (its canonical cell, 17 struts; touch 1/3), so it stays
// selectable where the engine lays it: Aesthetic. Structural keeps it greyed with core's own reason ("Aesthetic only"). Its
// sample lays (the page's own plan, Auto and Manual settings). The lookups it makes that core refuses are the OLD run's
// per-type numbers (lattice_limits, the measured strut table: Re-entrant has none); each answers with core's reason and the
// caller falls back, and since X1 (ed69b2d8) none writes a log line — the lines that, under Xcode's log redirect, blocked the
// main thread with "Building the sample…" up (X1's crash). No lookup is changed here: none of them stops the sample.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes30ReentrantTests: XCTestCase {
    override func tearDown() { TopOptKit.setControlLogEveryRefusal(false); super.tearDown() }

    /// ★ Core builds Re-entrant on the new engine: offered in Aesthetic, greyed in Structural with core's reason; the Lattice
    /// page's own sample of it lays — on Auto's settings and on Manual ones (a typed cell, a uniform density, Allow quilt on) —
    /// and writes no log line. RED CONTROL (X1's `setControlLogEveryRefusal`): the same sample, every refusal logged — its
    /// lookups ARE refused ones (the old run's numbers), which is what blocked the page under Xcode.
    func testCoreBuildsReentrantAndItsSampleLays() async throws {
        let f = LatticeLayoutSession.typeFacts("reentrant")
        print("NOTES30-X2 REENTRANT facts: lays \(f.lays), open look \(f.openLook), touch \(f.touch), s \(f.s), struts \(f.struts.count), "
              + "Structural: '\(f.structuralRefusal ?? "-")'")
        print("NOTES30-X2 REENTRANT old run's limits: \(TopOptKit.latticeLimits(topology: "reentrant"))")
        XCTAssertTrue(f.lays, "★ core's new engine builds Re-entrant")
        XCTAssertNotNil(LatticeType.named("reentrant"), "★ its cell and law from the engine")
        let ae = try XCTUnwrap(LatticeTypeCatalog.layoutEntriesFromCore(structural: false).first { $0.id == "reentrant" })
        XCTAssertTrue(ae.offered, "★ Aesthetic: offered")
        let st = try XCTUnwrap(LatticeTypeCatalog.layoutEntriesFromCore(structural: true).first { $0.id == "reentrant" })
        XCTAssertFalse(st.offered, "★ Structural: greyed")
        XCTAssertEqual(LatticeTypeCatalog.caption(st), LatticeTypeCatalog.aestheticOnlyCaption, "★ its five words")
        XCTAssertNotNil(st.reason, "★ its (i): core's reason")
        XCTAssertFalse(TopOptKit.latticeLimits(topology: "reentrant").certifiable, "the old run's numbers: none for it")

        var auto = LatticeSettings()
        auto.chooseLatticeType(.aesthetic)
        auto.topologyID = "reentrant"
        var manual = auto
        manual.cellSizeMode = .fixed; manual.cellMM = 6
        manual.densityMode = .uniform; manual.maxRelativeDensity = 0.3
        manual.allowQuilt = true
        for (name, l) in [("Auto", auto), ("Manual", manual)] {
            let plan = LatticeSampleLay.page(l, lineWidthMM: 0.45, wallRingMM: 0.9)
            let before = TopOptKit.bridgeLogLineCount
            let t0 = Date()
            let made = try await LatticeSampleLay.lay(plan, cube: true)
            let lines = TopOptKit.bridgeLogLineCount - before
            print("NOTES30-X2 REENTRANT sample (\(name)): laid \(made.laidAnything), \(made.struts) struts in "
                  + String(format: "%.2f s", Date().timeIntervalSince(t0)) + ", \(lines) log lines")
            XCTAssertTrue(made.laidAnything, "★ \(name): the sample lays")
            XCTAssertGreaterThan(made.struts, 100, "★ \(name): a lattice of struts")
            XCTAssertEqual(lines, 0, "★ \(name): no log line from its lookups")
        }
        // RED CONTROL: release 21's bridge — every refusal logged
        TopOptKit.setControlLogEveryRefusal(true)
        let before = TopOptKit.bridgeLogLineCount
        _ = try await LatticeSampleLay.lay(LatticeSampleLay.page(auto, lineWidthMM: 0.45, wallRingMM: 0.9), cube: true)
        XCTAssertGreaterThan(TopOptKit.bridgeLogLineCount - before, 0, "RED CONTROL: its lookups are refused ones, each logged")
    }
}
#endif
