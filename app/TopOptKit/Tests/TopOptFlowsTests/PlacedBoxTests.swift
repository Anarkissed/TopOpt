// PlacedBoxTests — ★ HIS 11-21: "please make ALL boxes the exact same as the Design Box in TO. It has to have the same mechanisms
// including the detents against faces ... handles against each face and magnetically connected to faces ... Do the same for
// Cylinders." The placed box's math is the Design Box's: one-sided face drags, the same magnets and hysteresis, a cylinder
// kept round — on the box's own (possibly turned) axes.
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class PlacedBoxTests: XCTestCase {
    private let square: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]

    private func plane(_ normal: SIMD3<Double>, _ origin: SIMD3<Double>) -> StepFaceGeometry {
        StepFaceGeometry(kind: .plane, planeNormal: normal, planeOrigin: origin)
    }

    func testAFaceMovesAloneAndTheOppositeFaceStays() {
        let b = PlacedBox(center: SIMD3(0, 0, 5), axes: square, half: SIMD3(2, 3, 5))
        let m = b.movingFace(2, isMax: true, to: 14, minSize: 0.1)
        XCTAssertEqual(m.faceCoord(2, isMax: true), 14, accuracy: 1e-12, "★ the dragged face lands where it was put")
        XCTAssertEqual(m.faceCoord(2, isMax: false), 0, accuracy: 1e-12, "★ the opposite face stays (the Design Box's one-sided drag)")
        XCTAssertEqual(m.half.x, 2); XCTAssertEqual(m.half.y, 3)
        let n = b.movingFace(0, isMax: false, to: 5, minSize: 0.5)
        XCTAssertEqual(n.faceCoord(0, isMax: false), 1.5, accuracy: 1e-12, "never past the other face, nearer than the least size")
    }

    func testACylinderStaysRound() {
        let c = PlacedBox(center: .zero, axes: square, half: SIMD3(4, 4, 10), isCylinder: true)
        let m = c.movingFace(0, isMax: true, to: 6, minSize: 0.1)
        XCTAssertEqual(m.half.x, 5, accuracy: 1e-12); XCTAssertEqual(m.half.y, 5, accuracy: 1e-12, "★ a side sets the diameter")
        XCTAssertEqual(m.half.z, 10, "its height untouched")
        let e = c.movingFace(2, isMax: false, to: -14, minSize: 0.1)
        XCTAssertEqual(e.half.z, 12, accuracy: 1e-12, "★ an end sets the height")
        XCTAssertEqual(e.half.x, 4, "its diameter untouched")
    }

    func testOnASquareBoxTheMagnetsAreTheDesignBoxs() {
        let faces = [plane(SIMD3(0, 0, 1), SIMD3(5, 5, 20)), plane(SIMD3(1, 0, 0), SIMD3(7, 0, 0)), plane(SIMD3(0, 0, -1), SIMD3(0, 0, 3))]
        let lo = SIMD3<Double>(-10, -10, 0), hi = SIMD3<Double>(10, 10, 30)
        let mine = PlacedBoxDetent.candidates(direction: SIMD3(0, 0, 1), faces: faces, partMin: lo, partMax: hi)
        let theirs = DesignBoxDetent.candidates(axis: 2, faces: faces, aabbMin: SIMD3<Float>(lo), aabbMax: SIMD3<Float>(hi))
        XCTAssertEqual(mine.map(Float.init), theirs, "★ the same snap planes as the Design Box")
        XCTAssertEqual(mine, [0, 3, 20, 30])
    }

    func testAFaceSnapsToThePartsFaceAndHoldsInsideTheReleaseBand() {
        let faces = [plane(SIMD3(0, 0, 1), SIMD3(0, 0, 20))]
        let lo = SIMD3<Double>(-50, -50, -50), hi = SIMD3<Double>(50, 50, 50)
        let b = PlacedBox(center: SIMD3(0, 0, 5), axes: square, half: SIMD3(2, 2, 5))
        let snap = PlacedBoxDetent.applyFaceDrag(b, axis: 2, isMax: true, rawTarget: 19, faces: faces, partMin: lo, partMax: hi,
                                                 current: nil, minSize: 0.1)
        XCTAssertEqual(snap.box.faceCoord(2, isMax: true), 20, accuracy: 1e-12, "★ within 1.5 mm, the top meets the part's face")
        XCTAssertTrue(snap.didSnap, "a fresh snap: flash and tick")
        XCTAssertEqual(snap.matchedFace, FaceID(0), "★ the face it met is the one to pulse")
        let held = PlacedBoxDetent.applyFaceDrag(b, axis: 2, isMax: true, rawTarget: 22.5, faces: faces, partMin: lo, partMax: hi,
                                                 current: snap.detent, minSize: 0.1)
        XCTAssertEqual(held.box.faceCoord(2, isMax: true), 20, accuracy: 1e-12, "★ held inside the 3 mm release band")
        XCTAssertFalse(held.didSnap, "no second tick while held")
        let free = PlacedBoxDetent.applyFaceDrag(b, axis: 2, isMax: true, rawTarget: 23.5, faces: faces, partMin: lo, partMax: hi,
                                                 current: held.detent, minSize: 0.1)
        XCTAssertEqual(free.box.faceCoord(2, isMax: true), 23.5, accuracy: 1e-9, "past the band, it lets go")
        XCTAssertNil(free.detent)
        let far = PlacedBoxDetent.applyFaceDrag(b, axis: 2, isMax: true, rawTarget: 17, faces: faces, partMin: lo, partMax: hi,
                                                current: nil, minSize: 0.1)
        XCTAssertNil(far.detent, "RED CONTROL: 3 mm away is free")
    }

    func testATurnedBoxSnapsToFacesFacingItsOwnWay() {
        let r = 1 / 2.0.squareRoot()
        let d = SIMD3<Double>(r, r, 0)   // turned 45° about z
        let axes = [d, SIMD3(-r, r, 0), SIMD3(0, 0, 1)]
        let faces = [plane(d, d * 10), plane(SIMD3(1, 0, 0), SIMD3(10, 0, 0))]
        let lo = SIMD3<Double>(-50, -50, -50), hi = SIMD3<Double>(50, 50, 50)
        let b = PlacedBox(center: .zero, axes: axes, half: SIMD3(3, 3, 3))
        let s = PlacedBoxDetent.applyFaceDrag(b, axis: 0, isMax: true, rawTarget: 9, faces: faces, partMin: lo, partMax: hi,
                                              current: nil, minSize: 0.1)
        XCTAssertEqual(s.box.faceCoord(0, isMax: true), 10, accuracy: 1e-9, "★ its face meets the part's face that faces its way")
        XCTAssertEqual(s.matchedFace, FaceID(0))
        XCTAssertFalse(PlacedBoxDetent.candidates(direction: d, faces: faces, partMin: lo, partMax: hi).contains { abs($0 - 7.071) < 0.01 },
                       "RED CONTROL: a face at 45° to it is no magnet")
    }

    func testHandlesAreTheDesignBoxsSeven() {
        let hs = PlacedBoxHandle.all("k")
        XCTAssertEqual(hs.map(\.frameKey), ["placedBox-k-move", "placedBox-k-u-", "placedBox-k-u+", "placedBox-k-v-", "placedBox-k-v+",
                                            "placedBox-k-w-", "placedBox-k-w+"], "★ the move dot and a square on each face")
        let b = PlacedBox(center: SIMD3(1, 2, 3), axes: square, half: SIMD3(1, 1, 1))
        XCTAssertEqual(hs[6].anchor(b), SIMD3(1, 2, 4), "the w+ square sits on the middle of its face")
        let chosen = PlacedBoxHandle.choose(at: CGPoint(x: 10, y: 10),
                                            among: [(hs[0], CGPoint(x: 0, y: 0)), (hs[1], CGPoint(x: 12, y: 12))], radius: 30)
        XCTAssertEqual(chosen, hs[1], "the nearest within reach")
        XCTAssertNil(PlacedBoxHandle.choose(at: CGPoint(x: 100, y: 100), among: [(hs[0], .zero)], radius: 30))
    }

    // MARK: his boxes, as placed boxes

    @MainActor func testAKeepClearBoxIsItsSlabAndWritesBack() throws {
        let p = ProjectModel(id: UUID(), name: "Box", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        let g = p.selection.addGroup()
        var mp = ManualPrimitive(kind: .face, center: SIMD3(0, 0, 10), axis: SIMD3(0, 0, 1), halfUMM: 4, halfWMM: 6)
        mp.override.slabDepthMM = 8
        _ = p.force.addManualPrimitive(mp, to: g)
        let b = p.manualPrimitiveBox(mp)
        XCTAssertEqual(b.faceCoord(2, isMax: false), 10, accuracy: 1e-9, "★ its face at the slab's face")
        XCTAssertEqual(b.faceCoord(2, isMax: true), 18, accuracy: 1e-9, "★ reaching out by its depth (core's slab)")
        p.setManualPrimitiveBox(mp.id, in: g, b.movingFace(2, isMax: true, to: 22, minSize: 0.1))
        let after = try XCTUnwrap(p.manualPrimitives(in: g).first)
        XCTAssertEqual(after.resolvedDepthMM, 12, accuracy: 1e-9, "★ the top square sets its depth")
        XCTAssertEqual(after.center.z, 10, accuracy: 1e-9, "its face stays")
        p.setManualPrimitiveBox(mp.id, in: g, p.manualPrimitiveBox(after).movingFace(0, isMax: true, to: 9, minSize: 0.1))
        let wider = try XCTUnwrap(p.manualPrimitives(in: g).first)
        XCTAssertEqual(wider.halfUMM, 6.5, accuracy: 1e-9, "★ a side square widens it, one side only")
        XCTAssertEqual(wider.resolvedDepthMM, 12, accuracy: 1e-9)
    }

    @MainActor func testAKeepClearCylinderIsItsBore() throws {
        let p = ProjectModel(id: UUID(), name: "Cyl", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        let g = p.selection.addGroup()
        let mp = ManualPrimitive(kind: .bolt, center: SIMD3(0, 0, 0), axis: SIMD3(0, 0, 1), radiusMM: 3, halfLengthMM: 5)
        _ = p.force.addManualPrimitive(mp, to: g)
        let b = p.manualPrimitiveBox(mp)
        XCTAssertTrue(b.isCylinder)
        p.setManualPrimitiveBox(mp.id, in: g, b.movingFace(1, isMax: true, to: 5, minSize: 0.1))
        let after = try XCTUnwrap(p.manualPrimitives(in: g).first)
        XCTAssertEqual(after.radiusMM, 4, accuracy: 1e-9, "★ a side square sets its diameter (3 + 5 across → 8)")
        XCTAssertEqual(after.halfLengthMM, 5, accuracy: 1e-9)
    }
}
