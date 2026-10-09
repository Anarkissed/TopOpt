// FlexibleS1VerifyTests — the S1 sync's verification (angled presses, batch S1; the #361 / #358 / #354
// merges). The verifier's confirmed major: the reviewer's ruling (i) put H7/H8 on #354's
// `legendDrilledIn`, and #354 defines that as `latticeLegendMounted && !latticeLegendMinimized &&
// latticeLegendMode.drilledIn` with `latticeLegendMounted = showStrutPreview && strutScene != nil` —
// the OCTET key. On the Flexible lattice stage the octet key is never mounted (`showStrutPreview` is
// set only by the octet's view toggles, which H5 replaces, and by LatticePage, which Flexible does not
// open), so with the Flexible key (FlexibleMainLegends, H6) drilled in:
//   - the wall probe (H8, `onLatticeProbe`) was never armed: a tap on a wall read "—" through H7;
//   - the double tap out (`onLatticeProbeExit`) was off, though the key's header promises it;
//   - #354's drilled-in hides (clearance volumes, depth-plane handles, gizmos, band chips) no longer
//     applied — FlexibleMainLegends' header relies on "#354's own gates hold".
// Before S1 every one of those read `latticeLegendMode.drilledIn`, which the Flexible key writes.
//
// THE FIX (H14): #354's definition gains ONE disjunct, the Flexible key's own drill-in
// (`FlexibleMainStage.keyDrilledIn`): the stage owns the page (H6 mounts the key exactly then, and the
// key resets the mode when it goes — onDisappear, or a drilled view turned off) and the mode is one of
// the Flexible key's kinds. The ruled H7/H8 text is unchanged, #354's own expression is unchanged
// (its pins: the expression, one raw `latticeLegendMode.drilledIn` read), and every one of #354's
// gates reads the one value again.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleS1VerifyTests: XCTestCase {

    private func member(_ text: String, _ decl: String) throws -> String {
        let r = try XCTUnwrap(text.range(of: decl), "missing \(decl)")
        let rest = text[r.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "unterminated \(decl)")
        return String(rest[..<end.upperBound])
    }

    /// The Flexible key's drill-in counts on the Flexible lattice stage, with NO octet preview —
    /// the state the main page is always in under Flexible — and the wall probe is armed for the
    /// lattice reading (H8's whole gate: `legendDrilledIn && wantsWallProbe`).
    @MainActor
    func testTheFlexibleKeysDrillInCountsWithoutTheOctetPreview() throws {
        let project = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let stage = FlexibleMainStage()
        for k in FlexibleReadKind.allCases {
            XCTAssertTrue(stage.keyDrilledIn(project, .lattice, mode: k.mode),
                          "★ \(k): the Flexible key drilled in is drilled in (the octet key is never mounted here)")
        }
        let lattice = FlexibleReadKind.lattice.mode
        XCTAssertTrue(stage.keyDrilledIn(project, .lattice, mode: lattice) && stage.wantsWallProbe(lattice),
                      "★ H8's gate: the wall probe is armed for the lattice reading")
        // not drilled in: the face path decides
        XCTAssertFalse(stage.keyDrilledIn(project, .lattice, mode: .groups))
        // the octet key's own colour is the octet's gate (its mount + minimised rule), never the Flexible key's
        let octet = LatticeLegendMode.colour(LatticeStructureClass.allCases[0].id)
        XCTAssertFalse(stage.keyDrilledIn(project, .lattice, mode: octet))
        // off the Flexible stage — another stage, or an octet project — the Flexible key is not on screen
        for s in WorkspaceStage.allCases where s != .lattice {
            XCTAssertFalse(stage.keyDrilledIn(project, s, mode: lattice), "\(s): the Flexible key is not mounted")
        }
        project.lattice.flexible = nil
        XCTAssertFalse(stage.keyDrilledIn(project, .lattice, mode: lattice), "an octet project: #354's own gate only")
    }

    /// The call site: #354's `legendDrilledIn` carries the Flexible disjunct, #354's own expression is
    /// intact, its one raw read stays, and the ruled H7/H8 lines read `legendDrilledIn` unchanged —
    /// so the probe, the double tap out and every drilled-in hide read one value again.
    func testLegendDrilledInCarriesTheFlexibleKey() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        let def = try member(ws, "private var legendDrilledIn: Bool")
        XCTAssertTrue(def.contains("latticeLegendMounted && !latticeLegendMinimized && latticeLegendMode.drilledIn"),
                      "#354's expression, unchanged")
        XCTAssertTrue(def.contains("|| flexibleMain.keyDrilledIn(project, stage, mode: latticeLegendMode)"),
                      "★ H14: the Flexible key's drill-in is a drill-in")
        XCTAssertEqual(ws.components(separatedBy: "latticeLegendMode.drilledIn").count - 1, 1,
                       "#354's pin: one raw read, its definition")
        XCTAssertEqual(ws.components(separatedBy: "flexibleMain.keyDrilledIn(").count - 1, 1, "H14 is one line")
        // the ruled lines (reviewer's ruling (i), 2026-10-08 19:13), verbatim
        XCTAssertTrue(ws.contains("onLatticeProbe: legendDrilledIn && flexibleMain.wantsWallProbe(latticeLegendMode)"))
        XCTAssertTrue(ws.contains("onLatticeProbeExit: legendDrilledIn\n"))
        XCTAssertTrue(ws.contains("if legendDrilledIn { return true }"))
        // the key H14 trusts: mounted exactly while the stage owns the page, and it resets the mode when it goes
        XCTAssertTrue(ws.contains("if flexibleMain.owns(project, stage) { FlexibleMainLegends(main: flexibleMain, mode: $latticeLegendMode,"))
        let legends = try FlexibleSource.text("FlexibleMainLegends.swift")
        XCTAssertTrue(legends.contains(".onDisappear {\n            if drilled != nil { mode = .groups }"))
        XCTAssertTrue(legends.contains("if let k = drilled, !now.contains(k) { mode = .groups }"))
        // the definition reads no stage mode (#354's pin: the prism and lattice-only carry over by construction)
        XCTAssertFalse(def.contains("stageMode"))
    }

    // MARK: the sector rule on a CURVED sector (the verifier's minor; the spec's V2)
    //
    // #361's 254cb137 changed core's `in_stack` for a SECTOR: the voxel's OWN ray is cast back onto the
    // footprint (`stack_owns_projection`) and tested against the cuts of the part it lands on. The app's
    // port (FlexibleStackMembership) kept the OLD rule — the point projected back by its depth. On his
    // sectors (flat, square to the load, split on a column line) the two agree, so FLEX-ASSEMBLE read 0
    // and measured nothing about the change. Here a CURVED sector — the cylinder's side, split by x ≥ 3
    // and then by a plane whose normal is off the press — where they do not: 23 voxels on the third
    // case (core refuses them, the old rule kept them; |Δρ| ≤ 0.256). The spec's S1 item: replace the
    // port's cut test with core's verdict, asked in one batch (FlexSectorVerdict).

    private struct Curved {
        let key: Int, n: Int, owners: Int, rho: Double, coreOwned: Int, appOwned: Int
        let oldRuleOwners: Int        // the same stack with core's verdict stripped (the old cut test)
        let verdict: FlexSectorVerdict?
        let topVerdict: FlexSectorVerdict??   // the whole top face's stack (nil: not built)
    }

    /// The cylinder (r 9, h 28)'s side, split by `splits` (each keeps its A side), pressed (5 kg) with
    /// its top pressed too (a whole face); the app's assembled field of the SECTOR against core's.
    @MainActor
    private func curvedSector(_ splits: [(point: SIMD3<Double>, normal: SIMD3<Double>)]) async throws -> Curved {
        let pm = try FlexibleSquishFixture.stlProject("evidence/2026-07-30-lattice-skin-freeform/cylinder_r9_h28.stl")
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleSquishFixture.faceAtZ(mesh, 28), bottom = FlexibleSquishFixture.faceAtZ(mesh, 0)
        let side = Set(mesh.faceIDs.map(Int.init)).subtracting([top, bottom]).sorted()
        XCTAssertFalse(side.isEmpty)
        var fr = pm.faceRegions
        var id = fr.union(faces: side.map { FaceID($0) }, named: "side")
        for c in splits { id = try XCTUnwrap(fr.splitManual(id, point: c.point, normal: c.normal).first, "the split's A side") }
        pm.faceRegions = fr
        let key = FlexibleRegions.wireID(try XCTUnwrap(fr.region(id)))
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(90, "the cylinder's scene") { m.sceneState == .ready }
        XCTAssertTrue(m.press(key, kg: 5))
        XCTAssertTrue(m.press(top, kg: 5))
        m.rest(bottom)
        try await FlexibleSquishFixture.settle(m, "the curved sector")
        let k = FlexFaceKey(region: key, rotation: 0)
        let st = try XCTUnwrap(m.stacks[k], "the sector's stack")
        let d = try XCTUnwrap(m.designs[k], "the sector's design: \(m.readiness.oneLine)")
        let build = m.build
        let core = try await m.workerForTests.withScene { try $0.densityField(faces: [key], rotations: [0], build: build) }
        let mask = try await m.workerForTests.withScene { try $0.latticeMask(build: build) }
        let c = FlexiblePinch.core(d, stack: st)
        let cuts = m.regions.cuts(of: key)
        XCTAssertEqual(cuts.count, splits.count, "premise: the sector carries its cuts")
        func app(_ s: FlexStackInfo) -> FlexDensityField {
            FlexibleGroupField.assemble(mask: mask, faces: [FlexibleGroupField.Face(region: key, stack: s, cuts: cuts,
                                                                                    density: c.buildableDensity, cellMM: c.cellMM)])
        }
        func diff(_ a: FlexDensityField) -> (rho: Double, owners: Int, n: Int, coreOwned: Int, appOwned: Int) {
            var worst = 0.0, owners = 0, n = 0, co = 0, ao = 0
            for i in core.density.indices where core.density[i] > -0.5 {
                n += 1
                worst = max(worst, Double(abs(a.density[i] - core.density[i])))
                if a.owner[i] != core.owner[i] { owners += 1 }
                if core.owner[i] == key { co += 1 }
                if a.owner[i] == key { ao += 1 }
            }
            return (worst, owners, n, co, ao)
        }
        var stripped = st
        stripped.sector = nil
        let now = diff(app(st)), old = diff(app(stripped))
        return Curved(key: key, n: now.n, owners: now.owners, rho: now.rho, coreOwned: now.coreOwned, appOwned: now.appOwned,
                      oldRuleOwners: old.owners, verdict: st.sector,
                      topVerdict: m.stacks[FlexFaceKey(region: top, rotation: 0)].map { $0.sector })
    }

    /// The app's assembled field of a curved sector IS core's, voxel for voxel; the sector's stack carries
    /// core's verdict and a whole face's carries none. RED (the third case): the old cut test — core's
    /// verdict stripped — differs from core.
    @MainActor
    func testTheAppsSectorMembershipIsCoresOnACurvedSector() async throws {
        let cases: [(String, [(point: SIMD3<Double>, normal: SIMD3<Double>)])] = [
            ("x ≥ 4 (its rim lies in the skin)", [(SIMD3(4, 0, 0), SIMD3(1, 0, 0))]),
            ("x ≥ 3, then x + z ≥ 20", [(SIMD3(3, 0, 0), SIMD3(1, 0, 0)), (SIMD3(6, 0, 14), SIMD3(1, 0, 1))]),
            ("x ≥ 3, then x + 2z ≥ 37", [(SIMD3(3, 0, 0), SIMD3(1, 0, 0)), (SIMD3(9, 0, 14), SIMD3(1, 0, 2))]),
        ]
        var oldRule: [Int] = []
        for (name, splits) in cases {
            let r = try await curvedSector(splits)
            print("FLEX-S1 CURVED SECTOR \(name), sector \(r.key): \(r.n) lattice voxels · owners differ on \(r.owners) (core owns \(r.coreOwned), app \(r.appOwned)) · |Δρ| ≤ \(r.rho) · the old cut test (verdict stripped): owners differ on \(r.oldRuleOwners) · core refuses \(r.verdict?.refused.count ?? -1) voxels of the sector's columns")
            XCTAssertGreaterThan(r.n, 10_000, "premise: the cylinder is latticed")
            XCTAssertGreaterThan(r.coreOwned, 10_000, "premise: the sector owns material")
            XCTAssertNotNil(r.verdict, "★ \(name): the sector's stack carries core's verdict")
            XCTAssertEqual(r.topVerdict ?? nil, nil, "a whole face (the top) has no verdict: core owns all its columns hold")
            XCTAssertNotNil(r.topVerdict, "premise: the top's stack was built")
            XCTAssertEqual(r.owners, 0, "★ \(name): the app's sector membership is core's")
            XCTAssertLessThan(r.rho, 1e-5)
            oldRule.append(r.oldRuleOwners)
        }
        XCTAssertGreaterThan(oldRule[2], 0, "★ RED CONTROL: the old cut test is not core's rule on this curved sector")
    }
}
