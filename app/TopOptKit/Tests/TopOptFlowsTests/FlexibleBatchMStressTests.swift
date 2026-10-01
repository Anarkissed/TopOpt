// FlexibleBatchMStressTests — his round-5 M3 (img 4): "Stress is not able to simulate; I imagine it
// should simulate the group that is playing/selected" — task 2026-09-29-flexible-screens, round 5
// batch M.
//   * WHY it failed on his pad: his 'Top' group presses a UNION region (105: top A + top B), which
//     reaches core with no faces — core refuses the whole solid solve (documented; #354's region
//     mapping, outside the track).
//   * Stress is now each group's OWN sim: von Mises from its displacement and each element's modulus
//     (FlexibleFEStress) — exact on a known strain; RED: the calibrated u (k not taken out), or one
//     modulus for all.
//   * On his project it follows the picker — the colours, the legend, a tap, the walls are the shown
//     group's; RED: the other group's field.
//   * A failed sim says why in ONE line with Retry, and Retry re-runs it without rebuilding the
//     lattice; RED: the request released (batch G) — the lattice is rebuilt.
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchMStressTests: XCTestCase {

    // MARK: the formula, on known strains

    /// A field on a 3×3×3-node grid (2×2×2 elements), u = f(node position), every element E.
    static func field(_ u: (SIMD3<Float>) -> SIMD3<Float>, e: Float = 2, h: Float = 1.5) -> FlexibleFEField {
        var us: [SIMD3<Float>] = []
        for c in 0..<3 { for b in 0..<3 { for a in 0..<3 { us.append(u(SIMD3(Float(a), Float(b), Float(c)) * h)) } } }
        return FlexibleFEField(simID: "t", generation: 0, nx: 3, ny: 3, nz: 3, origin: .zero, spacing: h, u: us,
                               elementE: [Float](repeating: e, count: 8))
    }

    func testVonMisesOfKnownStrainsFromTheRawFieldAndEachElementsModulus() throws {
        let nu = FlexibleFE.poisson, eps = 0.01, E = 2.0
        // uniaxial strain: u = (0, 0, −ε z) ⇒ σzz − σxx = 2μ ε ⇒ VM = E ε / (1 + ν)
        let uni = Self.field { SIMD3(0, 0, -Float(eps) * $0.z) }
        let a = try XCTUnwrap(FlexibleFEStress.elementVonMises(uni))
        // simple shear: u = (γ y, 0, 0) ⇒ τ = μ γ ⇒ VM = √3 μ γ
        let shear = Self.field { SIMD3(Float(eps) * $0.y, 0, 0) }
        let b = try XCTUnwrap(FlexibleFEStress.elementVonMises(shear))
        let mu = E / (2 * (1 + nu))
        print(String(format: "FLEX-M STRESS uniaxial %.6f (expect %.6f) · shear %.6f (expect %.6f)",
                     Double(a[0]), E * eps / (1 + nu), Double(b[0]), 3.0.squareRoot() * mu * eps))
        for x in a { XCTAssertEqual(Double(x), E * eps / (1 + nu), accuracy: 1e-6) }
        for x in b { XCTAssertEqual(Double(x), 3.0.squareRoot() * mu * eps, accuracy: 1e-6) }
        // ★ the RAW field: a calibrated field (u × k) has the same stress — the force is core's design force
        let k = uni.scaled(by: 3)
        let ak = try XCTUnwrap(FlexibleFEStress.elementVonMises(k))
        XCTAssertEqual(Double(ak[0]), Double(a[0]), accuracy: 1e-6, "k scales the picture, never the stress")
        // ★ RED CONTROL: reading the calibrated u as it is triples it
        let wrong = Self.field({ SIMD3(0, 0, -Float(3 * eps) * $0.z) })
        XCTAssertEqual(Double(try XCTUnwrap(FlexibleFEStress.elementVonMises(wrong))[0]), 3 * Double(a[0]), accuracy: 1e-6,
                       "control: the calibrated u read as raw is 3× the stress")
        // each element's OWN modulus: a soft element reads less, and the node field averages its neighbours
        var mixed = Self.field({ SIMD3(0, 0, -Float(eps) * $0.z) })
        mixed = FlexibleFEField(simID: "t", generation: 0, nx: 3, ny: 3, nz: 3, origin: .zero, spacing: 1.5, u: mixed.u,
                                elementE: [2, 2, 2, 2, 2, 2, 2, 0.2])
        let m = try XCTUnwrap(FlexibleFEStress.elementVonMises(mixed))
        XCTAssertEqual(Double(m[7]), 0.1 * Double(m[0]), accuracy: 1e-6, "the soft element's own modulus")
        let nodes = try XCTUnwrap(FlexibleFEStress.field(mixed))
        XCTAssertEqual(Double(nodes.vonMises[mixed.node(2, 2, 2)]), Double(m[7]), accuracy: 1e-6, "a corner node: its one element")
        XCTAssertEqual(Double(nodes.vonMises[mixed.node(1, 1, 1)]), Double(m.reduce(0, +)) / 8, accuracy: 1e-6, "the centre: the mean of 8")
        // no moduli (a field from parts): no stress, never a guess
        XCTAssertNil(FlexibleFEStress.elementVonMises(FlexibleFEField(simID: "t", generation: 0, nx: 3, ny: 3, nz: 3, origin: .zero,
                                                                      spacing: 1, u: uni.u)))
        // the failure line is ONE line, with why
        for why in ["CG did not converge. The iteration blew its time budget", "squish sim: deadline passed after 20000 ms",
                    "The part is still opening.", "anything else"] {
            let l = FlexibleFEStress.failedLine(why)
            XCTAssertTrue(l.hasPrefix("Couldn't simulate: "), l)
            XCTAssertFalse(l.contains(". "), l)
            XCTAssertLessThanOrEqual(l.count, 44, l)
        }
    }

    // MARK: WHY it failed on his pad

    func testWhyHisSolidStressFailedAndTheGroupsSimDoesNot() throws {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        defer { r.cleanup() }
        let ctx = FlexibleStressContext.reached(try XCTUnwrap(r.app.makeLatticeSimContext()))
        var why = ""
        XCTAssertThrowsError(try TopOptKit.analyzeSolidLoadCase(modelPath: ctx.modelPath, material: ctx.material,
                                                               materialsPath: ctx.materialsPath, rulesPath: ctx.rulesPath,
                                                               resolution: ctx.resolution, anchorFaceIDs: ctx.anchorFaceIDs,
                                                               loadGroups: ctx.loadGroups, buildDirection: ctx.buildDirection,
                                                               faceRegions: ctx.faceRegions, anchorRegionIDs: ctx.anchorRegionIDs)) { why = "\($0)" }
        let union = try XCTUnwrap(r.project.faceRegions.regions.first { $0.id == 105 })
        print("FLEX-M STRESS WHY: his Top group presses \(ctx.loadGroups.map(\.regionIDs)) · region 105 '\(union.name)' has \(union.parts.count) parts, \(union.add.count) faces of its own · core: \(why)")
        XCTAssertTrue(why.contains("105") && why.contains("NO faces"), "the union region reaches core empty")
        XCTAssertFalse(union.parts.isEmpty, "…because a union carries its members as parts, which the region spec does not have")
        XCTAssertTrue(union.add.isEmpty)
    }

    // MARK: Stress on his project: each group's own sim, following the picker

    func round5(failing: Set<String> = []) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlFailSimIDs = failing
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

    func testStressIsTheShownGroupsOwnSimOnTheBodyAndTheWalls() async throws {
        let (r, stage, m) = try await round5()
        let o = try XCTUnwrap(stage.overlay)
        stage.toggleStress()
        XCTAssertTrue(stage.stress && !stage.heat, "Stress took the map")
        XCTAssertTrue(stage.feStressRoute)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var peaks: [String: Double] = [:]
        for g in ["group-1", "group-2"] {
            stage.pick(g)
            stage.refresh()
            XCTAssertEqual(stage.stressView, .ready, g)
            XCTAssertNil(stage.stressLine, g)
            let f = try XCTUnwrap(m.squish[g]?.field)
            let own = try XCTUnwrap(FlexibleFEStress.field(f)), other = try XCTUnwrap(FlexibleFEStress.field(try XCTUnwrap(m.squish[g == "group-1" ? "group-2" : "group-1"]?.field)))
            let shown = try XCTUnwrap(stage.feShownStress)
            XCTAssertEqual(shown.field.vonMises, own.vonMises, "\(g): the shown group's own field")
            peaks[g] = shown.peak
            XCTAssertEqual(stage.legendTitle(.stress), "Stress · Group \(g.last!) · MPa")
            // the part's colours: the rainbow of ITS field at every part vertex (RED: the other group's)
            let t = try XCTUnwrap(stage.tints(r.project, on: .lattice, roles: [:], stress: nil))
            let pos = o.mesh.flat.positions
            var match = 0, otherMatch = 0, n = 0
            for v in stride(from: 0, to: o.partFlatVertices, by: 7) {
                let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
                let c = FlexibleColours.stressTint(fraction: (FlexibleProbe.stress(own, at: p) ?? 0) / shown.peak)
                let d = FlexibleColours.stressTint(fraction: (FlexibleProbe.stress(other, at: p) ?? 0) / shown.peak)
                let got = SIMD3(t[v * 8], t[v * 8 + 1], t[v * 8 + 2])
                n += 1
                if simd_distance(got, SIMD3(c.x, c.y, c.z)) < 1e-4 { match += 1 }
                if simd_distance(got, SIMD3(d.x, d.y, d.z)) < 1e-4 { otherMatch += 1 }
            }
            // a tap: the shown group's MPa at the point (RED: the other group's number there)
            let p = SIMD3<Float>(pos[0], pos[1], pos[2])
            let read = try XCTUnwrap(stage.surfaceReading(.stress, at: p))
            let ownV = try XCTUnwrap(FlexibleProbe.stress(own.self, at: p)), otherV = FlexibleProbe.stress(other, at: p) ?? 0
            // the walls: the layer asks for the stress colours on the page's one scale
            let layer = try XCTUnwrap(stage.layer(r.project, stage: .lattice, pageUp: false))
            let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
            mr.setMesh(try XCTUnwrap(stage.mesh(r.project, on: .lattice)))
            mr.applyFlexibleLattice(layer, device: device)
            print(String(format: "FLEX-M STRESS %@: peak %.4f MPa · part colours: its own field %d / %d, the other group's %d · tap %@ MPa (its own %.4f, the other's %.4f) · walls 1/%.4f",
                         g, shown.peak, match, n, otherMatch, read.value, ownV, otherV, 1 / Double(layer.stressInvMPa)))
            XCTAssertEqual(match, n, "\(g): the part is coloured by its own group's stress")
            XCTAssertLessThan(otherMatch, n / 2, "\(g): control: the other group's field is another picture")
            XCTAssertEqual(read.value, FlexibleProbe.mpa(ownV), "\(g): the tap reads its own group's MPa")
            XCTAssertNotEqual(FlexibleProbe.mpa(ownV), FlexibleProbe.mpa(otherV), "\(g): control: the other group's number differs")
            XCTAssertEqual(Double(layer.stressInvMPa), 1 / shown.peak, accuracy: 1e-6 / shown.peak, "\(g): the walls take the stress")
            XCTAssertEqual(mr.flexibleLattice?.stressInvMPa, layer.stressInvMPa)
        }
        XCTAssertNotEqual(peaks["group-1"], peaks["group-2"], "two groups, two fields")
        // Stress off: the walls go back to their density
        stage.toggleStress()
        XCTAssertEqual(stage.layer(r.project, stage: .lattice, pageUp: false)?.stressInvMPa, 0)
    }

    func testAFailedSimSaysWhyInOneLineAndRetryRerunsItWithoutARebuild() async throws {
        let (_, stage, m) = try await round5(failing: ["group-2"])
        stage.toggleStress()
        stage.pick("group-2")
        stage.refresh()
        guard case .failed(let why) = stage.stressView else { return XCTFail("group 2's sim failed: \(stage.stressView)") }
        let line = try XCTUnwrap(stage.stressLine)
        print("FLEX-M STRESS FAILED: line '\(line)' · (i) '\(stage.stressInfo)' · core: \(why)")
        XCTAssertTrue(line.hasPrefix("Couldn't simulate: "))
        XCTAssertFalse(line.contains(". "), "one line")
        XCTAssertTrue(stage.stressInfo.contains("failed"), "core's words behind the (i)")
        XCTAssertTrue(stage.stressView.retries, "Retry is offered")
        // Retry: the sim runs again — on the request still held (no lattice rebuild)
        let generation = try XCTUnwrap(m.lattice?.generation)
        m.squishSolver.controlFailSimIDs = []
        stage.retryStress()
        XCTAssertEqual(m.squish["group-2"], .pending, "Retry re-runs the group's sim")
        try await FlexibleHisProject.waitFor(120, "the retried sim") { m.squish["group-2"]?.field != nil }
        stage.refresh()
        XCTAssertEqual(m.lattice?.generation, generation, "…without rebuilding the lattice")
        XCTAssertEqual(stage.stressView, .ready, "and Stress draws")
        // ★ RED CONTROL: batch G released the request after the last solve — a retry had to rebuild
        let (_, s2, m2) = try await round5(failing: ["group-2"])
        s2.toggleStress(); s2.pick("group-2"); s2.refresh()
        let g2 = try XCTUnwrap(m2.lattice?.generation)
        m2.squishSolver.cancel()   // (the request gone, as batch G left it)
        m2.squishSolver.controlFailSimIDs = []
        s2.retryStress()
        try await FlexibleHisProject.waitFor(180, "the control's rebuild") { (m2.lattice?.generation ?? g2) != g2 || m2.latticeBuilding }
        XCTAssertTrue(m2.latticeBuilding || m2.lattice?.generation != g2, "control: without the request, Retry rebuilds the lattice")
        await m2.waitForIdle()
    }
}
#endif
