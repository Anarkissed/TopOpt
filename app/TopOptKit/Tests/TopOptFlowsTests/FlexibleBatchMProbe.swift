// FlexibleBatchMProbe — batch M's opt-in diagnostics on HIS round-5 project (task
// 2026-09-29-flexible-screens, round 5 batch M). Opt-in:
//     FLEX_M_PROBE_DIR=<dir> swift test --filter FlexibleBatchMProbe
// (1) WHY the Stress view said "Couldn't simulate" on his pad (img 4): the solid-part solve the
//     Stress button runs, with the context the app builds and the one the Flexible solve sends.
// (2) The main page's own picture (the shipping renderer, offscreen) in the dent view, for the
//     stripes of his img 6: each group at full load, FE and the column fallback.
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
import SwiftUI
import ImageIO
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchMProbe: XCTestCase {

    static var dir: URL? {
        ProcessInfo.processInfo.environment["FLEX_M_PROBE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func testWhyHisStressCouldNotSimulate() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_M_PROBE_DIR") }
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        defer { r.cleanup() }
        let app = try XCTUnwrap(r.app.makeLatticeSimContext())
        let reached = FlexibleStressContext.reached(app)
        print("FLEX-M STRESS app regions \(app.faceRegions.map { "\($0.id)(parent \($0.parentID), add \($0.addFaces), cuts \($0.cuts.count))" }) · anchors \(app.anchorFaceIDs)/\(app.anchorRegionIDs) · loads \(app.loadGroups.map { "\($0.faceIDs)/\($0.regionIDs)" })")
        print("FLEX-M STRESS reached regions \(reached.faceRegions.map(\.id))")
        func solve(_ c: LatticeSimModel.Context) -> String {
            do {
                let res = try TopOptKit.analyzeSolidLoadCase(modelPath: c.modelPath, material: c.material, materialsPath: c.materialsPath,
                                                             rulesPath: c.rulesPath, resolution: c.resolution, anchorFaceIDs: c.anchorFaceIDs,
                                                             loadGroups: c.loadGroups, buildDirection: c.buildDirection,
                                                             faceRegions: c.faceRegions, anchorRegionIDs: c.anchorRegionIDs)
                return String(format: "OK peak %.4f MPa nonConvergent %@", Double(res.vonMisesField.max() ?? 0), res.nonConvergent ? "yes" : "no")
            } catch { return "THROWS \(error)" }
        }
        print("FLEX-M STRESS the app's context: \(solve(app))")
        print("FLEX-M STRESS the Flexible (reached) context: \(solve(reached))")
    }
    // MARK: the main page's picture (offscreen, the shipping renderer)

    /// His round-5 project through Save & Exit, every sim landed (`quality`: the main page's grid).
    func round5(_ quality: RunQuality? = nil) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        if let quality { r.project.quality = quality }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(400, "his round 5: the sims") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        stage.refresh()
        return (r, stage, m)
    }

    static var views: [(String, Float, Float)] {
        if ProcessInfo.processInfo.environment["FLEX_M_VIEWS"] == "img6" {
            // his img 6's gizmo: BACK / LEFT / TOP — from behind-left, above
            return [("backleft", -3 * .pi / 4, 0.55), ("left", -.pi / 2, 0.45), ("back", .pi, 0.5), ("backleft2", -2.4, 0.75)]
        }
        return [("iso", .pi / 4, .pi / 6), ("front", 0, 0.35), ("top", .pi / 5, 1.2)]
    }

    /// One offscreen frame of what the stage hands MetalMeshView, at `amount` of the page's ×k.
    static func render(_ stage: FlexibleMainStage, _ project: ProjectModel, to url: URL, amount: Float,
                       view: (String, Float, Float), size: Int = 900) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard let mesh = stage.mesh(project, on: .lattice), let ch = stage.channels else { XCTFail("no overlay"); return }
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(mesh)
        let settle = project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: view.1, elevation: view.2)
        if let t = stage.tints(project, on: .lattice, roles: [:], stress: nil) { mr.setVertexTints(t) }
        mr.setBodyAlpha(stage.bodyAlpha(project, on: .lattice) ?? 1)
        let layer = stage.layer(project, stage: .lattice, pageUp: false)
        mr.applyFlexibleLattice(layer, device: device)
        if let l = layer, !l.feSequence.isEmpty, let pass = mr.flexibleLattice {
            let i = l.feSequence[0]
            pass.bindFE(i)
            mr.setFlexDisplacements(l.feMesh[i])
            if let t = l.feTints?.tints(pass.feFields[i].simID), t.count / 8 == l.feMesh[i].count / 3 { mr.setVertexTints(t) }
        } else if let d = stage.dents(project, on: .lattice) {
            mr.setFlexDisplacements(d)
        }
        mr.setFlexScale(Float(ch.exaggeration) * amount)
        let bg = DS.Color.background
        let px = try XCTUnwrap(mr.renderOffscreen(size: size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        try FlexibleLatticeEvidenceProbe.writeBGRA(px, size: size, to: url)
    }

    /// His img 6: the dent view with the lattice, Fine — each group at full load, FE and the column
    /// fallback (the build he saw), to find what draws the stripes.
    func testHisDentViewFrames() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_M_PROBE_DIR") }
        let tag = ProcessInfo.processInfo.environment["FLEX_M_TAG"] ?? "before"
        let qs: [(RunQuality, String)] = ProcessInfo.processInfo.environment["FLEX_M_VIEWS"] == "img6"
            ? [(.fine, "fine")] : [(.fine, "fine"), (.fast, "fast")]
        for (q, qn) in qs {
            let (r, stage, m) = try await round5(q)
            for g in m.squishSims.map(\.sim.id) {
                stage.pick(g)
                for (mode, column) in [("fe", false), ("column", true)] {
                    stage.controlColumnSquish = column
                    stage.refresh()
                    for (lat, on) in [("lattice", true), ("nolattice", false)] {
                        stage.latticeOn = on
                        stage.refresh()
                        for v in Self.views {
                            try Self.render(stage, r.project, to: dir.appendingPathComponent("M_\(tag)_\(qn)_\(g)_\(mode)_\(lat)_\(v.0).png"),
                                            amount: 1, view: v)
                        }
                    }
                    stage.latticeOn = true
                }
                stage.controlColumnSquish = false
            }
        }
    }
    /// The 3D sim's surface sink round each STAMP of his round-5 project, by distance from the stamp's
    /// edge (over the sink under it) — what the Settings page's spread is measured against.
    func testFEStampSpreadProfile() async throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_M_PROBE_DIR") }
        let (_, _, m) = try await round5()
        let r = try XCTUnwrap(m.lastFERequest)
        let bins: [ClosedRange<Double>] = [0...2, 2...4, 4...8, 8...16, 16...40]
        for sim in r.sims {
            guard let f = m.squish[sim.id]?.field else { continue }
            for (i, press) in sim.pressed.enumerated() {
                guard let cov = m.stampCoverage(press.face) else { continue }
                let t = sim.targets[i], st = t.stack, cols = st.columns
                let load = SIMD3<Float>(st.load)
                func sink(_ c: Int) -> Double {
                    Double(simd_dot(f.sample(SIMD3<Float>(FlexibleStackMembership.point(st, column: c, t: cols[c].entryT))), load))
                }
                let inside = cols.indices.filter { cov[$0] >= 0.5 }
                guard !inside.isEmpty else { continue }
                let inMean = inside.map(sink).reduce(0, +) / Double(inside.count)
                var line = String(format: "FLEX-M SPREAD %@ face %d: lattice %.1f mm (mean), pitch %.2f, footprint %d of %d · inside %.3f mm",
                                  sim.id, press.face, st.latticeMMMean, st.pitchMM, inside.count, cols.count, inMean)
                for b in bins {
                    let ring = cols.indices.filter { c in
                        guard cov[c] < 0.5 else { return false }
                        let d = inside.map { hypot(cols[$0].uMM - cols[c].uMM, cols[$0].vMM - cols[c].vMM) }.min()! - st.pitchMM / 2
                        return b.contains(d)
                    }
                    guard !ring.isEmpty else { continue }
                    let mean = ring.map(sink).reduce(0, +) / Double(ring.count)
                    let ratio = mean / inMean
                    let mid = (b.lowerBound + b.upperBound) / 2
                    line += String(format: " · %.0f–%.0f mm %.0f%% (L %.1f)", b.lowerBound, b.upperBound, 100 * ratio,
                                   ratio > 0 && ratio < 1 ? -mid / log(ratio) : .nan)
                }
                print(line)
                // the Settings page's spread at several shares of the depth, on the same rings
                guard let foot = m.stampFootprint(press.face) else { continue }
                var fit = "FLEX-M SPREAD-FIT face \(press.face):"
                for share in [0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5] {
                    let L = max(st.pitchMM, share * st.latticeMMMean)
                    let w = FlexibleStampSpread.spread(foot, stack: st, lengthMM: L)
                    let wIn = inside.map { w[$0] }.reduce(0, +) / Double(inside.count)
                    var err = 0.0, parts: [String] = []
                    for b in bins.prefix(3) {
                        let ring = cols.indices.filter { c in
                            guard cov[c] < 0.5 else { return false }
                            let d = inside.map { hypot(cols[$0].uMM - cols[c].uMM, cols[$0].vMM - cols[c].vMM) }.min()! - st.pitchMM / 2
                            return b.contains(d)
                        }
                        guard !ring.isEmpty else { continue }
                        let fe = ring.map(sink).reduce(0, +) / Double(ring.count) / inMean
                        let sp = ring.map { w[$0] }.reduce(0, +) / Double(ring.count) / wIn
                        err += (fe - sp) * (fe - sp)
                        parts.append(String(format: "%.0f%%", 100 * sp))
                    }
                    fit += String(format: " · share %.2f (L %.1f): %@ rms %.2f", share, L, parts.joined(separator: "/"), (err / 3).squareRoot())
                }
                print(fit)
            }
        }
    }
    /// The FE heat per face of each group: its max, where, and the field's calibration.
    func testFEHeatPerFace() async throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_M_PROBE_DIR") }
        let (_, stage, m) = try await round5()
        let o = try XCTUnwrap(stage.overlay)
        for g in m.squishSims.map(\.sim.id) {
            stage.pick(g); stage.refresh()
            guard let f = stage.feShownField, let vals = stage.feMapValues(f, m) else { continue }
            print(String(format: "FLEX-M HEAT %@: scale k %.3f · asked %.2f · fold %@ · gmax part %.3f", g, f.scale, f.coreRatio,
                         f.foldShare.map { String(format: "%.2f", $0) } ?? "-", f.gmaxPart))
            for (k, start) in o.flatStart {
                guard let st = m.stacks[k] else { continue }
                var best: (Float, Int) = (-1, -1)
                var sum: Float = 0, n = 0
                for v in start..<(start + st.columns.count * 6) where vals[v].isFinite {
                    if vals[v] > best.0 { best = (vals[v], v) }
                    sum += vals[v]; n += 1
                }
                guard n > 0 else { continue }
                let c = (best.1 - start) / 6
                let col = st.columns[c]
                var foot = "-"
                if let cov = m.stampCoverage(k.region) {
                    let ins = st.columns.indices.filter { cov[$0] >= 0.5 }
                    let vs = ins.map { c in (0..<6).map { vals[start + 6 * c + $0] }.reduce(0, +) / 6 }.filter(\.isFinite)
                    if !vs.isEmpty { foot = String(format: "%.2f (%d columns)", vs.reduce(0, +) / Float(vs.count), vs.count) }
                }
                print(String(format: "FLEX-M HEAT %@ face %d: max %.2f mm at column %d (u %.1f v %.1f, lattice %.1f) · mean %.2f · under its stamp %@ · core's deepest %@",
                             g, k.region, best.0, c, col.uMM, col.vMM, col.latticeMM, sum / Float(n), foot,
                             m.settings.face(k.region).map { String(format: "%.1f", $0.deepestMM) } ?? "-"))
            }
        }
    }
    // MARK: the AFTER evidence (batch M)

    /// The Settings page's own picture: its channels (X-ray, no lattice drawn), the dent at full ×k.
    static func renderSettings(_ m: FlexibleStageModel, _ pm: ProjectModel, to url: URL, view: (String, Float, Float), size: Int = 900) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let c = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: true, drawnLattice: nil)
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(overlay.mesh)
        let settle = pm.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: view.1, elevation: view.2)
        if let t = c.tints { mr.setVertexTints(t) }
        mr.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        if let d = c.dents { mr.setFlexDisplacements(d) }
        mr.setFlexScale(Float(c.exaggeration))
        let bg = DS.Color.background
        let px = try XCTUnwrap(mr.renderOffscreen(size: size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        try FlexibleLatticeEvidenceProbe.writeBGRA(px, size: size, to: url)
    }

    /// The main page's ONE legend card, rendered by SwiftUI at an iPad 13" portrait page.
    static func renderLegend(_ stage: FlexibleMainStage, to url: URL) throws {
        #if canImport(AppKit)
        let size = CGSize(width: 1032, height: 1376)
        let view = FlexibleMainLegends(main: stage, mode: .constant(.groups), projection: nil, settle: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)),
                                       bottomClearance: 94, chipColumnWidth: 222)
            .frame(width: size.width, height: size.height)
            .background(DS.Color.background.color)
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let img = r.cgImage else { XCTFail("no legend image"); return }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("FLEX-EVIDENCE wrote \(url.path)")
        #endif
    }

    func testAfterFrames() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_M_PROBE_DIR") }
        let tag = ProcessInfo.processInfo.environment["FLEX_M_TAG"] ?? "after"
        let views: [(String, Float, Float)] = [("iso", .pi / 4, .pi / 6), ("top", .pi / 5, 1.2), ("backleft", -3 * .pi / 4, 0.55)]
        let only = ProcessInfo.processInfo.environment["FLEX_M_ONLY"]
        if only == nil {
        let (r, stage, m) = try await round5()
        // the main page: each group at full load — the dent view (ghost body + ghost walls, solid planes),
        // the dent view without the lattice, the Stress view with and without it
        for g in m.squishSims.map(\.sim.id) {
            stage.pick(g); stage.refresh()
            for (name, heat, lattice) in [("dent", true, true), ("dent_nolattice", true, false), ("stress", false, true), ("stress_nolattice", false, false)] {
                if heat != stage.heat { if heat { stage.toggleHeat() } else { stage.toggleStress() } }
                stage.latticeOn = lattice
                stage.refresh()
                print("FLEX-M AFTER \(g) \(name): legend \(stage.legendKinds.map { stage.legendTitle($0) }) · stress \(stage.stressView) · scale \(String(format: "%.2f", stage.dentMaxMM)) mm · ghost walls \(stage.ghostWalls)")
                for v in views {
                    try Self.render(stage, r.project, to: dir.appendingPathComponent("M_\(tag)_his_\(g)_\(name)_\(v.0).png"), amount: 1, view: v)
                }
                if g == "group-2", name == "dent" || name == "stress" {
                    try Self.renderLegend(stage, to: dir.appendingPathComponent("M_\(tag)_legend_\(name).png"))
                }
            }
            if !stage.heat { stage.toggleHeat() }
            stage.latticeOn = true
        }
        // the Settings page: his drawing, graded out of each stamp (Face 3's fingertips, Top A's elbow)
        for v in views { try Self.renderSettings(m, r.project, to: dir.appendingPathComponent("M_\(tag)_his_settings_\(v.0).png"), view: v) }
        }
        // a pad with a four-fingertip stamp on its top (C1's pad): the Settings page and the main page
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let pad = FlexibleMainStage()
        pad.reduceMotion = { true }
        let pmod = pad.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await pmod.waitForIdle() }
        pmod.openScene()
        try await FlexibleHisProject.waitFor(90, "the pad") { pmod.sceneState == .ready }
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        _ = pmod.press(top, kg: 3)
        pmod.rest(FlexibleSquishFixture.bottomFace(mesh))
        try await FlexibleHisProject.waitFor(60, "the top's stack") { pmod.stack(top) != nil }
        pmod.setShape(top, "stamp")
        let fingers = try XCTUnwrap(pmod.library?.stamps.first { $0.id == "four_fingers" })
        pmod.setStamp(top, source: .library(fingers.id), shape: fingers)
        pmod.edit { s in if var f = s.face(top) { f.deepestMM = 6; s.setFace(f) } }
        try await FlexibleHisProject.waitFor(60, "the stamp's grid") { pmod.stampDent(top) != nil }
        try await FlexibleSquishFixture.settle(pmod, "the fingertip pad")
        for v in views { try Self.renderSettings(pmod, pm, to: dir.appendingPathComponent("M_\(tag)_pad4_settings_\(v.0).png"), view: v) }
        if only == "pad4settings" { return }
        pad.didExitSettings()
        pad.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(300, "the fingertip pad's sims") {
            pad.refresh()
            return pmod.lattice != nil && !pmod.squish.isEmpty && !pmod.squish.values.contains(.pending)
        }
        await pmod.squishSolver.waitForIdle()
        pad.refresh()
        print("FLEX-M AFTER pad4: FE \(pad.fe.active) · scale \(String(format: "%.2f", pad.dentMaxMM)) mm · (i) \(pad.dentInfo)")
        for v in views { try Self.render(pad, pm, to: dir.appendingPathComponent("M_\(tag)_pad4_main_\(v.0).png"), amount: 1, view: v) }
        pad.toggleStress(); pad.refresh()
        for v in views { try Self.render(pad, pm, to: dir.appendingPathComponent("M_\(tag)_pad4_stress_\(v.0).png"), amount: 1, view: v) }
    }
}
#endif
