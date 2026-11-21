// OrganicVineOS1Tests — his pick 2026-11-21 13:00 EST: LatticeReview's engine (OS1 + OG2e + OG2f) goes in tonight and "the
// drawing follows the print file. Always." (his 11-19 rule) in the same install. OS1 (core weave_tubes.cpp, e95b7852):
// B, a bridge's rounded end is a PUCK (its section revolved about the vertical: a level underside at the bar's own underside
// height, its side straight up, the D's round top revolved), one per place, the wider kept; F, end kind 5 "continues": no
// ball, no flat end, the next run the same tube. RED CONTROLS: a round run's ends are whole balls; without kind 5 a
// continuing end is a ball.

import XCTest
import Metal
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class OrganicVineOS1Tests: XCTestCase {

    func run(_ pts: [SIMD3<Float>], width: Float = 1.0, section: UInt8 = 0, a: UInt8 = 0, b: UInt8 = 0) -> LatticeLayoutSession.Run {
        var r = LatticeLayoutSession.Run(region: 1, marks: [], endA: a, endB: b, points: pts,
                                         widthMM: [Float](repeating: width, count: pts.count),
                                         spacingMM: [Float](repeating: 4, count: pts.count))
        r.section = section
        return r
    }
    func puckPieces(_ s: OrganicVineShape) -> ArraySlice<OrganicVineShape.Piece> { s.pieces.suffix(s.pucks) }

    /// ★ OS1 B: a level D bridge's node ends: a vertical piece from the bar's underside up to its centre line (its bottom a
    /// flat disc, its top open into the dome) and the upper half of a ball of the bar's half width.
    func testALevelBridgesEndsArePucks() throws {
        let s = OrganicVineShape.tubes(runs: [run([SIMD3(0, 0, 5), SIMD3(4, 0, 5), SIMD3(8, 0, 5)], width: 1.0, section: 1)])
        XCTAssertEqual(s.pucks, 2)
        XCTAssertEqual(s.pieces.count, 2 + 2)
        for (q, x) in zip(puckPieces(s), [Float(0), 8]) {
            XCTAssertEqual(q.a, SIMD3(x, 0, 4.5), "★ its underside level with the bar's (c.z - r)")
            XCTAssertEqual(q.b, SIMD3(x, 0, 5), "★ its side straight up to the centre line")
            XCTAssertEqual(q.ra, 0.5); XCTAssertEqual(q.rb, 0.5)
            XCTAssertTrue(q.flatA, "★ a flat bottom: no dome under a bar")
            XCTAssertFalse(q.flatB, "its top is the dome")
            XCTAssertEqual(q.section, 0, "round in plan")
        }
        XCTAssertEqual(s.caps, [SIMD4(0, 0, 5, 0.5), SIMD4(8, 0, 5, 0.5)])
        XCTAssertEqual(s.capDomes, [true, true], "★ the D's round top revolved: the upper half of the ball")
        XCTAssertTrue(s.pieces[0].flatA && s.pieces[1].flatB, "the bar's own ends stay flat (the puck's back half lies inside)")
        XCTAssertEqual(OrganicVinePass.signedCaps(s).map(\.w), [-0.5, -0.5], "★ the GPU reads a dome by its negative radius")
        // RED CONTROL: a round run's node ends are whole balls
        let round = OrganicVineShape.tubes(runs: [run([SIMD3(0, 0, 5), SIMD3(4, 0, 5), SIMD3(8, 0, 5)])])
        XCTAssertEqual(round.pucks, 0)
        XCTAssertEqual(round.capDomes, [false, false])
        XCTAssertEqual(OrganicVinePass.signedCaps(round).map(\.w), [0.5, 0.5])
    }

    /// ★ A rising bridge: the underside at c.z - r * up.z (up.z the bar's horizontal share), as the file's puck. The square
    /// bar's puck is a flat-topped cylinder (its section revolved), no dome.
    func testARisingBridgeAndTheSquareBar() throws {
        let p: [SIMD3<Float>] = [SIMD3(0, 0, 5), SIMD3(4, 0, 6)]
        let upZ = 4 / Float(17).squareRoot()
        let d = OrganicVineShape.tubes(runs: [run(p, width: 1.0, section: 1)])
        let q = try XCTUnwrap(puckPieces(d).first)
        XCTAssertEqual(q.a.z, 5 - 0.5 * upZ, accuracy: 1e-5, "★ the bar's own underside height there")
        XCTAssertEqual(q.b.z, 5, accuracy: 1e-6)
        let sq = OrganicVineShape.tubes(runs: [run(p, width: 1.0, section: 2)])
        XCTAssertEqual(sq.pucks, 2)
        XCTAssertTrue(sq.caps.isEmpty, "★ the square bar's puck has a flat top, no dome")
        let s0 = try XCTUnwrap(puckPieces(sq).first)
        XCTAssertEqual(s0.a.z, 5 - 0.5 * upZ, accuracy: 1e-5)
        XCTAssertEqual(s0.b.z, 5 + 0.5 * upZ, accuracy: 1e-5, "★ up to the bar's top height (zb + 2 r up.z)")
        XCTAssertTrue(s0.flatA && s0.flatB)
    }

    /// ★ Where the file keeps a bridge's end flat: into the solid (1), cut flush by the surface (2 without proud), any other
    /// kind (LatticeReview 11-21: e.g. a dome its print check held flat); a proud surface end (2 with proud) is a puck.
    func testWhereABridgeEndStaysFlat() {
        let p: [SIMD3<Float>] = [SIMD3(0, 0, 5), SIMD3(4, 0, 5)]
        XCTAssertEqual(OrganicVineShape.tubes(runs: [run(p, section: 1, a: 1, b: 2)]).pucks, 0, "★ solid and flush ends: flat")
        XCTAssertEqual(OrganicVineShape.tubes(runs: [run(p, section: 1, a: 6, b: 9)]).pucks, 0, "★ an unknown kind: flat")
        var proud = run(p, section: 1, a: 1, b: 2)
        proud.proudB = 0.3
        let s = OrganicVineShape.tubes(runs: [proud])
        XCTAssertEqual(s.pucks, 1, "★ a proud end is rounded")
        XCTAssertEqual(s.caps.first.map { SIMD3($0.x, $0.y, $0.z) }, p[1])
        XCTAssertTrue(s.pieces[0].flatA && s.pieces[0].flatB)
        // R2: a dome the print check held flat (the Exact preview's list) is drawn flat
        let held = OrganicVineShape.tubes(runs: [run(p, section: 1)], heldFlat: [p[1] + SIMD3(0, 0, 5e-5)])
        XCTAssertEqual(held.pucks, 1, "★ the listed end flat, the other a puck")
        XCTAssertEqual(held.caps.map { SIMD3($0.x, $0.y, $0.z) }, [p[0]])
        // loose (3) and joined (4) ends are rounded, as a round tube's
        XCTAssertEqual(OrganicVineShape.tubes(runs: [run(p, section: 1, a: 3, b: 4)]).pucks, 2)
    }

    /// ★ One puck per place, the wider kept (two bridges ending at one point); a sharp turn inside a bridge splits it with a
    /// puck there, its two pieces flat at the split.
    func testOnePuckPerPlaceAndAtASharpSplit() {
        let corner = OrganicVineShape.tubes(runs: [run([SIMD3(0, 0, 5), SIMD3(8, 0, 5)], width: 1.0, section: 1),
                                                   run([SIMD3(8, 0, 5), SIMD3(8, 8, 5)], width: 1.2, section: 1)])
        XCTAssertEqual(corner.pucks, 3, "★ the shared corner has ONE puck")
        let at = corner.caps.filter { SIMD3($0.x, $0.y, $0.z) == SIMD3(8, 0, 5) }
        XCTAssertEqual(at.map(\.w), [0.6], "★ the wider kept")
        let bent = OrganicVineShape.tubes(runs: [run([SIMD3(0, 0, 5), SIMD3(4, 0, 5), SIMD3(4, 4, 5)], section: 1)])
        XCTAssertEqual(bent.pucks, 3, "★ both ends and the 90-degree split")
        XCTAssertTrue(bent.pieces[0].flatB && bent.pieces[1].flatA, "the pieces flat at the split")
        XCTAssertTrue(bent.caps.contains { SIMD3($0.x, $0.y, $0.z) == SIMD3(4, 0, 5) })
    }

    /// ★ OS1 F: a run whose end continues (kind 5) is the same tube as the next run: no ball, no flat end, one mitre ring.
    func testAContinuingRunIsOneTubeWithTheNext() {
        let c = SIMD3<Float>(8, 0, 0)
        let next = c + SIMD3(4 * cos(Float.pi / 6), 4 * sin(Float.pi / 6), 0)
        let r1 = run([SIMD3(0, 0, 0), SIMD3(4, 0, 0), c], b: 5), r2 = run([c, next], a: 5)
        let s = OrganicVineShape.tubes(runs: [r1, r2])
        XCTAssertFalse(s.caps.contains { simd_length(SIMD3($0.x, $0.y, $0.z) - c) < 1e-5 }, "★ no ball where the tube goes on")
        let end1 = s.pieces[1], start2 = s.pieces[2]
        XCTAssertFalse(end1.flatB || start2.flatA, "★ no flat end there either")
        XCTAssertLessThan(simd_length(end1.tb - start2.ta), 1e-5, "★ one mitre plane")
        var worst: Float = 0
        for k in 0..<16 {
            let ang = Float(k) * 2 * .pi / 16
            worst = Swift.max(worst, simd_length(OrganicVineShape.tubeRingPoint(end1, atB: true, angle: ang)
                                                 - OrganicVineShape.tubeRingPoint(start2, atB: false, angle: ang)))
        }
        XCTAssertLessThan(worst, 1e-4, "★ the two runs' rings are one ring (no crack, no twist)")
        // a bridge continuing: no puck there
        let b = OrganicVineShape.tubes(runs: [run([SIMD3(0, 0, 0), c], section: 1, b: 5), run([c, next], section: 1, a: 5)])
        XCTAssertEqual(b.pucks, 2, "★ pucks at the two real ends only")
        XCTAssertFalse(b.caps.contains { simd_length(SIMD3($0.x, $0.y, $0.z) - c) < 1e-5 })
        // a continuing end with no run to go on into: closed flat, never an open hole
        let alone = OrganicVineShape.tubes(runs: [r1])
        XCTAssertTrue(alone.pieces[1].flatB)
        XCTAssertFalse(alone.caps.contains { simd_length(SIMD3($0.x, $0.y, $0.z) - c) < 1e-5 })
        // RED CONTROL: the same runs without kind 5: a ball at each run's end there
        let split = OrganicVineShape.tubes(runs: [run([SIMD3(0, 0, 0), SIMD3(4, 0, 0), c]), run([c, next])])
        XCTAssertEqual(split.caps.filter { simd_length(SIMD3($0.x, $0.y, $0.z) - c) < 1e-5 }.count, 2)
    }

    /// ★ On the app's renderer, seen from the side (z up on screen): the dome top alone is the upper half of the ball (the
    /// shader drops its lower half); with its wall the end is square below (the bar's flat underside to its very end), so it
    /// covers more than a whole ball. RED CONTROL: the same caps drawn as whole balls.
    @MainActor func testThePuckOnTheRenderer() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")") }
        let runs = [run([SIMD3(2, 0, 5), SIMD3(8, 0, 5)], width: 2.0, section: 1)]
        let puck = OrganicVineShape.tubes(runs: runs)
        XCTAssertEqual(puck.pucks, 2)
        var domeOnly = puck
        domeOnly.pieces.removeLast(puck.pucks); domeOnly.pucks = 0
        var ballOnly = domeOnly
        ballOnly.capDomes = ballOnly.capDomes.map { _ in false }
        // a box round the bar to frame it, drawn clear
        let v: [Float] = [0, -3, 2, 10, -3, 2, 10, 3, 2, 0, 3, 2, 0, -3, 8, 10, -3, 8, 10, 3, 8, 0, 3, 8]
        let idx: [Int32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
        r.setMesh(ViewerMesh(vertices: v, indices: idx, faceIDs: [Int32](repeating: 1, count: idx.count / 3)))
        r.setBodyAlpha(0)
        r.camera.target = SIMD3(5, 0, 5)
        let clear = MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        let seg = LatticeLayoutPreview.segments(runs)
        var token = 40
        func covered(_ shape: OrganicVineShape) throws -> Int {
            r.camera.setOrientation(azimuth: 0, elevation: 1.5)   // looking down the y axis: x across, z up the screen
            token += 1
            var bars = LatticeLayoutBarsInputs(token: token, bars: seg.bars, flags: seg.flags)
            bars.vines = shape
            XCTAssertTrue(r.applyLayoutBars(bars, device: device))
            XCTAssertNil(OrganicVinePass.lastInitError, "★ the dome's shader builds")
            let f = try XCTUnwrap(r.renderOffscreen(width: 600, height: 600, clear: clear, stage: false))
            let bg = Array(f[0..<4])
            return stride(from: 0, to: f.count, by: 4).filter { Array(f[$0..<$0 + 4]) != bg }.count
        }
        let withWall = try covered(puck), dome = try covered(domeOnly), ball = try covered(ballOnly)
        print("VINE PUCK: the end with its wall \(withWall), the dome top alone \(dome), whole balls \(ball) pixels")
        XCTAssertGreaterThan(dome, 1_000, "premise: on screen")
        XCTAssertLessThan(dome, ball, "★ the dome is the ball's upper half (its lower half beyond the bar's end is gone)")
        XCTAssertGreaterThan(withWall, ball, "★ with its wall the end is square below: the flat underside to its very end")
    }
}
