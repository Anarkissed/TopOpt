// FlexibleInPassCompositeTests — the Flexible lattice drawn INSIDE MeshRenderer's frame,
// under the X-ray view the maintainer asked for (task 2026-09-29-flexible-screens:
// "I am not able to see through the model. Imagine an 'X-ray vision' with a plane with a
// heat map for the dent"; "the dent is full 100% opacity"). Every frame here is the
// renderer's own offscreen frame — the same encode the screen runs.
//   T5  the 0.04 ghost does not hide the walls (it stays out of the G-buffer);
//   T6  the opaque dent hides the walls behind it (the ghost is drawn AFTER the shade);
//   T7  the ghost veils the walls;
//   T8  no lattice AO or crease lines on the heat map (neutral AO on the re-issued body);
//   T9  the squish is the dent's flexScale — one number;
//   T10 the lattice lands where the part projects, under a non-identity settle;
//   T11 the in-pass march matches a fine reference march (gates every speed-up);
//   T12 #354's frames are byte-identical with no drawable Flexible pass.
// Each has a control that goes RED — a knob on the pass that restores the wrong
// behaviour, and the test proves the instrument sees it.
#if canImport(Metal) && canImport(MetalKit)
import XCTest
import Metal
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class FlexibleInPassCompositeTests: XCTestCase {

    typealias Fx = FlexibleLatticeFixtures
    let size = 384
    let bg = MTLClearColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
    /// The dented map's colour here: a DS token, distinct from the ghost and the walls.
    var dentTint: SIMD4<Float> { FlexibleColours.token(DS.Color.warning, 1) }
    var ghost: SIMD4<Float> { FlexibleColours.ghost }

    /// The X-ray configuration the page draws: ghost tints, the top face as the opaque map,
    /// the body at the page's ghost alpha, the pass uploaded.
    func xray(_ r: MeshRenderer, _ box: Fx.BoxMesh, inputs: FlexibleLatticeInputs, faces: [FlexibleSquishFace] = [],
              token: Int, device: MTLDevice) {
        r.setVertexTints(Fx.xrayTints(box, ghost: ghost, dent: dentTint))
        r.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        r.applyFlexibleLattice(Fx.layer(inputs, faces: faces, token: token), device: device)
    }

    func frame(_ r: MeshRenderer) throws -> [UInt8] {
        try XCTUnwrap(r.renderOffscreen(size: size, clear: bg))
    }

    /// Pixels the opaque map covers: the frame with ONLY the dent visible, against the clear.
    func footprint(_ r: MeshRenderer, _ box: Fx.BoxMesh, device: MTLDevice) throws -> [Bool] {
        let pass = r.flexibleLattice
        let hiddenBefore = pass?.hidden ?? true
        pass?.hidden = true
        r.setVertexTints(Fx.xrayTints(box, ghost: nil, dent: dentTint))
        r.setBodyAlpha(0)
        let d = try frame(r)
        pass?.hidden = hiddenBefore
        let b = UInt8((bg.blue * 255).rounded()), g = UInt8((bg.green * 255).rounded()), rr = UInt8((bg.red * 255).rounded())
        return (0..<(size * size)).map { p in
            let i = p * 4
            return abs(Int(d[i]) - Int(b)) > 1 || abs(Int(d[i + 1]) - Int(g)) > 1 || abs(Int(d[i + 2]) - Int(rr)) > 1
        }
    }

    // MARK: T5

    func testGhostDoesNotHideTheLattice() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        r.setVertexTints(Fx.xrayTints(box, ghost: ghost, dent: nil))
        r.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        XCTAssertNil(r.latticeMaskDump(size: size), "no Flexible pass ⇒ no lattice G-buffer")
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), token: 1), device: device)
        let pass = try XCTUnwrap(r.flexibleLattice)
        let ghostedDump = try XCTUnwrap(r.latticeMaskDump(size: size))
        let ghosted = ghostedDump.covered
        // (ported) the two topologies draw different pictures in the same frame
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.honeycomb), token: 2), device: device)
        let honey = try XCTUnwrap(r.latticeMaskDump(size: size))
        let topoDiffer = Fx.mismatch(ghostedDump.mask, honey.mask)
        print("FLEX-T5 gyroid vs honeycomb masks differ at \(topoDiffer) px (honeycomb covers \(honey.covered))")
        XCTAssertGreaterThan(Double(topoDiffer), 0.02 * Double(size * size), "gyroid and honeycomb drew the same picture")
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), token: 1), device: device)
        // positive control: an OPAQUE shell occludes every wall (the instrument sees occlusion)
        r.setBodyAlpha(1)
        let opaque = try XCTUnwrap(r.latticeMaskDump(size: size)).covered
        // ★ RED CONTROL: today's rule (a visible shell goes into the G-buffer) at 0.04
        r.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        pass.controlKeepGhostInGBuffer = true
        let kept = try XCTUnwrap(r.latticeMaskDump(size: size)).covered
        pass.controlKeepGhostInGBuffer = false
        print("FLEX-T5 covered at 0.04 ghost: \(ghosted) of \(size * size); opaque shell \(opaque); control (ghost kept in the G-buffer) \(kept)")
        XCTAssertGreaterThan(Double(ghosted), 0.02 * Double(size * size))
        XCTAssertEqual(opaque, 0, "positive control: an opaque shell must hide the walls")
        XCTAssertEqual(kept, 0, "control: the ghost in the G-buffer hides every wall")
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), token: 1, hidden: true), device: device)
        XCTAssertNil(r.latticeMaskDump(size: size), "a hidden pass is out of the frame")
        XCTAssertTrue(r.latticePipelinesDidBuild)
    }

    // MARK: T6 / T7 / T8

    func testOpaqueMapHidesTheWallsBehindIt() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        r.quality = []
        xray(r, box, inputs: Fx.boxInputs(.gyroid), token: 1, device: device)
        let pass = try XCTUnwrap(r.flexibleLattice)
        let mask = try XCTUnwrap(r.latticeMaskDump(size: size)).mask
        let a = try frame(r)
        pass.hidden = true
        let c = try frame(r)
        pass.hidden = false
        let foot = try footprint(r, box, device: device)
        xray(r, box, inputs: Fx.boxInputs(.gyroid), token: 1, device: device)
        let inFoot = Fx.differing(a, c, where: { foot[$0] })
        let outside = Fx.differing(a, c, where: { !foot[$0] && mask[$0] })
        // ★ BATCH M VERIFICATION (D-R5-MV3): the map's depth is in the G-buffer, so a wall behind the opaque
        // map is never marched — the draw order alone no longer puts walls on it (a SECOND guard). The
        // control restores batch M's frame first (no planes' depth), then the old order
        pass.controlDrawGhostFirst = true
        let aFirstWithDepth = try frame(r)
        pass.controlNoMapDepth = true
        let aFirst = try frame(r)
        pass.controlDrawGhostFirst = false
        pass.controlNoMapDepth = false
        let firstFoot = Fx.differing(aFirst, c, where: { foot[$0] })
        let firstWithDepth = Fx.differing(aFirstWithDepth, c, where: { foot[$0] })
        print("FLEX-T6 footprint \(inFoot.of) px: A≠C at \(inFoot.differ); outside the map, lattice px A≠C \(outside.differ)/\(outside.of); control (ghost first, no planes' depth) footprint A≠C \(firstFoot.differ); ghost first WITH the planes' depth \(firstWithDepth.differ)")
        XCTAssertGreaterThan(inFoot.of, 1000, "the map must cover part of the frame")
        XCTAssertLessThanOrEqual(Double(inFoot.differ), 0.005 * Double(inFoot.of), "the opaque map must hide the walls behind it")
        XCTAssertGreaterThan(Double(outside.differ), 0.2 * Double(outside.of), "positive control: the lattice shows outside the map")
        XCTAssertGreaterThan(Double(firstFoot.differ), 0.3 * Double(inFoot.of), "control: shading after the ghost paints walls over the map")
        XCTAssertLessThanOrEqual(Double(firstWithDepth.differ), 0.005 * Double(inFoot.of), "the planes' depth alone keeps the walls off the map")
    }

    func testGhostVeilsTheLattice() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        r.quality = []
        xray(r, box, inputs: Fx.boxInputs(.gyroid), token: 1, device: device)
        let pass = try XCTUnwrap(r.flexibleLattice)
        let mask = try XCTUnwrap(r.latticeMaskDump(size: size)).mask
        let a = try frame(r)
        pass.controlDrawGhostFirst = true
        let aFirst = try frame(r)
        pass.controlDrawGhostFirst = false
        let foot = try footprint(r, box, device: device)
        // B: the same lattice, no body at all
        r.setVertexTints(Fx.xrayTints(box, ghost: nil, dent: nil))
        r.setBodyAlpha(0)
        let b = try frame(r)
        let keep: (Int) -> Bool = { !foot[$0] && mask[$0] }
        let veiled = Fx.differing(a, b, where: keep)
        let first = Fx.differing(aFirst, b, where: keep)
        // ★ THE DIRECTION, as HUE: the ghost's brightness runs 0.35 … 1.25 × its tint by design
        // (faint face-on, lit at the silhouette), so a per-channel sign is not a property of the
        // shader — but every ghost colour has the tint's CHROMATICITY (rgb / (r+g+b)), and a
        // premultiplied "over" blend moves a pixel's chromaticity along the line toward it.
        func chroma(_ v: SIMD3<Double>) -> SIMD3<Double> { v / max(v.x + v.y + v.z, 1e-6) }
        let tintC = chroma(SIMD3<Double>(Double(ghost.x), Double(ghost.y), Double(ghost.z)))
        var toward = 0, judged = 0
        for p in 0..<(size * size) where keep(p) {
            let i = p * 4
            let av = SIMD3<Double>(Double(a[i + 2]), Double(a[i + 1]), Double(a[i])) / 255
            let bv = SIMD3<Double>(Double(b[i + 2]), Double(b[i + 1]), Double(b[i])) / 255
            guard simd_length(av - bv) > 2.5 / 255 else { continue }   // beyond 8-bit rounding
            judged += 1
            if simd_distance(chroma(av), tintC) < simd_distance(chroma(bv), tintC) { toward += 1 }
        }
        print("FLEX-T7 lattice px outside the map: A≠B \(veiled.differ)/\(veiled.of); of \(judged) clearly veiled px, \(toward) moved toward the ghost's hue; control (ghost first) \(first.differ)")
        XCTAssertGreaterThan(Double(veiled.differ), 0.5 * Double(veiled.of), "the ghost must veil the walls")
        XCTAssertGreaterThan(judged, 100)
        XCTAssertGreaterThan(Double(toward), 0.95 * Double(judged), "the veil must move the walls toward the ghost's tint")
        XCTAssertLessThanOrEqual(Double(first.differ), 0.005 * Double(first.of), "control: an opaque shade over the ghost leaves no veil")
    }

    /// T7b — the re-issued ghost keeps its DEPTH TEST: the box's far side, behind every wall,
    /// fails `.less` against the depth lsdf_shade wrote, so a wall is veiled by ONE layer of
    /// ghost (the near side), never two. Frames: the full box vs the same box with its far
    /// faces removed — on lattice pixels they must agree. POSITIVE CONTROL: where no wall
    /// hides it, the far side does show through the ghost (the two frames differ there).
    /// RED (proved by giving the re-issued body `.always`): the far side paints over the walls.
    func testTheGhostsFarSideIsHiddenBehindTheWalls() throws {
        let device = try Fx.device()
        let full = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: full)
        r.quality = []
        // the far faces: outward normal pointing away from the eye (the model is not settled)
        let eye = r.camera.eye
        let faces: [(id: Int32, n: SIMD3<Float>, c: SIMD3<Float>)] = [
            (0, SIMD3(0, 0, -1), SIMD3(20, 20, 0)), (2, SIMD3(-1, 0, 0), SIMD3(0, 20, 10)),
            (3, SIMD3(1, 0, 0), SIMD3(40, 20, 10)), (4, SIMD3(0, -1, 0), SIMD3(20, 0, 10)),
            (5, SIMD3(0, 1, 0), SIMD3(20, 40, 10))]
        let far = Set(faces.filter { simd_dot($0.n, eye - $0.c) < 0 }.map(\.id))
        XCTAssertGreaterThanOrEqual(far.count, 2, "the camera must see some faces from behind")
        let open = Fx.boxMesh(omit: far)
        func frame(_ box: Fx.BoxMesh) throws -> [UInt8] {
            r.setMesh(box.mesh)
            r.setVertexTints(Fx.xrayTints(box, ghost: ghost, dent: nil))
            r.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
            return try self.frame(r)
        }
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), token: 1), device: device)
        r.setMesh(full.mesh)
        r.setVertexTints(Fx.xrayTints(full, ghost: ghost, dent: nil))
        r.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        let mask = try XCTUnwrap(r.latticeMaskDump(size: size)).mask
        let a = try frame(full)
        let b = try frame(open)
        let walls = Fx.differing(a, b, where: { mask[$0] })
        let bare = Fx.differing(a, b, where: { !mask[$0] })
        print("FLEX-T7b far faces \(far.sorted()): lattice px full ≠ open \(walls.differ)/\(walls.of); positive control, px with no wall \(bare.differ)/\(bare.of)")
        XCTAssertGreaterThan(walls.of, 5000)
        XCTAssertLessThanOrEqual(Double(walls.differ), 0.005 * Double(walls.of), "the ghost's far side must fail the depth test behind a wall")
        XCTAssertGreaterThan(bare.differ, 1000, "positive control: the far side must show where no wall hides it")
    }

    func testNoLatticeAOOrCreasesOnTheMap() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        r.quality = .all
        xray(r, box, inputs: Fx.boxInputs(.gyroid), token: 1, device: device)
        let pass = try XCTUnwrap(r.flexibleLattice)
        let a = try frame(r)
        // ★ BATCH M VERIFICATION (D-R5-MV3): with the map's depth in the G-buffer no wall is marched behind
        // the map, so the lattice-only AO has nothing to print there — the control restores batch M's
        // frame too (no planes' depth) to show the instrument still sees the AO when it is bound
        pass.controlKeepAOForGhost = true
        pass.controlNoMapDepth = true
        let aAO = try frame(r)
        pass.controlKeepAOForGhost = false
        pass.controlNoMapDepth = false
        // E: a ready pass with no lattice anywhere (mask all zero)
        var empty = Fx.boxInputs(.gyroid)
        empty.mask.values = [Float](repeating: 0, count: empty.mask.values.count)
        xray(r, box, inputs: empty, token: 2, device: device)
        XCTAssertTrue(r.flexibleLatticeInFrame)
        let e = try frame(r)
        let foot = try footprint(r, box, device: device)
        let same = Fx.differing(a, e, where: { foot[$0] })
        let ao = Fx.differing(aAO, e, where: { foot[$0] })
        print("FLEX-T8 footprint \(same.of) px: A≠E at \(same.differ); control (lattice AO on the re-issued body) \(ao.differ)")
        XCTAssertGreaterThan(same.of, 1000)
        XCTAssertLessThanOrEqual(Double(same.differ), 0.005 * Double(same.of), "the lattice's AO/creases must not print on the map")
        XCTAssertGreaterThan(Double(ao.differ), 0.02 * Double(same.of), "control: the lattice-only AO must show when bound")
    }

    // MARK: T9 — one number

    func testSquishIsTheDentsFlexScale() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        r.setVertexTints(Fx.xrayTints(box, ghost: nil, dent: nil))
        r.setBodyAlpha(0)
        let f = Fx.boxInputs(.gyroid), face = Fx.topFace(depth: 3)
        func mask(_ faces: [FlexibleSquishFace], token: Int, s: Float) throws -> [Bool] {
            r.applyFlexibleLattice(Fx.layer(f, faces: faces, token: token), device: device)
            r.setFlexScale(s)
            return try XCTUnwrap(r.latticeMaskDump(size: size)).mask
        }
        let none = try mask([], token: 1, s: 0)
        let m0 = try mask([face], token: 2, s: 0)
        let m1 = try mask([face], token: 2, s: 1)
        let mh = try mask([face], token: 2, s: 0.5)
        r.flexibleLattice?.controlSquishOverride = 0
        let mOverride = try mask([face], token: 2, s: 1)
        r.flexibleLattice?.controlSquishOverride = nil
        let total = size * size
        print("FLEX-T9 mask px differing: s=0 vs no faces \(Fx.mismatch(m0, none)); s=1 vs s=0 \(Fx.mismatch(m1, m0)); s=½ vs 0 \(Fx.mismatch(mh, m0)), vs 1 \(Fx.mismatch(mh, m1)); control (squish forced 0 at flexScale 1) vs s=0 \(Fx.mismatch(mOverride, m0))")
        XCTAssertEqual(Fx.mismatch(m0, none), 0, "flexScale 0 is the rest lattice, bit for bit")
        XCTAssertGreaterThan(Double(Fx.mismatch(m1, m0)), 0.01 * Double(total))
        XCTAssertGreaterThan(Fx.mismatch(mh, m0), 0)
        XCTAssertGreaterThan(Fx.mismatch(mh, m1), 0)
        XCTAssertEqual(Fx.mismatch(mOverride, m0), 0, "control: with the squish cut from flexScale nothing moves")
    }

    // MARK: T10 — the lattice lands where the part projects

    func testTheLatticeLandsWhereThePartProjects() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        r.beginSettle(to: settle, duration: 0)   // duration 0 applies at once
        XCTAssertEqual(r.pickModelFrame.rotation.vector, settle.vector, "the settle must be applied")
        r.setVertexTints(Fx.xrayTints(box, ghost: nil, dent: nil))
        r.setBodyAlpha(0)
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), token: 1), device: device)
        let n = 512
        func bbox() throws -> (minX: Double, maxX: Double, minY: Double, maxY: Double, mask: [Bool]) {
            let d = try XCTUnwrap(r.latticeMaskDump(size: n))
            var minX = n, minY = n, maxX = -1, maxY = -1
            for y in 0..<n { for x in 0..<n where d.mask[y * n + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            return (Double(minX), Double(maxX + 1), Double(minY), Double(maxY + 1), d.mask)
        }
        let got = try bbox()
        let cam = CameraProjection(camera: r.camera, viewportSize: CGSize(width: n, height: n))
        let model = ViewerModelFrame.matrix(centre: r.pickModelFrame.centre, rotation: settle)
        let proj = CameraProjection(viewProjection: cam.viewProjection * model, viewportSize: cam.viewportSize)
        var cx: [Double] = [], cy: [Double] = []
        for c in 0..<8 {
            let p = SIMD3<Float>(c & 1 == 0 ? 0 : 40, c & 2 == 0 ? 0 : 40, c & 4 == 0 ? 0 : 20)
            let q = try XCTUnwrap(proj.project(p))
            cx.append(Double(q.x)); cy.append(Double(q.y))
        }
        let want = (minX: cx.min()!, maxX: cx.max()!, minY: cy.min()!, maxY: cy.max()!)
        let err = max(abs(got.minX - want.minX), abs(got.maxX - want.maxX), abs(got.minY - want.minY), abs(got.maxY - want.maxY))
        let flipY = (minY: Double(n) - want.maxY, maxY: Double(n) - want.minY)
        let flipX = (minX: Double(n) - want.maxX, maxX: Double(n) - want.minX)
        let errFlipY = max(abs(got.minY - flipY.minY), abs(got.maxY - flipY.maxY))
        let errFlipX = max(abs(got.minX - flipX.minX), abs(got.maxX - flipX.maxX))
        // the shell's OWN silhouette (the box mesh, opaque, no pass), dilated by one pixel
        r.flexibleLattice?.hidden = true
        r.setBodyAlpha(1)
        let shell = try XCTUnwrap(r.renderOffscreen(size: n, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)))
        r.setBodyAlpha(0)
        r.flexibleLattice?.hidden = false
        var sil = [Bool](repeating: false, count: n * n)
        for q in 0..<(n * n) where shell[q * 4 + 3] > 0 {
            let x = q % n, y = q / n
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                if xx >= 0, yy >= 0, xx < n, yy < n { sil[yy * n + xx] = true }
            } }
        }
        func outside(_ m: [Bool]) -> Int { m.indices.filter { m[$0] && !sil[$0] }.count }
        let outsideNow = outside(got.mask)
        // ★ RED CONTROL: the pass's model centre 1 mm off (the pass alone) lands outside
        r.flexibleLattice?.controlModelCenterOffset = SIMD3(0, 1, 0)
        let shifted = try bbox()
        r.flexibleLattice?.controlModelCenterOffset = .zero
        let outsideShifted = outside(shifted.mask)
        print(String(format: "FLEX-ALIGN settled: covered x %.0f–%.0f y %.0f–%.0f; projected x %.1f–%.1f y %.1f–%.1f; max edge error %.1f px; controls: y-flipped %.1f, x-flipped %.1f px; outside the silhouette %d px, with the pass's centre 1 mm off %d px",
                     got.minX, got.maxX, got.minY, got.maxY, want.minX, want.maxX, want.minY, want.maxY, err, errFlipY, errFlipX, outsideNow, outsideShifted))
        XCTAssertLessThanOrEqual(err, 8, "the lattice must land on the part's projected silhouette")
        XCTAssertEqual(outsideNow, 0)
        XCTAssertGreaterThan(errFlipY, 15, "control: a vertically flipped picture must fail")
        XCTAssertGreaterThan(errFlipX, 15, "control: a horizontally flipped picture must fail")
        XCTAssertGreaterThan(outsideShifted, 0, "control: a pass-side centre offset must put walls outside")
    }

    // MARK: T11 — the march is the field's zero set

    func testMarchMatchesAFineReferenceInPass() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        r.setVertexTints(Fx.xrayTints(box, ghost: nil, dent: nil))
        r.setBodyAlpha(0)
        let n = 768
        var token = 0
        for (topo, faces) in [(FlexibleLatticeInputs.Topology.gyroid, [FlexibleSquishFace]()), (.gyroid, [Fx.checkerFace()]),
                              (.honeycomb, []), (.honeycomb, [Fx.checkerFace()])] {
            token += 1
            r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(topo), faces: faces, token: token), device: device)
            let pass = try XCTUnwrap(r.flexibleLattice)
            r.setFlexScale(faces.isEmpty ? 0 : 1)
            // ★ THE REFERENCE IS INDEPENDENT OF THE MARCH'S OWN VIEW OF F: `earlyOut` off, so
            // it steps through `flx_field` (no lower-bound shortcuts). With it on, the
            // reference shared `flx_field_march` — a wrong march-view field moved both and
            // the comparison could not see it (a 5 % phase bias there: 4168 px, bar 526).
            let own = (factor: pass.stepFactor, minStep: pass.minStepMM)   // the pass's own values
            pass.stepFactor = 0.2; pass.stepCapOverride = 0.02; pass.minStepMM = 0.005; pass.stepBudget = 30000
            pass.earlyOut = false
            let ref = try XCTUnwrap(r.latticeMaskDump(size: n))
            pass.stepFactor = own.factor; pass.stepCapOverride = nil; pass.minStepMM = own.minStep; pass.stepBudget = FlexibleLatticePass.maxSteps
            pass.earlyOut = true
            let shipped = try XCTUnwrap(r.latticeMaskDump(size: n))
            let bad = Fx.mismatch(shipped.mask, ref.mask)
            let label = "\(topo) \(faces.isEmpty ? "rest" : "checkerboard press")"
            print("FLEX-MARCH in-pass \(label): \(bad) px disagree with the fine march (of \(ref.covered) covered)")
            XCTAssertGreaterThan(ref.covered, 1000)
            XCTAssertLessThan(Double(bad), 0.003 * Double(ref.covered), "\(label): the march misses walls the field has")
            if topo == .gyroid && faces.isEmpty {
                pass.stepCapOverride = 0.25
                let quarter = Fx.mismatch(try XCTUnwrap(r.latticeMaskDump(size: n)).mask, ref.mask)
                pass.stepCapOverride = 0.5
                let half = Fx.mismatch(try XCTUnwrap(r.latticeMaskDump(size: n)).mask, ref.mask)
                pass.stepCapOverride = nil
                print("FLEX-MARCH in-pass controls, gyroid at a quarter-cell cap: \(quarter) px; at a half-cell cap: \(half) px")
                // the quarter cell FAILS the shipped bar (why the gyroid's cap is 0.1), and a
                // half cell jumps walls by the percent
                XCTAssertGreaterThan(Double(quarter), 0.003 * Double(ref.covered), "control: a quarter-cell cap must fail the bar")
                XCTAssertGreaterThan(Double(half), 0.01 * Double(ref.covered), "control: the comparison cannot see a jumped wall")
            }
            if !faces.isEmpty {
                pass.ignoresColumnWalls = true
                let torn = Fx.mismatch(try XCTUnwrap(r.latticeMaskDump(size: n)).mask, ref.mask)
                pass.ignoresColumnWalls = false
                print("FLEX-MARCH in-pass control, \(label) without the column-wall bound: \(torn) px")
                XCTAssertGreaterThan(Double(torn), 0.01 * Double(ref.covered), "control: the comparison cannot see a torn column wall")
            }
        }
    }

    // MARK: the two hooks no frame test sees — the 1152 px cap and the view's apply

    /// ★ The march inherits #354's G-buffer cap (`gbufferSize`), and the SwiftUI update
    /// (`Coordinator.apply`) is what hands the pass its inputs. Frames at 384 px cannot see
    /// either: under the cap the size is the drawable's, and the tests above call
    /// `applyFlexibleLattice` directly. RED (proved by reverting each hook): the gbufferSize
    /// hook reverted gives a 2048² G-buffer; the apply line removed leaves the pass out.
    @MainActor
    func testTheMarchIsCappedAndTheViewHandsThePassItsInputs() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        r.setVertexTints(Fx.xrayTints(box, ghost: nil, dent: nil))
        r.setBodyAlpha(0)
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), token: 1), device: device)
        let big = try XCTUnwrap(r.latticeMaskDump(size: 2048))
        // positive control: under the cap the G-buffer is the drawable's own size
        let small = try XCTUnwrap(r.latticeMaskDump(size: 512))
        print("FLEX-CAP drawable 2048 → G-buffer \(big.width)×\(big.height); drawable 512 → \(small.width)×\(small.height)")
        XCTAssertEqual(big.width, MeshRenderer.latticeGBufferMaxPixels, "the Flexible march must inherit the 1152 px cap")
        XCTAssertEqual(big.height, MeshRenderer.latticeGBufferMaxPixels)
        XCTAssertEqual(small.width, 512, "control: under the cap the size is the drawable's")

        // the view's own apply, as the SwiftUI update calls it (LatticePreviewConfettiTests' precedent)
        guard let r2 = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        let coord = MetalMeshView.Coordinator()
        coord.renderer = r2
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 256, height: 256), device: device)
        var inputs = LatticePreviewConfettiTests.baseInputs()
        inputs.mesh = box.mesh
        inputs.bodyAlpha = FlexibleStagePage.xrayBodyAlpha
        inputs.flexibleLattice = Fx.layer(Fx.boxInputs(.gyroid), token: 3)
        coord.apply(inputs, to: view)
        XCTAssertTrue(r2.flexibleLatticeInFrame, "Coordinator.apply must hand the pass its inputs")
        XCTAssertEqual(r2.flexibleLattice?.uploadCount, 1)
        coord.apply(inputs, to: view)
        XCTAssertEqual(r2.flexibleLattice?.uploadCount, 1, "a redraw with the same token must not re-upload")
        // control: the same update without the lattice tears it down
        inputs.flexibleLattice = nil
        coord.apply(inputs, to: view)
        XCTAssertNil(r2.flexibleLattice)
        XCTAssertFalse(r2.flexibleLatticeInFrame)
    }

    // MARK: T12 — #354's frames are inert

    func testHooksAreInertWithoutAFlexiblePass() throws {
        let device = try Fx.device()
        let scene = LatticeBandTestCase.octetScene()
        guard let r = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        XCTAssertTrue(r.latticePipelinesDidBuild)
        r.setMesh(scene.mesh)
        r.setLatticeScene(scene, token: 1)
        r.latticeParams = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold(cellMM: 4)
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.35)
        func frames() throws -> [[UInt8]] {
            try [1, 0, FlexibleStagePage.xrayBodyAlpha].map { (a: Float) in
                r.setBodyAlpha(a)
                return try XCTUnwrap(r.renderOffscreen(size: 400, clear: bg))
            }
        }
        func hash(_ b: [UInt8]) -> UInt64 { LatticeBandTestCase.fnv(b) }
        let base = try frames()
        XCTAssertNil(r.flexibleLattice)
        // a pass that exists but has never been uploaded
        r.flexibleLattice = try FlexibleLatticePass(device: device)
        XCTAssertFalse(r.flexibleLatticeInFrame)
        let notReady = try frames()
        // a ready pass that is hidden
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), token: 1, hidden: true), device: device)
        XCTAssertEqual(r.flexibleLattice?.uploadCount, 1)
        XCTAssertFalse(r.flexibleLatticeInFrame)
        let hidden = try frames()
        // positive control: a ready, shown pass changes the ghost frame
        r.applyFlexibleLattice(Fx.layer(Fx.boxInputs(.gyroid), token: 1, hidden: false), device: device)
        r.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        let shown = try XCTUnwrap(r.renderOffscreen(size: 400, clear: bg))
        print("FLEX-T12 hashes base \(base.map(hash)) notReady \(notReady.map(hash)) hidden \(hidden.map(hash)); shown at 0.04 \(hash(shown))")
        for i in 0..<3 {
            XCTAssertEqual(notReady[i], base[i], "a pass that is not ready must leave #354's frame byte-identical (frame \(i))")
            XCTAssertEqual(hidden[i], base[i], "a hidden pass must leave #354's frame byte-identical (frame \(i))")
        }
        XCTAssertNotEqual(shown, base[2], "positive control: a shown pass must change the frame")
    }
}
#endif
