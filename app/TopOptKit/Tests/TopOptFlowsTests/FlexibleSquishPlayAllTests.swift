// FlexibleSquishPlayAllTests — "Play all" plays the squeeze groups ONE AFTER ANOTHER (task
// 2026-09-29-flexible-screens, round 5 batch G, §7; his words: "I'd like a way to play the
// different sims if there are multiple ways to squeeze/squish a model"). Each with a RED control:
//   * the loop's cycle picks the group: 0, 1, 2, 0 …, and every change happens at rest — RED: D2's
//     all-at-once (one sequence entry) plays group 0 throughout;
//   * pause, scrub and play keep the group on screen — RED: the anchor without the held cycle;
//   * the renderer swaps the field AND the mesh in the same step, at the cycle's start — RED: the
//     mesh a frame late;
//   * nothing publishes while Play all plays — RED: a publish per wrap;
//   * the picker lists each group, then "Play all", which is the default — RED: D2's list.
#if canImport(MetalKit)
import XCTest
import Combine
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSquishPlayAllTests: XCTestCase {

    typealias Fx = FlexibleLatticeFixtures
    let P = FlexibleSquishLoop.periodS

    func testPlayAllPlaysTheGroupsInTurn() {
        let loop = FlexibleSquishLoop()
        var t: CFTimeInterval = 100
        loop.clock = { t }
        loop.sequenceCount = 3
        loop.restartFromRest(reduceMotion: false)
        var got: [Int] = []
        for n in [0.5, 1.5, 2.5, 3.5] { got.append(loop.simIndex(at: 100 + n * P)) }
        XCTAssertEqual(got, [0, 1, 2, 0], "each group in turn, then round again")
        // every change of group happens at rest
        var worst = 0.0, changes = 0
        var last = loop.simIndex(at: 100)
        for i in 1...4000 {
            t = 100 + Double(i) * P / 1000
            let now = loop.simIndex(at: t)
            if now != last { changes += 1; worst = max(worst, loop.amount(at: t)) }
            last = now
        }
        print("FLEX-G PLAYALL: indices at ½, 1½, 2½, 3½ periods \(got) · \(changes) changes over 4 periods, the largest amount at a change \(worst)")
        XCTAssertEqual(changes, 3)
        XCTAssertLessThanOrEqual(worst, 1e-3, "a swap never lands mid-squeeze")
        // ★ RED CONTROL: D2's "All at once" — one entry, group 0 throughout
        let d2 = FlexibleSquishLoop()
        d2.clock = { t }
        d2.restartFromRest(reduceMotion: false)
        XCTAssertEqual([0.5, 1.5, 2.5, 3.5].map { d2.simIndex(at: t + $0 * P) }, [0, 0, 0, 0], "control: all at once never takes turns")
    }

    func testPauseScrubAndPlayKeepTheGroup() {
        let loop = FlexibleSquishLoop()
        var t: CFTimeInterval = 50
        loop.clock = { t }
        loop.sequenceCount = 2
        loop.restartFromRest(reduceMotion: false)
        t = 50 + 1.3 * P   // group 2, rising
        XCTAssertEqual(loop.simIndex(at: t), 1)
        loop.pause()
        let held = loop.held
        t += 10 * P
        XCTAssertEqual(loop.simIndex(at: t), 1, "paused in group 2: it stays")
        loop.scrub(to: 0.4)
        XCTAssertEqual(loop.simIndex(at: t), 1, "a drag keeps the group")
        loop.play()
        XCTAssertEqual(loop.simIndex(at: t), 1, "play resumes in group 2")
        XCTAssertEqual(loop.amount(at: t), 0.4, accuracy: 1e-9, "…from the held amount")
        t += 0.05 * P
        XCTAssertEqual(loop.simIndex(at: t), 1)
        print("FLEX-G PLAYALL pause at 1.3 P: held \(held) · group \(loop.simIndex(at: t)) after scrub + play")
        // ★ RED CONTROL: the pre-G play() anchored on the rising phase alone — cycle 0, group 1
        XCTAssertEqual(Int(FlexibleSquishLoop.risingPhase(0.4).rounded(.down)) % 2, 0, "control: without the held cycle it jumps to group 0")
    }

    /// A field whose every node moves `d` (so its mesh is recognisable).
    func uniformField(_ id: String, _ d: SIMD3<Float>) -> FlexibleFEField {
        FlexibleFEField(simID: id, generation: 1, nx: 3, ny: 3, nz: 3, origin: SIMD3(-1, -1, -1), spacing: 25,
                        u: [SIMD3<Float>](repeating: d, count: 27))
    }

    func testRendererSwapsFieldAndMeshTogether() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        let n = box.mesh.flat.vertexCount * 3
        let meshA = [Float](repeating: 0.1, count: n), meshB = [Float](repeating: 0.2, count: n)
        let loop = FlexibleSquishLoop()
        var t: CFTimeInterval = 10
        loop.clock = { t }
        var l = FlexibleLatticeLayerInputs(lattice: Fx.boxInputs(.gyroid), faces: [], token: 1, loop: loop)
        l.fe = [uniformField("group-1", SIMD3(0, 0, -1)), uniformField("group-2", SIMD3(1, 0, 0))]
        l.feMesh = [meshA, meshB]; l.feSequence = [0, 1]; l.feToken = 3
        r.applyFlexibleLattice(l, device: device)
        let pass = try XCTUnwrap(r.flexibleLattice)
        loop.sequenceCount = 2
        loop.restartFromRest(reduceMotion: false)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        var log: [String] = []
        func step(_ at: Double) {
            t = 10 + at * P
            r.stepFlexibleLoop(in: view, now: t)
            log.append(String(format: "t %.3fP: field %d mesh %d loop %d", at, pass.feShown, pass.feMeshShown, loop.shownIndex))
        }
        step(0.5)
        XCTAssertEqual([pass.feShown, pass.feMeshShown, loop.shownIndex], [0, 0, 0], "the first group bound, its mesh with it")
        step(0.999)
        XCTAssertEqual(pass.feShown, 0, "no swap mid-cycle")
        step(1.001)
        XCTAssertEqual(pass.feShown, 1, "the next cycle: group 2")
        XCTAssertEqual(pass.feMeshShown, 1, "…its mesh in the SAME step")
        XCTAssertEqual(loop.shownIndex, 1, "…and the page's H4 learns it")
        // a group landing mid-cycle (the sequence grows) never pops the one on screen
        l.fe.append(uniformField("group-3", SIMD3(0, 1, 0))); l.feMesh.append(meshA); l.feSequence = [0, 1, 2]; l.feToken = 4
        r.applyFlexibleLattice(l, device: device)
        step(1.5)
        XCTAssertEqual(pass.feShown, 1, "the field on screen stays until the next rest")
        // ★ RED CONTROL: the mesh swapped a frame late — the step shows the new field on the old mesh
        pass.controlSwapMeshNextFrame = true
        step(2.001)
        let mismatch = pass.feShown != pass.feMeshShown
        step(2.01)
        print("FLEX-G SWAP: " + log.joined(separator: " | ") + " · control (mesh a frame late) mismatch \(mismatch)")
        XCTAssertTrue(mismatch, "control: a late mesh is a one-frame mismatch")
        XCTAssertEqual(pass.feShown, pass.feMeshShown, "(the late mesh arrives the next frame)")
    }

    func testNoPublishWhilePlayingAll() {
        let stage = FlexibleMainStage()
        var t: CFTimeInterval = 100
        stage.loop.clock = { t }
        var fired = 0
        let c = stage.objectWillChange.sink { _ in fired += 1 }
        stage.loop.exaggeration = 2
        stage.loop.sequenceCount = 3
        stage.loop.restartFromRest(reduceMotion: false)
        var indices = Set<Int>()
        for _ in 0..<Int(3.5 * P * 30) {   // three and a half periods at 30 fps: the renderer's steps
            t += 1.0 / 30.0
            _ = stage.loop.scale(at: t)
            indices.insert(stage.loop.simIndex(at: t))
            stage.loop.shownIndex = stage.loop.simIndex(at: t)
        }
        c.cancel()
        print("FLEX-G PLAYALL 3½ periods (3 wraps): the stage publishes \(fired) · groups shown \(indices.sorted())")
        XCTAssertEqual(fired, 0, "Play all is stepped by the renderer, never published")
        XCTAssertEqual(indices, [0, 1, 2])
        // ★ RED CONTROL: a stage that publishes each wrap fires 3 times over three periods
        final class Publishing: ObservableObject { @Published var group = 0 }
        let p = Publishing()
        var red = 0
        let c2 = p.objectWillChange.sink { _ in red += 1 }
        var last = 0
        t = 100
        for _ in 0..<Int(3.5 * P * 30) {
            t += 1.0 / 30.0
            let g = stage.loop.simIndex(at: t)
            if g != last { p.group = g; last = g }
        }
        c2.cancel()
        XCTAssertEqual(red, 3, "control: publishing per wrap fires once per wrap (3)")
    }

    func testPickerListsGroupsThenPlayAll() throws {
        var s = FlexibleSqueezeGroupsTests.his()
        func sims() -> [FlexibleSim] {
            FlexibleSqueezeGroups.sims(FlexibleSqueezeGroups.groups(s), key: { FlexFaceKey(region: $0, rotation: 0) },
                                       area: { k in [3: 2031.0, 5: 2031.0][k.region] ?? 5000 },
                                       name: { [FlexibleHisProject.topA: "Top A", FlexibleHisProject.topB: "Top B"][$0] ?? "Face \($0)" })
        }
        let one = sims()
        let lattice1 = FlexibleGeneratedLattice(inputs: Fx.boxInputs(.gyroid), faces: [], topology: "gyroid", tempC: 220, settingsKey: 0, sims: one)
        XCTAssertEqual(one.count, 1)
        XCTAssertNil(lattice1.defaultSimID, "one group: nothing to pick (no picker)")
        _ = FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
        FlexibleSqueezeGroups.move(5, to: FlexibleSqueezeGroups.group(of: 3, in: s)!.id, in: &s)
        let two = sims()
        let lattice2 = FlexibleGeneratedLattice(inputs: Fx.boxInputs(.gyroid), faces: [], topology: "gyroid", tempC: 220, settingsKey: 0, sims: two)
        print("FLEX-G PICKER: \(two.map(\.title)) · default '\(lattice2.defaultSimID ?? "-")'")
        XCTAssertEqual(two.map(\.title), ["Group 1 · Top A + Top B", "Group 2 · Face 3 + Face 5", "Play all"])
        XCTAssertEqual(lattice2.defaultSimID, "all", "Play all is the default")
        XCTAssertEqual(lattice2.showing(nil).shownSim?.kind, .playAll)
        // ★ RED CONTROL: D2's list and default
        XCTAssertNotEqual(two.map(\.title), ["Group 1 · Top A + Top B", "Group 2 · Face 3 + Face 5", "All at once"], "control: D2's 'All at once'")
        XCTAssertNotEqual(lattice2.defaultSimID, "group-1", "control: D2's default was group 1")
    }
}
#endif
