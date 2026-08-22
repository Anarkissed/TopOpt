// LatticeEmptyIsExplainedTests — ★★ AN EMPTY REGION IS A RESULT, NOT AN ABSENCE
// (maintainer, 2026-08-20: "instead of showing an empty fucking wall we should have a
// way to recognize that it will happen and create a pop-up saying 'wall too thin to
// use default grade' … never leaving the Lattice Setting area").
//
// Measured on his own part: a swept 2–4 mm window returns ZERO cells. At 2 mm his
// density's strut falls under the bead so core must coarsen it; 4 mm needs a 20 mm
// member and his measures 13.9. Caught between "too fine to print" and "too coarse to
// certify", every cell falls back to solid — core behaving correctly, and the preview
// rendering a blank wall as though something had broken.
//
// ★ THE TWO CAUSES HAVE OPPOSITE REMEDIES — a coarser cell, or a thicker member — so
// saying WHICH is the entire value of the message.

import XCTest
import Metal
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeEmptyIsExplainedTests: XCTestCase {

    private func hisScene() throws -> LatticeSDFScene {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 13
        return LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                               regions: [region], whenEmpty: .latticeNothing)
    }

    /// ★ DRAWING SOMETHING MEANS SAYING NOTHING — the negative control first, so a
    /// message that fires always cannot pass as a diagnosis.
    func testAWorkingCellExplainsNothing() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = LatticeSDFRenderer(device: device) else { throw XCTSkip("no GPU") }
        let scene = try hisScene()
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no widths")
        r.setScene(scene)
        r.lineWidthMM = 0.42
        r.params = LatticeProxyParams(latticeID: "octet", cellMM: 2.0,
                                      minRelativeDensity: 0.25, maxRelativeDensity: 0.55)
        XCTAssertGreaterThan((r.cellField?.field.values ?? []).filter { $0 >= 0 }.count, 0,
                             "positive control: 2 mm draws on this region")
        XCTAssertNil(r.emptyReason, "★ nothing is wrong, so nothing is said")
    }

    /// ★ AND WHEN THE MEMBERS ARE THE REASON, IT SAYS MEMBERS — not "no lattice".
    /// A 4 mm cell needs 20 mm here and the material is 13.9 mm.
    func testTooCoarseToCertifySaysSo() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = LatticeSDFRenderer(device: device) else { throw XCTSkip("no GPU") }
        let scene = try hisScene()
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no widths")
        r.setScene(scene)
        r.lineWidthMM = 0.42
        // ★ DERIVED, so the bar survives the member being measured on the PART and the
        // floor following the stage MODE — both of which moved the widths this used to
        // hard-code. What is under test is that an empty region EXPLAINS ITSELF, and
        // names the members rather than printability.
        let occ = scene.occupancy
        let widest = (0..<occ.count).filter { occ.values[$0] > 0.5 }
            .map { scene.memberThicknessMM[$0] }
            .filter { $0.isFinite && $0 > 0 }.max() ?? 0
        XCTAssertGreaterThan(widest, 0, "positive control: measured material")
        let tooCoarse = 1.2 * widest / Swift.max(scene.minCellsPerMember, 1)
        r.params = LatticeProxyParams(latticeID: "octet", cellMM: tooCoarse,
                                      minRelativeDensity: 0.25, maxRelativeDensity: 0.55)
        XCTAssertEqual((r.cellField?.field.values ?? []).filter { $0 >= 0 }.count, 0,
                       "positive control: nothing here can hold a \(tooCoarse) mm cell")
        let why = try XCTUnwrap(r.emptyReason, "★ an empty region must explain itself")
        XCTAssertTrue(why.contains("too thin"),
                      "★ it must name the MEMBERS, whose remedy is a FINER cell — the "
                      + "opposite of the printability remedy: \(why)")
        XCTAssertTrue(why.contains("cells"), "★ and say how many it needs: \(why)")
        print("EMPTY(4mm): \(why)")
    }

    /// ★ AND WHEN THE NOZZLE IS THE REASON, IT SAYS NOZZLE. A 0.35 mm cell cannot
    /// print at ANY certifiable density against a 0.42 mm bead.
    func testTooFineToPrintSaysSo() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = LatticeSDFRenderer(device: device) else { throw XCTSkip("no GPU") }
        let scene = try hisScene()
        r.setScene(scene)
        r.lineWidthMM = 0.42
        r.params = LatticeProxyParams(latticeID: "octet", cellMM: 0.35,
                                      minRelativeDensity: 0.25, maxRelativeDensity: 0.55)
        try XCTSkipUnless(r.cellUnprintable, "fixture must be genuinely unprintable")
        let why = try XCTUnwrap(r.emptyReason)
        XCTAssertTrue(why.contains("coarser"),
                      "★ the remedy here is a COARSER cell, and the message must say "
                      + "so rather than sending him to thicken a wall: \(why)")
        print("EMPTY(0.35mm): \(why)")
    }
}
