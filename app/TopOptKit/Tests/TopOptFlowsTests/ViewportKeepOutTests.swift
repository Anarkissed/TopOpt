// Headless tests for the viewport keep-out layout pass (ViewportKeepOut.swift) — the
// ONE pass every viewport-anchored control goes through so no two overlap (handoff
// 2026-07-27). The pass is pure (it takes already-projected screen points and returns
// screen points), so every requirement is pinned here headlessly — the /app/ standard:
//
//   • L2  a camera + element set that OVERLAPS today, resolved to zero touch overlap
//   • L4  determinism: same input twice → identical; independent of input order
//   • L5  the gizmo is rigid — it never moves, it displaces the others
//   • req1 stability: a slow orbit produces small, monotone, non-oscillating motion
//   • req3 leader line kicks in past a stated distance
//   • req4 collisions resolve on TOUCH bounds, not the drawn glass
//   • req5 minimum 44 pt touch (Apple HIG) is enforced, never silently shrunk
//   • req7 the no-room case hides the lowest-priority element, never stacks
//
// The slow-orbit test also writes a CSV capture to $KEEPOUT_EVIDENCE_DIR when set, so
// the evidence plot is generated from this exact code path.

import XCTest
import CoreGraphics
import simd
@testable import TopOptFlows

final class ViewportKeepOutTests: XCTestCase {

    // MARK: helpers

    private let viewport = CGSize(width: 1194, height: 834)   // iPad landscape points

    private func framedCamera() -> OrbitCamera {
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3<Float>(-1, -1, -1),
                             max: SIMD3<Float>(1, 1, 1), isEmpty: false))
        return cam
    }

    /// A touch size min-enforced to the 44 pt HIG floor (mirrors the solver).
    private func protected(_ s: CGSize) -> CGSize {
        CGSize(width: max(s.width, KeepOutSolver.minTouch), height: max(s.height, KeepOutSolver.minTouch))
    }

    /// True when two placements' min-enforced TOUCH rects overlap (the thing we protect).
    private func touchOverlap(_ a: KeepOutPlacement, _ sa: CGSize,
                              _ b: KeepOutPlacement, _ sb: CGSize) -> Bool {
        let ra = CGRect(x: a.center.x - sa.width/2, y: a.center.y - sa.height/2, width: sa.width, height: sa.height)
        let rb = CGRect(x: b.center.x - sb.width/2, y: b.center.y - sb.height/2, width: sb.width, height: sb.height)
        return ra.intersects(rb)
    }

    /// Assert no two VISIBLE placements' protected touch rects overlap.
    private func assertNoOverlap(_ placements: [KeepOutPlacement],
                                 _ sizes: [String: CGSize],
                                 file: StaticString = #filePath, line: UInt = #line) {
        let visible = placements.filter { !$0.hidden }
        for i in 0..<visible.count {
            for j in (i+1)..<visible.count {
                let a = visible[i], b = visible[j]
                let sa = protected(sizes[a.id]!)
                let sb = protected(sizes[b.id]!)
                XCTAssertFalse(touchOverlap(a, sa, b, sb),
                               "‹\(a.id)› and ‹\(b.id)› still overlap after resolve", file: file, line: line)
            }
        }
    }

    private func byId(_ p: [KeepOutPlacement]) -> [String: KeepOutPlacement] {
        Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
    }

    // MARK: L2 — overlaps today, zero overlap after

    /// Two labels anchored at nearby 3D points project to nearby screen points whose
    /// touch rects overlap under the OLD raw-position path — reproduced here — and the
    /// pass separates them.
    func testRawProjectedAnchorsOverlapButPassSeparatesThem() {
        let cam = framedCamera()
        let proj = CameraProjection(camera: cam, viewportSize: viewport)
        // Two model points a hair apart — the maintainer's stacked-chip case.
        let pA = try! XCTUnwrap(proj.project(SIMD3<Float>(0.00, 0.0, 0.0)))
        let pB = try! XCTUnwrap(proj.project(SIMD3<Float>(0.03, 0.0, 0.0)))
        let size = CGSize(width: 60, height: 34)

        // OLD behaviour: both draw at their raw projected point. Prove they overlap today.
        let rawA = CGRect(x: pA.x-30, y: pA.y-17, width: 60, height: 34)
        let rawB = CGRect(x: pB.x-30, y: pB.y-17, width: 60, height: 34)
        XCTAssertTrue(rawA.intersects(rawB), "precondition: the two chips overlap under the raw path")

        let elements = [
            KeepOutElement(id: "A", anchor: pA, bounds: size, touch: size, priority: .label),
            KeepOutElement(id: "B", anchor: pB, bounds: size, touch: size, priority: .label),
        ]
        let placed = KeepOutSolver.resolve(elements, viewport: viewport)
        assertNoOverlap(placed, ["A": size, "B": size])
    }

    /// A denser, mixed-priority pile — several elements at almost the same anchor —
    /// resolves to zero overlap among everything that stays visible.
    func testDensePileResolvesToZeroOverlap() {
        let anchor = CGPoint(x: 600, y: 420)
        let s = CGSize(width: 80, height: 40)
        var elements: [KeepOutElement] = []
        for i in 0..<6 {
            let p: KeepOutPriority = i % 2 == 0 ? .label : .pill
            elements.append(KeepOutElement(id: "e\(i)",
                                           anchor: CGPoint(x: anchor.x + CGFloat(i), y: anchor.y),
                                           bounds: s, touch: s, priority: p))
        }
        let placed = KeepOutSolver.resolve(elements, viewport: viewport)
        assertNoOverlap(placed, Dictionary(uniqueKeysWithValues: elements.map { ($0.id, s) }))
    }

    // MARK: L4 — determinism

    func testDeterministicSameInputSameOutput() {
        let s = CGSize(width: 70, height: 36)
        let elements: [KeepOutElement] = (0..<10).map { i in
            let x = CGFloat(500 + i * 7)
            let y = CGFloat(400 + (i % 3) * 5)
            let p: KeepOutPriority = i % 2 == 0 ? .label : .pill
            return KeepOutElement(id: "e\(i)", anchor: CGPoint(x: x, y: y), bounds: s, touch: s, priority: p)
        }
        let a = KeepOutSolver.resolve(elements, viewport: viewport)
        let b = KeepOutSolver.resolve(elements, viewport: viewport)
        XCTAssertEqual(a, b)
    }

    /// The result must NOT depend on the order elements were registered in (no reliance
    /// on dictionary / array iteration order) — reversing the input yields the same map.
    func testDeterministicIndependentOfInputOrder() {
        let s = CGSize(width: 70, height: 36)
        let elements: [KeepOutElement] = (0..<10).map { i in
            let x = CGFloat(500 + i * 6)
            let y = CGFloat(400 + (i % 4) * 4)
            let p: KeepOutPriority = i % 3 == 0 ? .label : .pill
            return KeepOutElement(id: "e\(i)", anchor: CGPoint(x: x, y: y), bounds: s, touch: s, priority: p)
        }
        let forward = byId(KeepOutSolver.resolve(elements, viewport: viewport))
        let reversed = byId(KeepOutSolver.resolve(elements.reversed(), viewport: viewport))
        XCTAssertEqual(forward, reversed)
    }

    // MARK: L5 / priority — rigid gizmo never moves; higher priority keeps its anchor

    func testRigidGizmoNeverMovesAndDisplacesOthers() {
        let anchor = CGPoint(x: 600, y: 420)
        let gizmo = KeepOutElement(id: "gizmo", anchor: anchor,
                                   bounds: CGSize(width: 120, height: 120),
                                   touch: CGSize(width: 120, height: 120), priority: .gizmo)
        let label = KeepOutElement(id: "label", anchor: anchor,
                                   bounds: CGSize(width: 70, height: 34),
                                   touch: CGSize(width: 70, height: 34), priority: .label)
        let placed = byId(KeepOutSolver.resolve([gizmo, label], viewport: viewport))
        // Gizmo pinned to its exact anchor (L5: never moves relative to its primitive).
        XCTAssertEqual(placed["gizmo"]!.center, anchor)
        XCTAssertEqual(placed["gizmo"]!.displacement, .zero)
        // The label was pushed clear.
        XCTAssertGreaterThan(placed["label"]!.displacementLength, 0)
        assertNoOverlap(Array(placed.values), ["gizmo": CGSize(width: 120, height: 120), "label": CGSize(width: 70, height: 34)])
    }

    func testHigherPriorityStaysCloserToAnchorThanLower() {
        let anchor = CGPoint(x: 600, y: 420)
        let s = CGSize(width: 80, height: 40)
        let pill = KeepOutElement(id: "pill", anchor: anchor, bounds: s, touch: s, priority: .pill)
        let label = KeepOutElement(id: "label", anchor: anchor, bounds: s, touch: s, priority: .label)
        let placed = byId(KeepOutSolver.resolve([label, pill], viewport: viewport))
        // The pill outranks the label, so it keeps the anchor and the label yields.
        XCTAssertEqual(placed["pill"]!.displacementLength, 0, accuracy: 0.001)
        XCTAssertGreaterThan(placed["label"]!.displacementLength, 0)
    }

    // MARK: handles are movable + slide on their geometric locus (maintainer feedback)

    /// A clearance knob whose HOME position is buried under the gizmo slides along its
    /// circumferential locus to a candidate that clears the gizmo — landing ON a candidate
    /// (its geometry), not floated far off in 2-D.
    func testLocusKnobSlidesToClearCandidate() {
        let gizmo = KeepOutElement(id: "gizmo", anchor: CGPoint(x: 600, y: 430),
                                   bounds: CGSize(width: 297, height: 297),
                                   touch: CGSize(width: 297, height: 297), priority: .gizmo)
        // 12 circumferential candidates on a big cylinder (radius 200 around the gizmo centre);
        // the home (index 0) is a point buried inside the box, the axis-aligned ones escape it.
        var cands: [CGPoint] = [CGPoint(x: 600, y: 430)]   // home: dead centre, fully covered
        for k in 0..<12 {
            let a = Double(k) * .pi / 6
            cands.append(CGPoint(x: 600 + 200 * CGFloat(cos(a)), y: 430 + 200 * CGFloat(sin(a))))
        }
        let knob = KeepOutElement(id: "knob", anchor: cands[0], bounds: CGSize(width: 46, height: 46),
                                  touch: CGSize(width: 46, height: 46), priority: .handle, candidates: cands)
        let placed = byId(KeepOutSolver.resolve([gizmo, knob], viewport: viewport))
        // The knob is clear of the gizmo…
        assertNoOverlap(Array(placed.values), ["gizmo": CGSize(width: 297, height: 297), "knob": CGSize(width: 46, height: 46)])
        // …and it landed essentially ON one of its candidates (slid on the locus, not floated).
        let c = placed["knob"]!.center
        let nearest = cands.map { hypot($0.x - c.x, $0.y - c.y) }.min()!
        XCTAssertLessThan(nearest, 8, "the knob should sit on its circumferential locus, not float off it")
        XCTAssertGreaterThan(placed["knob"]!.displacementLength, 100, "it moved well off the covered home")
    }

    /// `bestCandidateIndex` prefers the earliest candidate when several are equally clear
    /// (so an unobstructed knob stays home), and picks a clear one over an overlapping home.
    func testBestCandidatePrefersHomeThenLeastOverlap() {
        let occ = [CGRect(x: 580, y: 410, width: 40, height: 40)]   // covers the origin area
        // Home clear → index 0.
        XCTAssertEqual(KeepOutSolver.bestCandidateIndex(
            [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)], size: CGSize(width: 44, height: 44), avoiding: occ), 0)
        // Home covered, a later candidate clear → that one.
        let idx = KeepOutSolver.bestCandidateIndex(
            [CGPoint(x: 600, y: 430), CGPoint(x: 200, y: 200)], size: CGSize(width: 44, height: 44), avoiding: occ)
        XCTAssertEqual(idx, 1)
    }

    // MARK: maxShift — a handle/chip only nudges SLIGHTLY, never floats far (maintainer rule)

    func testMaxShiftCapsDisplacementAndKeepsVisible() {
        // A big rigid gizmo covers the handle's home; with a 40 pt cap the handle may only
        // nudge 40 pt (staying close, accepting residual overlap) — it must NOT fly to the
        // gizmo's edge (~150 pt away) and must NOT be hidden.
        let gizmo = KeepOutElement(id: "gizmo", anchor: CGPoint(x: 600, y: 430),
                                   bounds: CGSize(width: 300, height: 300),
                                   touch: CGSize(width: 300, height: 300), priority: .gizmo)
        let knob = KeepOutElement(id: "knob", anchor: CGPoint(x: 600, y: 430),
                                  bounds: CGSize(width: 46, height: 46), touch: CGSize(width: 46, height: 46),
                                  priority: .handle, maxShift: 40)
        let p = byId(KeepOutSolver.resolve([gizmo, knob], viewport: viewport))["knob"]!
        XCTAssertLessThanOrEqual(p.displacementLength, 40.001, "a capped handle must not float far")
        XCTAssertFalse(p.hidden, "a capped handle stays visible/close rather than being withdrawn")
        XCTAssertFalse(p.needsLeader, "capped handles never draw a leader")
    }

    func testUncappedElementStillSeparatesFully() {
        // Default (unbounded) still fully separates — the cap is opt-in per element.
        let a = KeepOutElement(id: "a", anchor: CGPoint(x: 600, y: 430), bounds: CGSize(width: 60, height: 40),
                               touch: CGSize(width: 60, height: 40), priority: .label)
        let b = KeepOutElement(id: "b", anchor: CGPoint(x: 600, y: 430), bounds: CGSize(width: 60, height: 40),
                               touch: CGSize(width: 60, height: 40), priority: .pill)
        assertNoOverlap(KeepOutSolver.resolve([a, b], viewport: viewport), ["a": CGSize(width: 60, height: 40), "b": CGSize(width: 60, height: 40)])
    }

    // MARK: req4 — resolve on TOUCH bounds, not the drawn glass

    /// Two elements whose DRAWN rects clear each other but whose (larger) TOUCH rects
    /// overlap must still be separated.
    func testResolvesOnTouchBoundsNotDrawnBounds() {
        let a = CGPoint(x: 600, y: 420)
        let b = CGPoint(x: 660, y: 420)                    // 60 pt apart
        let drawn = CGSize(width: 40, height: 40)          // drawn rects 40 wide → 20 pt gap, clear
        let touch = CGSize(width: 80, height: 80)          // touch rects 80 wide → overlap by 20 pt
        // Drawn rects do NOT overlap…
        XCTAssertFalse(CGRect(x: a.x-20, y: a.y-20, width: 40, height: 40)
            .intersects(CGRect(x: b.x-20, y: b.y-20, width: 40, height: 40)))
        // …but touch rects DO — that's the bug the pass must catch.
        XCTAssertTrue(CGRect(x: a.x-40, y: a.y-40, width: 80, height: 80)
            .intersects(CGRect(x: b.x-40, y: b.y-40, width: 80, height: 80)))
        let placed = KeepOutSolver.resolve([
            KeepOutElement(id: "a", anchor: a, bounds: drawn, touch: touch, priority: .label),
            KeepOutElement(id: "b", anchor: b, bounds: drawn, touch: touch, priority: .pill),
        ], viewport: viewport)
        assertNoOverlap(placed, ["a": touch, "b": touch])
    }

    // MARK: req5 — minimum 44 pt touch enforced, never silently shrunk

    func testMinimumTouchIsEnforced() {
        // Two tiny 12 pt controls stacked. The pass must protect each at 44 pt, so they
        // end up at least 44 pt apart (plus separation), never squeezed to their drawn size.
        let a = CGPoint(x: 600, y: 420)
        let tiny = CGSize(width: 12, height: 12)
        let placed = byId(KeepOutSolver.resolve([
            KeepOutElement(id: "a", anchor: a, bounds: tiny, touch: tiny, priority: .pill),
            KeepOutElement(id: "b", anchor: a, bounds: tiny, touch: tiny, priority: .label),
        ], viewport: viewport))
        let gap = abs(placed["a"]!.center.x - placed["b"]!.center.x)
                + abs(placed["a"]!.center.y - placed["b"]!.center.y)
        XCTAssertGreaterThanOrEqual(gap, KeepOutSolver.minTouch, "tiny controls must be protected at 44 pt, not shrunk")
    }

    // MARK: req3 — leader line distance

    func testLeaderLineKicksInPastThreshold() {
        // A rigid wall of gizmos forces a label far from its anchor → leader on.
        let anchor = CGPoint(x: 600, y: 420)
        let wall = (0..<3).map { i in
            KeepOutElement(id: "g\(i)", anchor: CGPoint(x: anchor.x, y: anchor.y),
                           bounds: CGSize(width: 60, height: 60), touch: CGSize(width: 60, height: 60),
                           priority: .gizmo)
        }
        let label = KeepOutElement(id: "L", anchor: anchor, bounds: CGSize(width: 70, height: 34),
                                   touch: CGSize(width: 70, height: 34), priority: .label)
        let placed = byId(KeepOutSolver.resolve(wall + [label], viewport: viewport))
        XCTAssertGreaterThan(placed["L"]!.displacementLength, KeepOutSolver.leaderOnDistance)
        XCTAssertTrue(placed["L"]!.needsLeader)

        // A lone element sits on its anchor → no leader.
        let solo = KeepOutSolver.resolve([label], viewport: viewport)[0]
        XCTAssertEqual(solo.displacementLength, 0, accuracy: 0.001)
        XCTAssertFalse(solo.needsLeader)
    }

    // MARK: req7 — the no-room case hides, never stacks

    func testNoRoomHidesLowestPriorityNeverStacks() {
        // A tiny viewport with more 44 pt controls than can possibly fit.
        let small = CGSize(width: 100, height: 100)
        let s = CGSize(width: 44, height: 44)
        let center = CGPoint(x: 50, y: 50)
        var elements: [KeepOutElement] = []
        // one gizmo (rigid) + several pills + several labels, all piled on the centre
        elements.append(KeepOutElement(id: "gizmo", anchor: center, bounds: s, touch: s, priority: .gizmo))
        for i in 0..<4 { elements.append(KeepOutElement(id: "pill\(i)", anchor: center, bounds: s, touch: s, priority: .pill)) }
        for i in 0..<4 { elements.append(KeepOutElement(id: "label\(i)", anchor: center, bounds: s, touch: s, priority: .label)) }
        let placed = byId(KeepOutSolver.resolve(elements, viewport: small))

        // Nothing visible overlaps — the pass never re-stacks (the bug it exists to remove).
        assertNoOverlap(Array(placed.values), Dictionary(uniqueKeysWithValues: elements.map { ($0.id, s) }))
        // The gizmo (highest) is never hidden.
        XCTAssertFalse(placed["gizmo"]!.hidden)
        // Something got hidden (no room), and the hidden set is lowest-priority-first:
        // no label may survive while a pill is hidden.
        let hiddenLabels = (0..<4).filter { placed["label\($0)"]!.hidden }.count
        let hiddenPills = (0..<4).filter { placed["pill\($0)"]!.hidden }.count
        XCTAssertGreaterThan(hiddenLabels + hiddenPills, 0, "no-room must hide, not stack")
        if hiddenPills > 0 {
            XCTAssertEqual(hiddenLabels, 4, "labels must all yield before any pill is hidden")
        }
    }

    // MARK: req1 — stability: the stabilizer converges monotonically and never oscillates

    func testStabilizerConvergesMonotoneNoOvershoot() {
        var stab = KeepOutStabilizer(damping: 0.35, deadBand: 0.5)
        let anchor = CGPoint(x: 600, y: 420)
        let target = KeepOutPlacement(id: "x", center: CGPoint(x: 700, y: 420),
                                      displacement: .zero, needsLeader: false, hidden: false)
        // Seed the previous position away from target by first sighting a different center…
        _ = stab.step([KeepOutPlacement(id: "x", center: CGPoint(x: 600, y: 420),
                                        displacement: .zero, needsLeader: false, hidden: false)],
                      anchors: ["x": anchor])
        var lastX: CGFloat = 600
        var prevDelta: CGFloat = .greatestFiniteMagnitude
        for _ in 0..<40 {
            let out = stab.step([target], anchors: ["x": anchor])[0]
            let x = out.center.x
            XCTAssertGreaterThanOrEqual(x, lastX - 0.001, "must not move backward (no oscillation)")
            XCTAssertLessThanOrEqual(x, 700.001, "must not overshoot the target")
            let delta = abs(700 - x)
            XCTAssertLessThanOrEqual(delta, prevDelta + 0.001, "gap must shrink monotonically")
            prevDelta = delta; lastX = x
        }
        XCTAssertEqual(lastX, 700, accuracy: 1.0, "converges to target")
    }

    func testStabilizerDeadBandHoldsStill() {
        var stab = KeepOutStabilizer(damping: 0.35, deadBand: 0.5)
        let anchor = CGPoint(x: 600, y: 420)
        let p = KeepOutPlacement(id: "x", center: anchor, displacement: .zero, needsLeader: false, hidden: false)
        _ = stab.step([p], anchors: ["x": anchor])
        // A sub-dead-band nudge produces no motion.
        let nudged = KeepOutPlacement(id: "x", center: CGPoint(x: anchor.x + 0.2, y: anchor.y),
                                      displacement: .zero, needsLeader: false, hidden: false)
        let out = stab.step([nudged], anchors: ["x": anchor])[0]
        XCTAssertEqual(out.center, anchor, "a sub-pixel target move must not shimmer the element")
    }

    // MARK: req1 / L3 — slow orbit: small camera moves → small, jitter-free position changes
    //                    with no identity swap. Writes the evidence CSV when asked.

    func testSlowOrbitIsStableAndWritesCapture() throws {
        // A busy project: four group centroids spread through the unit cube, each with a
        // value label anchored beside its knob. As the camera turns some anchors crowd and
        // the labels must separate — smoothly, without jitter or swapping.
        let modelPoints: [(String, SIMD3<Float>)] = [
            ("c0", SIMD3<Float>( 0.55,  0.35,  0.10)),
            ("c1", SIMD3<Float>(-0.50,  0.30, -0.15)),
            ("c2", SIMD3<Float>( 0.20, -0.45,  0.40)),
            ("c3", SIMD3<Float>(-0.30, -0.35, -0.45)),
        ]
        let labelSize = CGSize(width: 74, height: 34)

        // Run the SAME orbit twice: once raw (resolve only — what a naive pass would draw),
        // once through the stabilizer. Jitter shows up as (a) a big single-frame jump at a
        // separation flip and (b) high total variation (the summed frame-to-frame path — a
        // wiggly track has more than a smooth one). A low-pass follower provably reduces both
        // and never amplifies motion. Motion is only compared across CONSECUTIVE visible
        // frames, so a point orbiting behind the camera and reappearing isn't miscounted.
        func runOrbit(smoothed: Bool) -> (maxJump: CGFloat, totalVariation: CGFloat, csv: String) {
            var stab = KeepOutStabilizer()
            var prevCentres: [String: CGPoint] = [:]
            var lastSeenFrame: [String: Int] = [:]
            var maxJump: CGFloat = 0
            var totalVariation: CGFloat = 0
            var csv = "frame,azimuth_deg,id,anchor_x,anchor_y,center_x,center_y,leader,hidden\n"

            var cam = framedCamera()
            let startAz = cam.azimuth
            let frames = 160                                    // a slow ~1/3 turn, all points on-screen
            for f in 0..<frames {
                cam.azimuth = startAz + Float(f) * (0.6 * Float.pi / Float(frames))   // ~0.68°/frame
                let proj = CameraProjection(camera: cam, viewportSize: viewport)

                var elements: [KeepOutElement] = []
                var anchors: [String: CGPoint] = [:]
                for (id, mp) in modelPoints {
                    guard let p = proj.project(mp) else { continue }
                    let a = CGPoint(x: p.x + 26, y: p.y)        // label sits beside the knob
                    anchors[id] = a
                    elements.append(KeepOutElement(id: id, anchor: a, bounds: labelSize,
                                                   touch: labelSize, priority: .label))
                }
                let target = KeepOutSolver.resolve(elements, viewport: viewport)
                // INVARIANT (requirement 4/L2): the resolved target never overlaps, every frame.
                assertNoOverlap(target, Dictionary(uniqueKeysWithValues: elements.map { ($0.id, labelSize) }))
                let placed = smoothed ? stab.step(target, anchors: anchors) : target

                for pl in placed where !pl.hidden {
                    if let prev = prevCentres[pl.id], lastSeenFrame[pl.id] == f - 1 {
                        let d = CoreGraphics.hypot(pl.center.x - prev.x, pl.center.y - prev.y)
                        maxJump = Swift.max(maxJump, d)
                        totalVariation += d
                    }
                    prevCentres[pl.id] = pl.center
                    lastSeenFrame[pl.id] = f
                    let a = anchors[pl.id] ?? pl.center
                    csv += "\(f),\(String(format: "%.2f", cam.azimuth * 180 / .pi)),\(pl.id),"
                    csv += "\(fmt(a.x)),\(fmt(a.y)),\(fmt(pl.center.x)),\(fmt(pl.center.y)),"
                    csv += "\(pl.needsLeader ? 1 : 0),\(pl.hidden ? 1 : 0)\n"
                }
            }
            return (maxJump, totalVariation, csv)
        }

        let raw = runOrbit(smoothed: false)
        let smooth = runOrbit(smoothed: true)

        // STABILITY (requirement 1): the stabilizer never amplifies motion, tames the worst
        // single-frame jump (the separation-flip spike), and lowers the total path variation
        // (the shimmer signature) versus the raw per-frame pass.
        XCTAssertLessThan(smooth.maxJump, raw.maxJump, "the stabilizer must tame the worst jump (raw \(fmt(raw.maxJump)) → smoothed \(fmt(smooth.maxJump)))")
        // The slew cap hard-bounds every frame's motion (default 8 pt) — no lurch is possible.
        XCTAssertLessThanOrEqual(smooth.maxJump, KeepOutStabilizer().maxStep + 0.001, "a slow orbit must not jitter — smoothed max per-frame jump was \(smooth.maxJump)")
        XCTAssertLessThan(smooth.totalVariation, raw.totalVariation, "the stabilizer must reduce path wiggle (raw \(fmt(raw.totalVariation)) → smoothed \(fmt(smooth.totalVariation)))")

        if let dir = ProcessInfo.processInfo.environment["KEEPOUT_EVIDENCE_DIR"] {
            let base = URL(fileURLWithPath: dir)
            try? smooth.csv.write(to: base.appendingPathComponent("slow-orbit.csv"), atomically: true, encoding: .utf8)
            try? raw.csv.write(to: base.appendingPathComponent("slow-orbit-raw.csv"), atomically: true, encoding: .utf8)
        }
    }

    private func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }

    // MARK: L6 — a busy project: several groups, manual primitives, gravity, design box.
    //        Emits a before/after JSON capture of the whole element set (all sizes ×
    //        priorities) so the evidence plot shows the raw-overlap pile resolving to a
    //        clean layout with the gizmo pinned. Runs through the same pure pass the app uses.

    func testBusyProjectBeforeAfterCaptureHasNoOverlap() {
        let (elements, sizes) = busyScene()
        let placed = KeepOutSolver.resolve(elements, viewport: viewport)
        assertNoOverlap(placed, sizes)
        // Only the gizmo is rigid — it never moves. Every handle (knob, box handle) and every
        // pill is movable and may have shifted to clear the overlaps.
        let map = byId(placed)
        XCTAssertEqual(map["gizmo.transform"]!.displacement, .zero)

        if let dir = ProcessInfo.processInfo.environment["KEEPOUT_EVIDENCE_DIR"] {
            var json = "[\n"
            var first = true
            for e in elements.sorted(by: { $0.id < $1.id }) {
                let p = map[e.id]!
                let sz = sizes[e.id]!
                let tw = max(sz.width, KeepOutSolver.minTouch), th = max(sz.height, KeepOutSolver.minTouch)
                if !first { json += ",\n" }; first = false
                json += "  {\"id\":\"\(e.id)\",\"priority\":\"\(e.priority)\",\"rigid\":\(e.rigid),"
                json += "\"tw\":\(tw),\"th\":\(th),"
                json += "\"ax\":\(fmt(e.anchor.x)),\"ay\":\(fmt(e.anchor.y)),"
                json += "\"cx\":\(fmt(p.center.x)),\"cy\":\(fmt(p.center.y)),"
                json += "\"leader\":\(p.needsLeader),\"hidden\":\(p.hidden)}"
            }
            json += "\n]\n"
            try? json.write(to: URL(fileURLWithPath: dir).appendingPathComponent("busy-scene.json"),
                            atomically: true, encoding: .utf8)
        }
    }

    /// A crowded but realistic overlay set — three clearance sites (knob + value pill each,
    /// two nearly coincident), a rigid transform gizmo, two load pills, and the four design-box
    /// grab handles — deliberately piled so many overlap at their raw anchors.
    private func busyScene() -> ([KeepOutElement], [String: CGSize]) {
        let pill = CGSize(width: 64, height: 40), knob = CGSize(width: 46, height: 46)
        let load = CGSize(width: 96, height: 44), box = CGSize(width: 44, height: 44)
        var els: [KeepOutElement] = []
        var sizes: [String: CGSize] = [:]
        func add(_ id: String, _ p: CGPoint, _ s: CGSize, _ pr: KeepOutPriority) {
            els.append(KeepOutElement(id: id, anchor: p, bounds: s, touch: s, priority: pr)); sizes[id] = s
        }
        // Rigid transform gizmo near centre (297 pt box → spans x[451,749] y[281,578]).
        add("gizmo.transform", CGPoint(x: 600, y: 430), CGSize(width: 297, height: 297), .gizmo)
        // Three clearance sites. The knobs are MOVABLE now (the maintainer's rule: a handle
        // slides clear of the gizmo, it does not sit under it). Two of the three land inside
        // the gizmo box; the pass pushes them — and their value pills — out.
        let sites = [CGPoint(x: 560, y: 380), CGPoint(x: 640, y: 470), CGPoint(x: 820, y: 300)]
        for (i, s) in sites.enumerated() {
            add("clr.knob.\(i)", s, knob, .handle)
            add("clr.pill.\(i)", CGPoint(x: s.x + 72, y: s.y), pill, .label)   // beside the knob
        }
        // Two load pills, one deep inside the gizmo box → must be pushed out.
        add("load.0", CGPoint(x: 500, y: 430), load, .pill)
        add("load.1", CGPoint(x: 300, y: 520), load, .pill)
        // Design-box handles (also movable) at the corners, mostly clear of the gizmo.
        for (i, p) in [CGPoint(x: 460, y: 300), CGPoint(x: 780, y: 300),
                       CGPoint(x: 460, y: 560), CGPoint(x: 780, y: 560)].enumerated() {
            add("box.\(i)", p, box, .handle)
        }
        return (els, sizes)
    }
}
