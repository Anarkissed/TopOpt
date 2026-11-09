// LatticeStartFromWholeTests — his iPad notes, 11-08 (2040 Extrusion Stand, Structural):
//   "I have selected 'All Lattice' in the settings, but there's a notification saying 'Nothing to lattice'. It seems
//    'All Lattice' does not work. This is a SERIOUS issue." … "It is only when I add a no-lattice zone where I am finally
//    able to see lattice — albeit only WITHIN the no-lattice zone. It should be literally everywhere else!"
//
// Three causes, one mechanism — where the lattice goes:
//   1. Start from − (core's `lattice.whole_part`: the whole part latticed, the No-lattice faces and zones cut out) reached
//      ONLY the job. The stage's preview clipped to the Lattice faces (none ⇒ nothing) and the Lattice / Optimize gates
//      said "nothing set to lattice", so the mode it offers could not be seen or run.
//   2. The preview never cut an exclude region out (core: exclude beats include), so No lattice inside a Lattice slab drew.
//   3. The stage's rebake key hashed Topology's groups, not the Lattice stage's own list (B6): a role, a zone, a face added
//      to a lattice group, and Start from − never rebaked — the No-lattice zone kept the picture baked while it was Lattice.
import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeStartFromWholeTests: XCTestCase {

    override func tearDown() {
        LatticeRegionMask.controlIncludesOnly = false
        super.tearDown()
    }

    /// A No-lattice slab off his part's +X wall, `depth` mm in (his Group 2's 4 mm faces).
    private func exclude(_ mesh: ViewerMesh, depth: Double) -> LatticeRegionSpec {
        let b = mesh.bounds
        let mid = (b.min + b.max) * 0.5
        var s = LatticeRegionSpec(role: .exclude, kind: .face)
        s.origin = SIMD3<Double>(Double(b.max.x), Double(mid.y), Double(mid.z))
        s.normal = SIMD3<Double>(-1, 0, 0)
        s.halfUMM = 200; s.halfWMM = 200; s.depthMM = depth
        return s
    }

    private func latticed(_ g: LatticeVoxelGrid, inside r: LatticeRegionSpec) -> Int {
        var n = 0, i = 0
        for k in 0..<g.nz { for j in 0..<g.ny { for x in 0..<g.nx {
            let p = SIMD3<Double>(Double(g.origin.x) + Double(x) * Double(g.spacing.x),
                                  Double(g.origin.y) + Double(j) * Double(g.spacing.y),
                                  Double(g.origin.z) + Double(k) * Double(g.spacing.z))
            if g.values[i] != 0, LatticeRegionMask.contains(p, region: r) { n += 1 }
            i += 1
        } } }
        return n
    }

    /// ★ (1) Start from − on the stage: the whole part, minus what is set to No lattice — never "Nothing to lattice".
    func testStartFromMinusLatticesTheWholePartButNoLattice() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let cut = exclude(mesh, depth: 8)
        // RED (the stage before 11-08): only No-lattice faces, clipped as "nothing declared"
        let before = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", regions: [cut], whenEmpty: .latticeNothing)
        XCTAssertEqual(before.interiorVoxelCount, 0, "★ RED: the stage drew nothing under Start from −")
        XCTAssertTrue(LatticePreviewBanner.make(previewOn: true, hasModel: true,
                                                scene: before)?.caption.hasPrefix("Nothing to lattice") == true,
                      "★ RED: his banner")
        // GREEN: the stage's Start from − scene
        let whole = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", regions: [cut], whenEmpty: .latticeEverything)
        XCTAssertGreaterThan(whole.interiorVoxelCount, 0)
        XCTAssertEqual(latticed(whole.occupancy, inside: cut), 0, "★ the No-lattice slab stays solid")
        XCTAssertLessThan(whole.interiorVoxelCount, whole.partInteriorVoxelCount, "★ and only it is cut out")
        XCTAssertFalse(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: whole)?.isEmpty ?? true)
        // CONTROL: the old clip ignored the cut
        LatticeRegionMask.controlIncludesOnly = true
        let ignored = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", regions: [cut], whenEmpty: .latticeEverything)
        XCTAssertGreaterThan(latticed(ignored.occupancy, inside: cut), 0, "★ CONTROL: without the cut the slab latticed")
    }

    /// ★ (2) A No-lattice region inside a Lattice slab stays solid (core's precedence: exclude beats include).
    func testNoLatticeWinsOverLattice() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var slab = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        slab.depthMM = 30
        let cut = exclude(mesh, depth: 6)
        let s = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", regions: [slab, cut], whenEmpty: .latticeNothing)
        XCTAssertGreaterThan(s.interiorVoxelCount, 0, "premise: the slab lattices past the cut")
        XCTAssertEqual(latticed(s.occupancy, inside: cut), 0, "★ the No-lattice part of the slab stays solid")
        LatticeRegionMask.controlIncludesOnly = true
        let red = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", regions: [slab, cut], whenEmpty: .latticeNothing)
        XCTAssertGreaterThan(latticed(red.occupancy, inside: cut), 0, "★ CONTROL: before, the slab latticed through it")
    }

    /// ★ (1) The Lattice and Optimize gates: Start from − needs no Lattice face; Start from + still does.
    func testTheGatesLetStartFromMinusRun() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regions = [exclude(mesh, depth: 4)]
        XCTAssertEqual(LatticeJobIncludeGate.refusal(latticeEnabled: true, regions: regions),
                       LatticeJobIncludeGate.nothingSetToLattice, "★ RED: his greyed 'Lattice · nothing set to lattice'")
        XCTAssertNil(LatticeJobIncludeGate.refusal(latticeEnabled: true, regions: regions, wholePart: true))
        XCTAssertNil(LatticeJobIncludeGate.optimizeRefusal(latticeEnabled: true, regions: regions, wholePart: true))
        XCTAssertEqual(LatticeJobIncludeGate.optimizeRefusal(latticeEnabled: true, regions: regions, wholePart: false),
                       LatticeJobIncludeGate.nothingSetToLattice, "Start from + keeps its rule")
        XCTAssertEqual(LatticeJobIncludeGate.refusal(latticeEnabled: false, regions: regions, wholePart: true),
                       LatticeJobIncludeGate.latticeModeOff, "lattice off is still off")
    }

    /// PROBE (looked at, not asserted beyond "drew"): Start from − on the stand, the body drawn (something is cut out), one
    /// 8 mm No-lattice slab — PNGs to $N1108_RENDER_DIR (else the temp dir), the path printed.
    @MainActor
    func testRenderStartFromMinusOnTheStand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", regions: [exclude(mesh, depth: 8)],
                                    whenEmpty: .latticeEverything)
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("renderer") }
        try XCTSkipUnless(renderer.latticePipelinesDidBuild)
        renderer.setMesh(mesh)
        renderer.setLatticeScene(scene, token: 1)
        renderer.latticeParams = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold(cellMM: 4.0)
        let dir = ProcessInfo.processInfo.environment["N1108_RENDER_DIR"] ?? NSTemporaryDirectory()
        let cells = renderer.activeCellsForTests
        print("RENDER start-from-minus census: cells drawn \(cells.active) of \(cells.total); voxels latticed "
              + "\(scene.interiorVoxelCount) of the part's \(scene.partInteriorVoxelCount)")
        for alpha in [Float(1), 0] {
            renderer.setBodyAlpha(alpha)
            for (name, az, el) in [("front", Float(0.6), Float(0.35)), ("cut", Float(-0.9), Float(0.3))] {
                LatticeQuiltFrameProbe.aim(renderer, mesh.bounds, azimuth: az, elevation: el, zoom: 0.8, height: 0.5)
                guard let px = renderer.renderOffscreen(size: 900, clear: MTLClearColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1))
                else { continue }
                let file = dir + "/startfrom_minus_\(name)_body\(Int(alpha)).png"
                LatticeQuiltFrameProbe.writePNG(px, size: 900, to: file)
                print("RENDER start-from-minus \(name) body \(alpha) → \(file)")
            }
        }
    }

    /// ★ (1) + (3) The stage reads Start from −, and its rebake key reads the Lattice stage's own list.
    func testTheStageReadsStartFromAndRebakesOnItsOwnList() throws {
        let src = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let r = try XCTUnwrap(src.range(of: "private var latticeRegionInputsKey: Int {"))
        let key = String(src[r.upperBound...].prefix(2600))
        for needle in ["for g in project.latticeGroups {", "h.combine(l.groupRoles[g.id])",
                       "project.force.manualPrimitives(for: g.id)", "h.combine(project.latticeStartsWhole)"] {
            XCTAssertTrue(key.contains(needle), "★ the rebake key reads \(needle)")
        }
        XCTAssertTrue(src.contains("let regions = project.latticePreviewRegions(emission.regions)"))
        XCTAssertTrue(src.contains("whenEmpty: startsWhole ? .latticeEverything : .latticeNothing,"))
        XCTAssertTrue(src.contains("regions: project.latticeJobRegions().regions, wholePart: project.latticeStartsWhole)"),
                      "★ the stage's Lattice and Optimize gates")
        XCTAssertEqual(WorkspacePlaceholder.wholePartSummary, "Whole part · no optimization")
        // ★ the body stays drawn under Start from − (thin walls and No-lattice zones read solid; the shell opens over cells)
        XCTAssertTrue(src.contains("let declared = project.latticeStartsWhole\n"
                                   + "            || LatticeJobIncludeGate.hasIncludeWall(project.latticeJobRegions().regions)"))
    }
}
