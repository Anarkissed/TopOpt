// FlexibleDepthPrismTests — "Deepest squish = a prism you drag out" (task
// 2026-09-29-flexible-screens, round 3, item 1.1). On the split pad (only top A pressed):
//   * the footprint is the sector's own columns (area = columns × pitch²) and stays on its side
//     of the cut. RED CONTROL: the whole face's bounding rectangle crosses the cut;
//   * the floor moves along +load (into the part). RED CONTROL: −load leaves the part;
//   * the handle reads the true depth back through the page's MODEL projection. RED CONTROL:
//     the same screen point through an un-settled WORLD projection reads another depth;
//   * clamp and detents: 0.2 → 0.5, past the lattice → the lattice depth, 2.9 → 3.0;
//   * the page passes the prism to MetalMeshView and mounts the chip (call-site pins).
// ★ VERIFICATION OF ROUND 3:
//   * a flat prism stands its skirt only where the outline turns (4 on top A; RED: the grid's
//     150 — the barcode that buried the map), and a staircase (diagonal) sector still meets
//     edge to edge (its outline length is the columns' perimeter; RED: rectangle corners only
//     would wall every T-junction);
//   * the prism is drawn ONLY while the chip is dragged;
//   * the prism floor stays inside the part: k is capped by k × deepest too (RED: the
//     verifier's flat-0.3 drawing got × 10 and a floor at z −10), and one drag stops where
//     k × depth reaches the lattice (RED: 12 mm × 3 = 36 mm);
//   * the chip stays mounted mid-drag (a removed view cancels without onEnded) and a
//     cancelled drag is finished; the scrub is DOWN = DEEPER (RED: his top-down projection
//     made a downward drag shallower).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleDepthPrismTests: XCTestCase {

    static func area(_ s: FaceOffsetShell) -> Double {
        var a = 0.0
        for t in stride(from: 0, to: s.indices.count, by: 3) {
            let p = (0..<3).map { SIMD3<Double>(s.base[Int(s.indices[t + $0])]) }
            a += simd_length(simd_cross(p[1] - p[0], p[2] - p[0])) / 2
        }
        return a
    }

    func testTheFootprintIsTheSectorsOwnColumns() throws {
        let a = try FlexibleOverlayClipTests.padAOnly()
        let t0 = Date()
        let s = try XCTUnwrap(FlexibleDepthPrism.shell(stack: a.stack, centres: a.geometry.centres, depthMM: 3, k: 4))
        let ms = Date().timeIntervalSince(t0) * 1000
        let want = Double(a.stack.columns.count) * a.stack.pitchMM * a.stack.pitchMM
        print(String(format: "FLEX-PRISM top A: %d columns, footprint %.1f mm² (columns × pitch² %.1f), %d corners, %d triangles, built in %.1f ms",
                     a.stack.columns.count, Self.area(s), want, s.base.count, s.indices.count / 3, ms))
        XCTAssertEqual(Self.area(s), want, accuracy: want * 1e-6)
        XCTAssertTrue(s.base.allSatisfy { $0.x >= 50 - 1e-4 }, "the prism stays on top A's side of the cut")
        XCTAssertLessThan(s.base.count, a.stack.columns.count * 2, "corners are shared, not four per column")
        // ★ RED CONTROL: the whole top face's bounding rectangle crosses the cut
        let rect: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 100), SIMD2(0, 100)]
        XCTAssertTrue(rect.contains { $0.x < 50 }, "control: the face's bounding box reaches into top B")
    }

    func testTheFloorMovesIntoThePart() throws {
        let a = try FlexibleOverlayClipTests.padAOnly()
        let s = try XCTUnwrap(FlexibleDepthPrism.shell(stack: a.stack, centres: a.geometry.centres, depthMM: 3, k: 4))
        for i in s.base.indices {
            let d = SIMD3<Double>(s.offset[i] - s.base[i])
            XCTAssertEqual(simd_dot(d, a.stack.load), 12, accuracy: 1e-3, "k · depth along +load")
        }
        XCTAssertEqual(s.reachedDepthMM, 12)
        XCTAssertEqual(a.stack.load.z, -1, accuracy: 1e-9, "premise: the top's load points down, into the part")
        // ★ RED CONTROL: along −load the floor would leave the part (above z = 20)
        let wrong = s.base.map { $0 - SIMD3<Float>(a.stack.load) * 12 }
        XCTAssertTrue(wrong.allSatisfy { $0.z > 20 }, "control: −load goes out of the part")
        XCTAssertTrue(s.offset.allSatisfy { $0.z < 20 }, "the floor is inside")
        // the handle: normal == load, anchor on the floor
        let v = try XCTUnwrap(FlexibleDepthPrism.volume(region: a.region, stack: a.stack, centres: a.geometry.centres, depthMM: 3, k: 4))
        let h = try XCTUnwrap(FlexibleDepthPrism.handle(v))
        XCTAssertEqual(simd_dot(SIMD3<Double>(h.planeNormal), a.stack.load), 1, accuracy: 1e-5)
        XCTAssertEqual(Double(h.anchor.z), 20 - FlexibleDepthPrism.insetMM - 12, accuracy: 1e-3)
    }

    /// ★ The page's projection is MODEL space (it composes the settle); the handle is too.
    func testTheHandleReadsTheTrueDepthThroughTheModelProjection() throws {
        let a = try FlexibleOverlayClipTests.padAOnly()
        let k = 4.0
        let v = try XCTUnwrap(FlexibleDepthPrism.volume(region: a.region, stack: a.stack, centres: a.geometry.centres, depthMM: 2, k: k))
        let h = try XCTUnwrap(FlexibleDepthPrism.handle(v))
        // the page's camera and settle (gravity → down), as FlexibleStagePage builds them
        var cam = OrbitCamera()
        cam.frame(a.part.bounds)
        cam.orbit(dx: 120, dy: 60)
        let viewport = CGSize(width: 1366, height: 1024)
        let world = CameraProjection(camera: cam, viewportSize: viewport)
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let m = ViewerModelFrame.matrix(centre: a.part.bounds.center, rotation: settle)
        let model = CameraProjection(viewProjection: world.viewProjection * m, viewportSize: viewport)
        var worst = 0.0, worstWorld = 0.0
        for d in [1.0, 3.0, 5.5] {
            let target = h.planeOrigin + h.planeNormal * Float(k * d)
            let p = try XCTUnwrap(model.project(target))
            let ray = try XCTUnwrap(model.ray(throughViewPoint: p))
            let got = try XCTUnwrap(FlexibleDepthPrism.depth(handle: h, rayOrigin: ray.origin, rayDir: ray.dir, k: k))
            worst = max(worst, abs(got - d))
            // ★ RED CONTROL: the same finger through the WORLD projection (no settle)
            let wr = try XCTUnwrap(world.ray(throughViewPoint: p))
            let wrong = FlexibleDepthPrism.depth(handle: h, rayOrigin: wr.origin, rayDir: wr.dir, k: k) ?? .infinity
            worstWorld = max(worstWorld, abs(wrong - d))
        }
        print(String(format: "FLEX-PRISM handle round trip: worst |read − set| %.5f mm (model projection), %.2f mm (world, control)", worst, worstWorld))
        XCTAssertLessThan(worst, 0.01)
        XCTAssertGreaterThan(worstWorld, 0.5, "control: an un-settled projection must read another depth")
    }

    func testClampAndDetents() {
        let lattice = 18.4
        XCTAssertEqual(FlexibleDepthPrism.resolve(rawMM: 0.2, latticeMM: lattice, held: nil).mm, 0.5)
        XCTAssertEqual(FlexibleDepthPrism.resolve(rawMM: -3, latticeMM: lattice, held: nil).mm, 0.5)
        XCTAssertEqual(FlexibleDepthPrism.resolve(rawMM: 40, latticeMM: lattice, held: nil).mm, lattice, "stops at the lattice depth")
        let snap = FlexibleDepthPrism.resolve(rawMM: 2.9, latticeMM: lattice, held: nil)
        XCTAssertEqual(snap.mm, 3.0)
        XCTAssertTrue(snap.didSnap)
        let atLattice = FlexibleDepthPrism.resolve(rawMM: 18.3, latticeMM: lattice, held: nil)
        XCTAssertEqual(atLattice.mm, lattice)
        XCTAssertEqual(atLattice.held?.kind, .extent)
        XCTAssertFalse(FlexibleDepthPrism.candidates(latticeMM: lattice).contains { $0.kind == .certifies },
                       "Flexible has no certificate")
    }

    /// The chip hides under the panel / legend (unreachable there) and off screen; looking
    /// along the load falls back to a screen scrub.
    func testTheChipKeepsOutAndFallsBackToAScrub() {
        let vp = CGSize(width: 1366, height: 1024)
        let panel = CGRect(x: 24, y: 400, width: 400, height: 600)
        XCTAssertTrue(FlexibleDepthChipLayout.visible(CGPoint(x: 700, y: 500), keepOut: [panel], viewport: vp))
        XCTAssertFalse(FlexibleDepthChipLayout.visible(CGPoint(x: 200, y: 700), keepOut: [panel], viewport: vp), "under the panel")
        XCTAssertFalse(FlexibleDepthChipLayout.visible(CGPoint(x: 440, y: 700), keepOut: [panel], viewport: vp), "half under it")
        XCTAssertFalse(FlexibleDepthChipLayout.visible(CGPoint(x: 5, y: 500), keepOut: [], viewport: vp), "off the edge")
        XCTAssertTrue(FlexibleDepthChipLayout.needsScrub(rayAlongLoad: 0.99, projectedPointsPer10MM: 40), "looking along the load")
        XCTAssertTrue(FlexibleDepthChipLayout.needsScrub(rayAlongLoad: 0.5, projectedPointsPer10MM: 4), "the load barely projects")
        XCTAssertFalse(FlexibleDepthChipLayout.needsScrub(rayAlongLoad: 0.5, projectedPointsPer10MM: 40))
    }

    /// ★ THE BARCODE (his top A, flat): the skirt stands only on the outline's 4 corners.
    func testAFlatPrismStandsItsSkirtOnlyWhereTheOutlineTurns() throws {
        let a = try FlexibleOverlayClipTests.padAOnly()
        let s = try XCTUnwrap(FlexibleDepthPrism.shell(stack: a.stack, centres: a.geometry.centres, depthMM: 3, k: 4))
        let grid = try XCTUnwrap(FlexibleDepthPrism.shell(stack: a.stack, centres: a.geometry.centres, depthMM: 3, k: 4, flatOutline: false))
        let want = Double(a.stack.columns.count) * a.stack.pitchMM * a.stack.pitchMM
        print("FLEX-PRISM top A skirt: \(FlexibleDepthPrism.skirtVertices(s)) vertical edges (grid mesh: \(FlexibleDepthPrism.skirtVertices(grid))), \(s.base.count) vertices")
        XCTAssertEqual(FlexibleDepthPrism.skirtVertices(s), 4, "a rectangle's prism has four walls' corners")
        XCTAssertEqual(Self.area(s), want, accuracy: want * 1e-6, "the same footprint")
        // ★ RED CONTROL: the per-corner grid stood a skirt edge every column pitch
        XCTAssertGreaterThan(FlexibleDepthPrism.skirtVertices(grid), 100, "control: the grid mesh is the barcode")
        XCTAssertEqual(Self.area(grid), want, accuracy: want * 1e-6)
    }

    /// ★ A STAIRCASE FOOTPRINT (the pad's top split along a DIAGONAL): the rectangles meet
    /// edge to edge — the boundary the skirt stands on is exactly the columns' own perimeter.
    @MainActor
    func testADiagonalSectorsPrismMeetsEdgeToEdge() throws {
        let m = try TopOptKit.importMesh(path: FlexibleStageTests.padSTL)
        let part = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, pseudoFaces: true)
        var model = FaceRegionModel()
        let top = FlexibleHisProject.topFace(part)
        let whole = model.union(faces: [FaceID(top)], named: "top")
        _ = model.splitManual(whole, point: SIMD3(50, 50, 20), normal: simd_normalize(SIMD3(1, 1, 0)))
        let regions = FlexibleRegions(model: model, mesh: part)
        let sector = regions.region(at: SIMD3(80, 80, 20), face: top, mesh: part)
        var st8 = FlexibleStageSettings(materialID: "varioshore_tpu")
        st8.setFace(FlexibleFaceSettings(faceRegionID: sector))
        var ji = FlexibleJob.Inputs(modelPath: FlexibleStageTests.padSTL, resolution: 50, beadWidthMM: 0.42, faceCount: 6, settings: st8)
        ji.sectorRegions = regions.wire
        let scene = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(ji, fallbackMaterial: "varioshore_tpu"), jobDir: "/")
        let stack = try scene.stack(face: sector, rotation: 0)
        let geo = try FlexFaceGeometry.compute(scene: scene, key: FlexFaceKey(region: sector, rotation: 0), stack: stack,
                                               partFlat: part.flat.positions)
        let s = try XCTUnwrap(FlexibleDepthPrism.shell(stack: stack, centres: geo.centres, depthMM: 3, k: 2))
        let cells = Set(stack.columns.map { SIMD2($0.iu, $0.iv) })
        // the columns' perimeter: every column side with no column across it
        var perimeter = 0
        for c in cells { for d in [SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)] where !cells.contains(c &+ d) { perimeter += 1 } }
        // the shell's boundary (edges used once), measured
        var use: [UInt64: Int] = [:]
        for t in stride(from: 0, to: s.indices.count, by: 3) {
            for e in 0..<3 {
                let a = s.indices[t + e], b = s.indices[t + (e + 1) % 3]
                use[a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a), default: 0] += 1
            }
        }
        XCTAssertTrue(use.values.allSatisfy { $0 <= 2 }, "no edge is shared by three triangles")
        var boundary = 0.0
        for (key, n) in use where n == 1 {
            boundary += Double(simd_length(s.base[Int(key >> 32)] - s.base[Int(key & 0xFFFF_FFFF)]))
        }
        let rects = FlexibleDepthPrism.rectangles(cells.map { ($0.x, $0.y) })
        let want = Double(stack.columns.count) * stack.pitchMM * stack.pitchMM
        print(String(format: "FLEX-PRISM diagonal sector: %d columns in %d rectangles, boundary %.1f mm (perimeter %.1f mm), skirt %d vertical edges",
                     cells.count, rects.count, boundary, Double(perimeter) * stack.pitchMM, FlexibleDepthPrism.skirtVertices(s)))
        XCTAssertGreaterThan(rects.count, 5, "premise: a staircase, not one rectangle")
        XCTAssertEqual(rects.reduce(0) { $0 + ($1.u1 - $1.u0) * ($1.v1 - $1.v0) }, cells.count, "the rectangles cover every column once")
        XCTAssertEqual(Self.area(s), want, accuracy: want * 1e-6)
        XCTAssertEqual(boundary, Double(perimeter) * stack.pitchMM, accuracy: 1e-3, "the skirt rides the outline only")
        // ★ RED CONTROL: each rectangle fanned through its own FOUR corners only — its sides meet
        // its neighbours' at T-junctions, and every such side reads as a boundary (a wall inside)
        struct Seg: Hashable { let a: SIMD2<Int>; let b: SIMD2<Int> }
        var naive: [Seg: Int] = [:]
        for r in rects {
            let c = [SIMD2(r.u0, r.v0), SIMD2(r.u1, r.v0), SIMD2(r.u1, r.v1), SIMD2(r.u0, r.v1)]
            for i in 0..<4 {
                let a = c[i], b = c[(i + 1) % 4]
                naive[(a.x, a.y) < (b.x, b.y) ? Seg(a: a, b: b) : Seg(a: b, b: a), default: 0] += 1
            }
        }
        let naiveBoundary = naive.filter { $0.value == 1 }.keys.reduce(0) { $0 + abs($1.b.x - $1.a.x) + abs($1.b.y - $1.a.y) }
        XCTAssertGreaterThan(naiveBoundary, perimeter, "control: corners only would wall the T-junctions")
    }

    /// ★ AT REST THE DENT READS ALONE: the prism is drawn only while the chip is dragged.
    @MainActor
    func testThePrismIsDrawnOnlyWhileTheChipIsDragged() async throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top))
        let m = try await FlexibleHisProject.openedModel(try FlexibleHisProject.padProject(s), test: self)
        m.selectedRegion = top
        XCTAssertTrue(FlexibleDepthPrism.renderItems(model: m, k: 4).isEmpty, "at rest: no prism")
        m.frozenExaggeration = 4
        XCTAssertEqual(FlexibleDepthPrism.renderItems(model: m, k: 4).count, 1, "dragging: the prism")
        m.frozenExaggeration = nil
        // ★ RED CONTROL: the prism itself exists at rest — only the drag rule hides it
        let key = try XCTUnwrap(m.key(top))
        XCTAssertNotNil(FlexibleDepthPrism.volume(region: top, stack: try XCTUnwrap(m.stacks[key]),
                                                  centres: try XCTUnwrap(m.geometry[key]).centres, depthMM: 3, k: 4))
    }

    /// ★ THE FLOOR STAYS INSIDE (the verifier's pad: curves flat at 0.3, deepest 3 mm, the
    /// drawing reaching 0.27 mm): k is capped by k × deepest as well as by the drawing.
    @MainActor
    func testThePrismFloorStaysInsideThePart() throws {
        let p = try FlexibleSquishTests.pad()
        let flat = FlexCurve(x: [0, 1], y: [0.3, 0.3])
        let face = FlexibleFaceSettings(faceRegionID: p.key.region, deepestMM: 3, curveX: flat, curveY: flat)
        let n = p.stack.columns.count
        let inp = FlexibleShownValues.Inputs(loadedFaces: [face], stacks: [p.key: p.stack], designs: [:],
                                             liveS: [p.key: [Double](repeating: 0.09, count: n)], checks: [:],
                                             checkStamps: [], checkStampShown: nil, showBuildable: false)
        let shown = FlexibleShownValues(inp, drawnLattice: nil)
        let prism = try XCTUnwrap(FlexibleDepthPrism.shell(stack: p.stack, centres: p.geometry.centres, depthMM: 3, k: shown.exaggeration))
        let floor = prism.offset.map(\.z).min() ?? 0
        print(String(format: "FLEX-PRISM flat 0.3 drawing: shown max %.2f mm, k %.0f, prism %.1f mm, floor z %.2f (lattice %.1f–%.1f mm)",
                     shown.maxDepth, shown.exaggeration, shown.exaggeration * 3, floor, p.stack.latticeMMMin, p.stack.latticeMMMax))
        XCTAssertGreaterThan(Double(floor), 0, "the prism floor lies inside the part")
        XCTAssertLessThanOrEqual(shown.exaggeration * 3, FlexibleShownValues.thinShare * p.stack.latticeMMMax + 1e-9)
        // ★ RED CONTROL: the drawing-only cap (the round-3 build) gave × 10 and a floor below the part
        let rule = FlexibleShownValues.exaggerationRule(maxDepthMM: shown.maxDepth, extentMM: max(p.stack.uExtentMM, p.stack.vExtentMM))
        let old = max(1, min(rule, FlexibleShownValues.thinCap(values: shown.values, stacks: [p.key: p.stack]) ?? rule))
        let wrong = try XCTUnwrap(FlexibleDepthPrism.shell(stack: p.stack, centres: p.geometry.centres, depthMM: 3, k: old))
        XCTAssertLessThan(wrong.offset.map(\.z).min() ?? 1, 0, "control: uncapped, the floor leaves the part")
    }

    /// ★ ONE DRAG STAYS INSIDE THE PART: with k frozen, the depth stops where k × depth meets
    /// the lattice depth (a detent there); after release k is re-chosen.
    func testOneDragStopsWhereThePrismMeetsTheLattice() throws {
        let a = try FlexibleOverlayClipTests.padAOnly()
        let lattice = a.stack.latticeMMMax
        let limit = FlexibleDepthPrism.dragLimit(stack: a.stack, k: 3)   // 20 / 3: off the 0.5 mm grid
        XCTAssertEqual(limit, lattice / 3, accuracy: 1e-9)
        let r = FlexibleDepthPrism.resolve(rawMM: 12, latticeMM: lattice, limitMM: limit, held: nil)
        XCTAssertEqual(r.mm, limit, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(r.mm * 3, lattice + 1e-9, "the prism floor stays in the lattice")
        XCTAssertEqual(FlexibleDepthPrism.resolve(rawMM: limit - 0.05, latticeMM: lattice, limitMM: limit, held: nil).held?.kind, .extent,
                       "it snaps at the limit")
        XCTAssertEqual(FlexibleDepthPrism.dragLimit(stack: a.stack, k: 1), lattice, "at × 1 the lattice depth itself")
        // ★ RED CONTROL: the lattice depth alone let one drag reach 12 mm × 3 = 36 mm
        let free = FlexibleDepthPrism.resolve(rawMM: 12, latticeMM: lattice, held: nil)
        XCTAssertGreaterThan(free.mm * 3, lattice, "control: without the limit the prism leaves the lattice")
    }

    /// ★ THE CHIP'S DRAG: mounted while dragged (even under the panel), finished when
    /// cancelled, and a scrub is DOWN = DEEPER.
    func testTheChipStaysMountedMidDragAndScrubsDownDeeper() throws {
        let vp = CGSize(width: 1366, height: 1024)
        let panel = CGRect(x: 24, y: 400, width: 400, height: 600)
        let under = CGPoint(x: 200, y: 700)
        XCTAssertTrue(FlexibleDepthChipLayout.shows(under, dragging: true, keepOut: [panel], viewport: vp), "mid-drag it stays")
        XCTAssertFalse(FlexibleDepthChipLayout.shows(under, dragging: false, keepOut: [panel], viewport: vp), "control: at rest it hides")
        XCTAssertFalse(FlexibleDepthChipLayout.shows(CGPoint(x: CGFloat.nan, y: 1), dragging: true, keepOut: [], viewport: vp))
        XCTAssertEqual(FlexibleDepthChipLayout.scrubMM(seedMM: 3, translation: CGSize(width: 0, height: 20)), 4, accuracy: 1e-9, "down = deeper")
        XCTAssertEqual(FlexibleDepthChipLayout.scrubMM(seedMM: 3, translation: CGSize(width: 0, height: -20)), 2, accuracy: 1e-9)
        // ★ RED CONTROL: the projected load on his top A seen from above was (−0.93, −0.37):
        // dragging DOWN 20 pt along it made the squish SHALLOWER
        let old = 3 + Double(0 * -0.93 + 20 * -0.37) * FlexibleDepthChipLayout.scrubMMPerPoint
        XCTAssertLessThan(old, 3, "control: the perspective's direction inverted the drag")
        // source pins: the gesture state finishes a cancelled drag
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let chips = try String(contentsOf: root.appendingPathComponent("FlexibleDepthChips.swift"), encoding: .utf8)
        XCTAssertTrue(chips.contains(".updating($dragging)"))
        XCTAssertTrue(chips.contains(".onChange(of: dragging) { d in if !d { finish() } }"))
        XCTAssertTrue(chips.contains(".onEnded { _ in finish() }"))
    }

    /// ★ CALL SITES (memory: value-type tests miss call sites).
    func testThePageDrawsThePrismAndMountsTheChip() throws {
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let page = try String(contentsOf: root.appendingPathComponent("FlexibleStagePage.swift"), encoding: .utf8)
        XCTAssertTrue(page.contains("clearanceVolumes: FlexibleDepthPrism.renderItems(model: model"))
        XCTAssertTrue(page.contains("FlexibleDepthChips("))
    }
}
