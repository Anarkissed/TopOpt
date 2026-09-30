import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ RULING 3 (maintainer, 2026-09-30): OLD RETAINED RUNS. A variant whose run froze a wall at
/// another depth than the wall has today is refused by core's depth tie — face_id kept, the tie
/// not dodged. The app asks core's OWN parser where it already asks about the variant's job, and
/// says it before any tap, in his words, with one tap to Optimize again. Never re-derived in Swift.
@MainActor
final class LatticeOldRetainedRunTests: XCTestCase {

    private func coreErrors(_ p: ProjectModel, retained: Data) throws -> [(String, String?)] {
        try VariantFacePrismFixture.variantDocuments(p, retained: retained).map { ($0.0, TopOptKit.jobSchemaError($0.1)) }
    }
    private func sentence(_ p: ProjectModel, _ coreError: String) -> String {
        p.variantJobCoreRefusal(coreError: coreError, regions: p.variantLatticeJobRegions().regions)
    }

    /// The bare form at the global depth: core refuses every variant document, and his sentence
    /// names the wall as its Selections row does, with core's own numbers.
    func testAnOldRetainedRunIsRefusedByCoreInHisWords() throws {
        for depth in [5.0, -1.0] {        // -1 omits the key: core's own 5 mm default
            let (p, _, _) = VariantFacePrismFixture.project(organic: true)
            let run1 = try XCTUnwrap(p.latticeJobRegions().regions.first { $0.rawFaceID == 1 }?.faceID)
            let old = try VariantFacePrismFixture.original(bareProtection: [run1], depthMM: depth)
            // control: it really is the old shape
            let loads = try XCTUnwrap((try JSONSerialization.jsonObject(with: old) as? [String: Any])?["loads"] as? [String: Any])
            XCTAssertEqual(loads["face_protections"] as? [Int], [run1], "control: bare ids")
            XCTAssertEqual(loads["face_protection_depth_mm"] as? Double, depth > 0 ? depth : nil)
            let errors = try coreErrors(p, retained: old)
            XCTAssertEqual(errors.count, 3, "run, forecast and Check sizes")
            for (label, why) in errors {
                let e = try XCTUnwrap(why, "★ \(label): core refuses it")
                XCTAssertTrue(e.contains("the protection is 5.000000 mm and the lattice region is 20.000000 mm"), e)
                XCTAssertEqual(sentence(p, e),
                               "This result was optimized with a 5 mm protected skin under Face 1, but the wall is 20 mm deep. "
                               + "Optimize again with this wall, or set the wall to 5 mm.", "★ \(label): his words")
            }
        }
    }

    /// The object form (a newer run) refuses too when the wall moved after the run — and the
    /// sentence carries core's exact numbers.
    func testANewerRunRefusesWhenTheWallMovedAfterIt() throws {
        let (p, gid, _) = VariantFacePrismFixture.project()
        let retained = try VariantFacePrismFixture.original(protecting: p)      // face 1 frozen at 20 mm
        p.writeLatticeDepthMM(.face(group: gid, face: 1), mm: 12.5)
        let e = try XCTUnwrap(try coreErrors(p, retained: retained).first?.1)
        XCTAssertEqual(sentence(p, e),
                       "This result was optimized with a 20 mm protected skin under Face 1, but the wall is 12.5 mm deep. "
                       + "Optimize again with this wall, or set the wall to 20 mm.")
        // ★ the remedy is true: the wall set to the skin's depth, core accepts every document
        p.writeLatticeDepthMM(.face(group: gid, face: 1), mm: 20)
        XCTAssertTrue(try coreErrors(p, retained: retained).allSatisfy { $0.1 == nil }, "★ set to 20 mm ⇒ accepted")
    }

    /// A wall with an in-plane expand: its slab reaches depth + expand, so the depth to SET is the
    /// skin less the expand — and that remedy is true.
    func testAnExpandedWallsRemedySubtractsItsExpand() throws {
        let (p, gid, _) = VariantFacePrismFixture.project()
        p.writeLatticeExpandMM(.face(group: gid, face: 1), mm: 2)
        let old = try VariantFacePrismFixture.original(bareProtection: [1], depthMM: 5)
        let e = try XCTUnwrap(try coreErrors(p, retained: old).first?.1)
        XCTAssertEqual(sentence(p, e),
                       "This result was optimized with a 5 mm protected skin under Face 1, but the wall is 22 mm deep. "
                       + "Optimize again with this wall, or set the wall to 3 mm.")
        p.writeLatticeDepthMM(.face(group: gid, face: 1), mm: 3)
        XCTAssertTrue(try coreErrors(p, retained: old).allSatisfy { $0.1 == nil }, "★ 3 mm + its 2 mm expand = the 5 mm skin")
    }

    /// The wall is named as its Selections row names it: a face region's member names the region.
    func testTheWallIsNamedAsItsRowNamesIt() throws {
        let (p, _, rid) = VariantFacePrismFixture.project()
        let old = try VariantFacePrismFixture.original(bareProtection: [Int(p.runFaceID(3))], depthMM: 5)
        let e = try XCTUnwrap(try coreErrors(p, retained: old).first?.1)
        XCTAssertTrue(sentence(p, e).contains("under \(p.latticeRegionName(rid)),"), sentence(p, e))
        XCTAssertEqual(p.latticeRegionName(rid), "wall")
    }

    /// The tie is core's: the same refused document with face_id stripped is accepted — so there
    /// is nothing for the app to say, and nothing is re-derived.
    func testTheRefusalIsCoresNotTheApps() throws {
        let (p, _, _) = VariantFacePrismFixture.project()
        let old = try VariantFacePrismFixture.original(bareProtection: [1], depthMM: 5)
        let doc = try XCTUnwrap(try VariantFacePrismFixture.variantDocuments(p, retained: old).first?.1)
        XCTAssertNotNil(TopOptKit.jobSchemaError(doc), "control: refused")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: doc) as? [String: Any])
        var lat = try XCTUnwrap(obj["lattice"] as? [String: Any])
        lat["regions"] = (lat["regions"] as? [[String: Any]] ?? []).map { r -> [String: Any] in var r = r; r["face_id"] = nil; return r }
        obj["lattice"] = lat
        XCTAssertNil(TopOptKit.jobSchemaError(try JSONSerialization.data(withJSONObject: obj)), "★ the verdict is core's tie")
        // the words come from core's message alone
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let session = try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/LatticeVariantSession.swift"), encoding: .utf8)
        let tie = String(session[session.range(of: "public enum LatticeVariantProtectionTie")!.lowerBound...])
        XCTAssertFalse(tie.contains("LatticeSlabDepth") || tie.contains("faceProtectionSpecs"), "never re-derived")
    }

    func testTheParserReadsCoresOwnFormat() {
        let msg = "job.json: face 23 is BOTH protected and a lattice region, at two different depths: the protection is "
            + "12.500000 mm and the lattice region is 0.100000 mm. They are one slab — the depth the face is held to IS the depth"
        let m = LatticeVariantProtectionTie.parse(coreError: msg)
        XCTAssertEqual(m, .init(faceID: 23, protectionMM: 12.5, wallMM: 0.1))
        XCTAssertNil(LatticeVariantProtectionTie.parse(coreError: "job.json: unknown key \"x\""))
        XCTAssertEqual(LatticeVariantProtectionTie.coreWords("job.json: unknown key \"x\""), "unknown key \"x\"")
        XCTAssertEqual(LatticeVariantProtectionTie.mm(5), "5")
        XCTAssertEqual(LatticeVariantProtectionTie.mm(12.5), "12.5")
        XCTAssertEqual(LatticeVariantProtectionTie.mm(24.15), "24.15")
    }

    /// Where it shows: the banner (before any tap, one tap to Optimize again), the disabled
    /// "Lattice this variant", the drawer — and the forecast is never sent.
    func testItIsSaidBeforeAnyTapWithOneTapToOptimizeAgain() throws {
        let s = "This result was optimized with a 5 mm protected skin under Face 1, but the wall is 20 mm deep. "
            + "Optimize again with this wall, or set the wall to 5 mm."
        let b = try XCTUnwrap(LatticePageBanner.derive(simPhase: .idle, simStale: false, optimizing: false, runFailure: nil,
                                                       variantJobRefusal: s, optimizeEnabled: true))
        XCTAssertEqual(b.kind, .variantJobRefused)
        XCTAssertEqual(b.body, s)
        XCTAssertEqual(b.actionLabel, "Optimize again", "★ the one tap")
        XCTAssertNil(LatticePageBanner.derive(simPhase: .idle, simStale: false, optimizing: false, runFailure: nil,
                                              variantJobRefusal: s, optimizeEnabled: false)?.actionLabel,
                     "no tap when Optimize itself is closed")
        XCTAssertEqual(LatticePageBanner.derive(simPhase: .running, simStale: false, optimizing: false, runFailure: nil,
                                                variantJobRefusal: s, optimizeEnabled: true)?.kind, .simRunning,
                       "a running sim keeps its Cancel")
        XCTAssertNil(LatticePageBanner.derive(simPhase: .idle, simStale: false, optimizing: false, runFailure: nil),
                     "control: nothing to say")
        let panel = LatticeForecastPanel.compute(state: .idle, describesCurrentJob: false, coreRefusal: s)
        XCTAssertEqual(panel.placeholder, s); XCTAssertTrue(panel.warn)
        // the wiring
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
        }
        let ws = try src("WorkspacePlaceholder.swift"), page = try src("LatticePage.swift")
        XCTAssertTrue(ws.contains("let coreRefusal = TopOptKit.jobSchemaError(json).map {"), "core's own parser, on the one document")
        XCTAssertTrue(ws.contains("if job.coreRefusal == nil { pass.forecastJob = job.json }"), "★ never sent when refused")
        XCTAssertTrue(ws.contains("if let why = job.coreRefusal { model.toast = why; return }"), "the run")
        XCTAssertTrue(ws.contains("if let why = job.coreRefusal { throw RelatticeError(why) }"), "Check sizes")
        XCTAssertTrue(ws.contains("variantJobCoreRefusal: pass.coreRefusal)"), "the page gets it")
        XCTAssertTrue(page.contains("case .variantJobRefused: if actions.optimize.enabled { onOptimize() }"),
                      "★ the one tap is the Optimize path itself")
        XCTAssertTrue(page.contains("variantJobRefusal: variantJobCoreRefusal,"), "the banner reads it")
    }
}
