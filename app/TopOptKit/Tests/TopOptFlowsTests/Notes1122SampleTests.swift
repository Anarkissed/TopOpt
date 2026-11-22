// Notes1122SampleTests — ★ his iPad notes 2026-11-22 (img 2-4): the sample "couldn't be built" with no reason at 2 mm cells,
// built at 3.5 mm, and later built at 2 mm after all. "An error should always tell what's wrong and how to fix it. Always."
// "The settings range should always be consistent. The sample model should always be consistent."
// Found: the sample borrowed his part's Auto struts only once his part's lattice had been laid; before that it used its own
// (thicker), which 2 mm cells cannot print, and the engine's sentence went to the log alone.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes1122SampleTests: XCTestCase {

    private func organicProject() throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        var look = LatticeOrganicLook(); look.mode = .traced; look.lookPercent = 5
        p.lattice.organicLook = look
        XCTAssertNotNil(p.importedFile, "premise: the part has its model file")
        return p
    }

    /// ★ The Lattice page's Auto numbers are measured for his part when it opens — no lay, no stress — so the fields and the
    /// sample read the same numbers whether or not a lattice was laid. RED CONTROL: before the page asks, there are none (what
    /// the sample used to build without).
    func testThePagesAutoNumbersAreMeasuredWithoutALay() async throws {
        let p = try organicProject()
        let preview = LatticeLayoutPreview()
        XCTAssertNil(preview.organicAutoLimits, "RED CONTROL: no numbers before the page asks (the sample built with its own)")
        let lays = LatticeLayoutPreview.laysStarted
        preview.measureLimits(project: p)
        XCTAssertTrue(preview.measuringLimits, "★ measuring: the sample waits")
        let end = Date().addingTimeInterval(300)
        while preview.measuringLimits, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(preview.measuringLimits, "measured within 5 min")
        let l = try XCTUnwrap(preview.organicAutoLimits, "★ his part's Auto numbers")
        XCTAssertTrue(l.measured, "★ measured by the engine")
        XCTAssertGreaterThan(l.strutUpperMM, 0, "★ the strut range is known (the boxes showed –)")
        XCTAssertEqual(LatticeLayoutPreview.laysStarted, lays, "★ no lay: the numbers come before any lattice")
        print("NOTES1122: part struts \(l.strutLowerMM)-\(l.strutUpperMM) mm, cells \(l.cellLowerMM)-\(l.cellUpperMM) mm")
        // asked again with nothing changed: the same numbers, nothing measured
        preview.measureLimits(project: p)
        XCTAssertFalse(preview.measuringLimits, "★ cheap when measured already")
        XCTAssertEqual(preview.organicAutoLimits, l)
    }

    /// ★ The wizard's sample waits while the part's numbers are measured (never one sample with its own struts, then another
    /// with his part's), and the page asks for them as it opens.
    func testTheSampleWaitsForThePartsNumbers() throws {
        let wiz = try FlexibleSource.code("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains("else { i.partStrutsPending = organicMeasuring }"), "★ pending while measuring")
        XCTAssertTrue(wiz.contains("measureOrganic?()"), "★ the page measures as it opens")
        let sample = try FlexibleSource.code("LatticeSampleView.swift")
        XCTAssertTrue(sample.contains("guard !i.partStrutsPending else { return }"), "★ no build while pending")
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains(".organicMeasuring(newEngine.measuringLimits) { newEngine.measureLimits(project: project) }"),
                      "★ the page's numbers come from the preview's measure")
    }

    /// ★ "An error should always tell what's wrong and how to fix it": 2 mm cells with 1.35 mm struts on the sample cube — the
    /// engine's sentence (which setting, what it allows) and the other way out. RED CONTROL: the old pop-up's words say neither.
    func testATooSmallCellSaysWhatIsWrongAndHowToFixIt() async throws {
        let body = try TopOptKit.latticeSampleBody(cube: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes1122-cube-\(UUID().uuidString).stl")
        try MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try await LatticeLayoutSession.open(path: url.path)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.beadMM = 0.45
        s.minStrutLines = 2
        let b = try XCTUnwrap(LatticeLayoutPreview.box(body.vertices))
        var r = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
        r.zone = .init(kind: .box, centre: SIMD3<Double>((b.lo + b.hi) / 2),
                       axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], half: SIMD3<Double>((b.hi - b.lo) / 2) + 1)
        r.weave = true
        s.regions = [r]
        var ask = LatticeLayoutSession.Organic()
        ask.spacingMM = 0; ask.spacingMinMM = 2; ask.spacingMaxMM = 6
        ask.widthMM = 1.35; ask.widthHeavyMM = 2.7
        let refused = try await session.validateOrganic(s, groups: [.init(regions: [1], ask: ask)])
        let cell = try XCTUnwrap(refused.first { $0.setting == "spacing_min_mm" }, "premise: 2 mm is refused: \(refused.map(\.text))")
        let line = LatticeRefusalWords.line(cell)
        print("NOTES1122: \(line)")
        XCTAssertTrue(line.hasPrefix("Cell size"), "★ which setting: \(line)")
        let floor = try XCTUnwrap(cell.allowedMin)
        let up = StrengthCheckDocs.number(LatticeRefusalWords.upToHundredth(floor))
        XCTAssertTrue(line.contains("Raise it to \(up) mm, or make the struts thinner."), "★ how: \(line)")
        XCTAssertTrue(line.contains("at least \(up) mm"), "★ the same number twice (the engine's rounding): \(line)")
        XCTAssertEqual(LatticeRefusalWords.lines(refused)?.hasPrefix(LatticeRefusalWords.line(refused[0])), true)
        // RED CONTROL: the old pop-up said neither what nor how
        let old = "These settings didn’t make a sample. Try changing one of them; if it keeps happening, tell us."
        XCTAssertFalse(old.contains("Cell size") || old.contains("Raise it"), "RED CONTROL: the old words named nothing")
        XCTAssertFalse(LatticeSampleView.organicFailedText.contains("These settings didn"), "★ the old words are gone")
    }
}
