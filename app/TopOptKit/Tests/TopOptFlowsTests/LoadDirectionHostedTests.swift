// LoadDirectionHostedTests — B3, ledger note 5 (approved design 2026-11-02, plan.md §B3, mockup #topo-setup-load): "Need to
// add a way to manually set the Push/Pull direction of a load".
//
// An open Load group shows Kind · Weight · Direction. Direction: Into the face · Along X / Y / Z · Pick on the part · Flipped;
// the arrow carries a round handle at its free end that aims it in 15° steps, snapping onto an axis; the exact angles sit
// behind Details. The job already carries a force vector per load group: it points where he aimed it. plan.md's test: pick
// Along Z → the job's force vector is (0, 0, −F); drag the handle 15° → the vector turns 15°. (A synthesised drag never
// reaches a gesture in the offscreen window, so the drag is its maths through the handle's own functions; the clicks are
// real.) RED before B3 (saved: scratchpad b2red/LoadDirection.txt): no Kind / Weight / Direction rows, no aim.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LoadDirectionHostedTests: XCTestCase {

    func page(_ size: CGSize = AppBuildHost.landscape13) throws -> (AppBuildHost, ProjectModel, AppModel, UUID) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" }).id   // his 10 kg load on the pad's top
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p, r.app, top)
    }

    /// The load's force in the job (N), from the request the Mac would get.
    func jobForce(_ app: AppModel, _ p: ProjectModel, _ id: UUID) throws -> SIMD3<Double> {
        let faces = try XCTUnwrap(p.selection.groups.first { $0.id == id }).faces.map { Int(p.runFaceID($0)) }
        let g = try XCTUnwrap(try XCTUnwrap(app.makeRunRequest(lattice: false)).loadGroups.first { $0.faceIDs == faces })
        return g.force
    }

    func angleDeg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi
    }

    func testKindWeightAndDirectionAndAlongZ() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let (h, p, app, top) = try page(size)
            let what = "\(size)"
            try h.tap("selGroup-\(top.uuidString)", "\(what): Top's row")
            XCTAssertEqual(p.selection.activeGroupID, top)
            // Gravity: Direction stays, greyed, with its one-tap fix (U6)
            XCTAssertEqual(p.force.kind(for: top).loadDirection, .gravity, "premise: his Top is a Gravity load")
            h.scrollIntoList("loadKind-push-\(top.uuidString)")
            _ = try h.probe("loadKind-push-\(top.uuidString)", "\(what): ★ Kind's Push", minHit: 44)
            h.scrollIntoList("loadDirectionFix-\(top.uuidString)")
            let fix = try h.probe("loadDirectionFix-\(top.uuidString)", "\(what): ★ Choose Push, beside 'Follows gravity'", minHit: 44)
            h.click(CGPoint(x: fix.midX, y: fix.midY))
            XCTAssertEqual(p.force.kind(for: top).loadDirection, .push, "\(what): ★ the fix makes it a Push")
            // Weight is a number field here too
            _ = try h.onScreen("numberField-loadWeight-\(top.uuidString)", "\(what): ★ Weight")
            // ★ Along Z: (0, 0, −F)
            h.scrollIntoList("loadDirection-\(top.uuidString)")
            let offered = try h.pickFromMenu("loadDirection-\(top.uuidString)", "Along Z", what: "\(what): Direction")
            XCTAssertEqual(offered.prefix(5).map { $0 }, ["Into the face", "Along X", "Along Y", "Along Z", "Pick on the part"],
                           "\(what): ★ the design's choices")
            XCTAssertTrue(offered.contains { $0.hasPrefix("Flipped") }, "\(what): and Flipped")
            XCTAssertEqual(p.force.aim(for: top), .axis(2))
            let F = 10 * ForceModel.gravityAccel
            let f = try jobForce(app, p, top)
            XCTAssertEqual(f.x, 0, accuracy: 1e-3); XCTAssertEqual(f.y, 0, accuracy: 1e-3)
            XCTAssertEqual(f.z, -F, accuracy: 1e-3, "\(what): ★ Along Z sends (0, 0, −F)")
            // ★ Flipped reverses it
            p.force.setFlipped(top, true)
            XCTAssertEqual(try jobForce(app, p, top).z, F, accuracy: 1e-3, "\(what): ★ Flipped")
            p.force.setFlipped(top, false)
            // the handle is on the arrow's free end, a 44 pt target
            let handle = try h.probe("aimHandle-\(top.uuidString)", "\(what): ★ the arrow's round handle", minHit: 44)
            XCTAssertLessThanOrEqual(handle.width, 44.5, "\(what): ★ only the ring takes the touch — the model still orbits around it")
            XCTAssertLessThanOrEqual(handle.height, 44.5)
        }
    }

    /// The handle's drag, through its own maths: the free end turned 15° on screen (camera square to the turn) turns the job's
    /// vector 15°; a drag within 7.5° of an axis lands on it.
    func testAFifteenDegreeDragTurnsTheVectorFifteenDegrees() throws {
        let (_, p, app, top) = try page()
        p.force.setDirection(top, .push)
        p.force.setAim(top, .axis(2))
        let before = try jobForce(app, p, top)
        // an orthographic camera looking along +Y at the XZ plane: screen x = world x, screen up = world z
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(0.01, 0, 0, 0)          // x → ndc x
        m.columns.1 = SIMD4(0, 0, 0.0005, 0)        // y → depth
        m.columns.2 = SIMD4(0, 0.01, 0, 0)          // z → ndc y
        m.columns.3 = SIMD4(0, 0, 0.5, 1)
        let proj = CameraProjection(viewProjection: m, viewportSize: CGSize(width: 1000, height: 1000))
        let base = SIMD3<Float>(0, 0, 0), screenBase = try XCTUnwrap(proj.project(base))
        // the free end (a Push presses in: its tail, above the face), turned 15° on screen
        let L: CGFloat = 74, t = 15 * CGFloat.pi / 180
        let finger = CGPoint(x: screenBase.x + L * sin(t), y: screenBase.y - L * cos(t))
        let world = try XCTUnwrap(LoadAimMath.dragged(finger: finger, base: base, into: true, projection: proj))
        let nm = SIMD3<Float>(0, 0, 1)   // the pad's top
        p.force.setAim(top, LoadAimMath.stepped(world, base: -nm))
        let after = try jobForce(app, p, top)
        XCTAssertEqual(angleDeg(before, after), 15, accuracy: 0.01, "★ the vector turns 15°")
        XCTAssertEqual(simd_length(after), simd_length(before), accuracy: 1e-3, "and keeps its size")
        // a 5° drag snaps back onto the axis
        let near = CGPoint(x: screenBase.x + L * sin(5 * .pi / 180), y: screenBase.y - L * cos(5 * .pi / 180))
        let w2 = try XCTUnwrap(LoadAimMath.dragged(finger: near, base: base, into: true, projection: proj))
        XCTAssertEqual(LoadAimMath.stepped(w2, base: -nm), .face, "★ within 7.5° of the face (here −Z): on it")
        // Details: the exact angles, typed
        let d = LoadAimMath.direction(fromFace: 37, around: 90, base: -nm)
        XCTAssertEqual(LoadAimMath.angles(of: d, base: -nm).fromFace, 37, accuracy: 0.01)
        XCTAssertEqual(LoadAimMath.angles(of: d, base: -nm).around, 90, accuracy: 0.01)
    }

    /// The sense rule and the bytes: an axis keeps the Kind's sense; no aim sends today's vector; a project with no aim
    /// encodes no aim keys.
    func testTheSenseRuleAndNoAimIsTodaysJob() throws {
        let up = SIMD3<Float>(0, 0, 1), side = SIMD3<Float>(1, 0, 0)
        XCTAssertEqual(LoadAimMath.direction(.push, faceNormal: up, aim: .axis(2), flipped: false), SIMD3(0, 0, -1), "push on a top face")
        XCTAssertEqual(LoadAimMath.direction(.pull, faceNormal: up, aim: .axis(2), flipped: false), SIMD3(0, 0, 1), "pull draws away")
        XCTAssertEqual(LoadAimMath.direction(.push, faceNormal: side, aim: .axis(2), flipped: false), SIMD3(0, 0, -1), "side-on: −axis")
        XCTAssertEqual(LoadAimMath.direction(.push, faceNormal: side, aim: .axis(0), flipped: true), SIMD3(1, 0, 0), "flipped")
        XCTAssertNil(LoadAimMath.direction(.gravity, faceNormal: up, aim: .axis(0), flipped: false), "gravity follows gravity")
        let (_, p, app, top) = try page()
        p.force.setDirection(top, .push)
        let today = try jobForce(app, p, top)
        p.force.setAim(top, .face); p.force.setFlipped(top, false)
        XCTAssertEqual(try jobForce(app, p, top), today)
        let text = String(decoding: try JSONEncoder().encode(p.force), as: UTF8.self)
        XCTAssertFalse(text.contains("loadAims") || text.contains("loadFlips"), "★ no aim: nothing new is stored")
        p.force.setAim(top, .axis(0))
        let back = try JSONDecoder().decode(ForceModel.self, from: JSONEncoder().encode(p.force))
        XCTAssertEqual(back.aim(for: top), .axis(0), "the aim survives a relaunch")
    }
}
#endif
