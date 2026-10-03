// FlexibleBatchMGroupTests — his round-5 M1 (img 4): "The animation is weird. When in group 1, it
// showed group 2's animation. When set on group 2, it should group 2 as a negative? I don't
// understand?" — on HIS round-5 project (Group 1 = Top A + Top B + Face 5's thumb, Group 2 = Face 3's
// four fingertips), task 2026-09-29-flexible-screens, round 5 batch M. For EVERY group, picked on
// the main page:
//   * the renderer binds that group's OWN field (the pass's swap, as the frame runs) and the page
//     hands that field's own mesh (H4) — RED: the other group's field (the index swapped);
//   * at full load its pressed faces move INTO the part — RED: the sign flipped;
//   * the column fallback (a failed sim) presses them in too — RED: flipped.
//   * "Play all" plays each group alone, in turn, and names it (the loop's playing sim).
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchMGroupTests: XCTestCase {

    /// His round-5 project through Save & Exit, every sim landed.
    func round5() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(300, "his round 5: the sims") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        stage.refresh()
        return (r, stage, m)
    }

    /// A face's mean motion INTO the part (along its load) over its map quads, under `dents` at ×1.
    static func inward(_ dents: [Float], _ o: FlexibleOverlayMesh, _ k: FlexFaceKey, _ st: FlexStackInfo) -> Double {
        guard let start = o.flatStart[k] else { return 0 }
        let load = SIMD3<Float>(st.load)
        var sum = 0.0, n = 0
        for v in start..<(start + 6 * st.columns.count) where 3 * v + 2 < dents.count {
            sum += Double(simd_dot(SIMD3(dents[3 * v], dents[3 * v + 1], dents[3 * v + 2]), load)); n += 1
        }
        return n > 0 ? sum / Double(n) : 0
    }

    func testEachGroupPlaysItsOwnSimAndPressesItsFacesIntoThePart() async throws {
        let (r, stage, m) = try await round5()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let o = try XCTUnwrap(stage.overlay)
        let groups = m.squishSims.map(\.sim.id)
        XCTAssertEqual(groups, ["group-1", "group-2"])
        for g in groups {
            stage.pick(g)
            stage.refresh()
            let layer = try XCTUnwrap(stage.layer(r.project, stage: .lattice, pageUp: false))
            XCTAssertEqual(layer.feSequence.count, 1, "\(g): one sim plays")
            let i = layer.feSequence[0], other = 1 - i
            XCTAssertEqual(layer.fe[i].simID, g, "\(g): the page asks for ITS field")
            // the renderer, as a frame runs: its swap binds the group's field and mesh
            let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
            mr.setMesh(try XCTUnwrap(stage.mesh(r.project, on: .lattice)))
            mr.applyFlexibleLattice(layer, device: device)
            mr.stepFlexibleFE(stage.loop, now: stage.loop.clock())
            let pass = try XCTUnwrap(mr.flexibleLattice)
            XCTAssertEqual(pass.feFields[pass.feShown].simID, g, "\(g): the renderer binds ITS field")
            XCTAssertEqual(stage.loop.playingSimID, g, "\(g): …and the player names it")
            let dents = try XCTUnwrap(stage.dents(r.project, on: .lattice))
            XCTAssertEqual(dents, layer.feMesh[i], "\(g): H4 hands the same field's mesh")
            // its pressed faces move INTO the part; the other group's field leaves them (nearly) still
            let own = try XCTUnwrap(m.lattice?.sims.first { $0.id == g }).keys
            var line = "FLEX-M GROUP \(g) at ×1 (full load):"
            var ownIn = 0.0, swapped = 0.0, flipped = 0.0
            for k in own {
                let st = try XCTUnwrap(m.stacks[k])
                let a = Self.inward(dents, o, k, st)
                let b = Self.inward(layer.feMesh[other], o, k, st)
                let c = Self.inward(dents.map { -$0 }, o, k, st)
                line += String(format: " · face %d in %.3f mm (the other group's field %.3f)", k.region, a, b)
                XCTAssertGreaterThan(a, 0, "\(g): face \(k.region) moves INTO the part")
                ownIn += a; swapped += b; flipped += c
            }
            print(line)
            // ★ RED CONTROLS: the other group's field (the index swapped) barely presses these faces; the
            // flipped sign pulls them out
            XCTAssertLessThan(swapped, 0.5 * ownIn, "\(g): control: the swapped field is not this group's squeeze")
            XCTAssertLessThan(flipped, 0, "\(g): control: the flipped field pulls its faces OUT")
            // the column fallback (a failed sim) presses its faces in too
            stage.controlColumnSquish = true
            stage.refresh()
            let column = try XCTUnwrap(stage.dents(r.project, on: .lattice))
            for k in own where stage.drawn?.squishedKeys.contains(k) == true {
                let st = try XCTUnwrap(m.stacks[k])
                XCTAssertGreaterThan(Self.inward(column, o, k, st), 0, "\(g): the column squish presses face \(k.region) in")
                XCTAssertLessThan(Self.inward(column.map { -$0 }, o, k, st), 0, "control: flipped")
            }
            stage.controlColumnSquish = false
            stage.refresh()
        }
        // "Play all": each group ALONE, in turn, named
        stage.pick(FlexibleSim.allID)
        stage.refresh()
        let layer = try XCTUnwrap(stage.layer(r.project, stage: .lattice, pageUp: false))
        XCTAssertEqual(layer.feSequence.count, 2, "Play all plays both groups")
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
        mr.setMesh(try XCTUnwrap(stage.mesh(r.project, on: .lattice)))
        mr.applyFlexibleLattice(layer, device: device)
        var t = 1000.0
        stage.loop.clock = { t }
        stage.loop.restartFromRest(reduceMotion: false)
        var named: [String] = []
        for cycle in 0..<4 {
            t = 1000.0 + (Double(cycle) + 0.02) * FlexibleSquishLoop.periodS
            mr.stepFlexibleFE(stage.loop, now: t)
            let pass = try XCTUnwrap(mr.flexibleLattice)
            named.append(stage.loop.playingSimID ?? "-")
            XCTAssertEqual(pass.feFields[pass.feShown].simID, stage.loop.playingSimID, "the bound field is the one named")
        }
        print("FLEX-M PLAY ALL turns: \(named)")
        XCTAssertEqual(named, ["group-1", "group-2", "group-1", "group-2"], "each group alone, in turn")
    }
}
#endif
