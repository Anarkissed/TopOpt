// FlexibleBatchM2Probe — batch M2's opt-in data dump (task 2026-09-29-flexible-screens, round 5,
// batch M2: V10 "the Settings page's stamp dent is a steep trench … and disagrees with the main page").
// Per stamp face: every column's place, its footprint, the Settings page's dent and the main page's
// 3D-sim heat (calibrated mm) — CSVs the spread is fitted against. Opt-in:
//     FLEX_M2_PROBE_DIR=<dir> swift test --filter FlexibleBatchM2Probe
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchM2Probe: XCTestCase {

    static var dir: URL? {
        ProcessInfo.processInfo.environment["FLEX_M2_PROBE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// One CSV per stamp face of the stage's model: the Settings page's values and the main page's heat.
    static func dump(_ stage: FlexibleMainStage, _ m: FlexibleStageModel, tag: String, to dir: URL) throws {
        let o = try XCTUnwrap(stage.overlay)
        let shown = FlexibleShownValues(model: m)
        let req = m.lastFERequest
        for g in m.squishSims.map(\.sim.id) {
            stage.pick(g); stage.refresh()
            guard let f = stage.feShownField, let vals = stage.feMapValues(f, m) else { print("FLEX-M2 \(tag) \(g): no FE field"); continue }
            for (k, start) in o.flatStart {
                guard let st = m.stacks[k], let face = m.settings.face(k.region), face.isStampShape,
                      let foot = m.stampFootprint(k.region), let cov = m.stampCoverage(k.region) else { continue }
                // the group's own faces only
                let mine = (0..<st.columns.count).contains { c in (0..<6).contains { vals[start + 6 * c + $0].isFinite } }
                guard mine else { continue }
                let dent = m.stampDent(k.region) ?? []
                let design = m.designs[k]
                let press = req?.sims.first { $0.id == g }?.pressed.first { $0.face == k.region }
                var csv = "c,iu,iv,u,v,lat,cov,foot,w,settings_mm,fe_mm,pressure,design_mm,density,buildable_mm,asbuilt_mm\n"
                let asBuilt = m.lattice?.columnDepths[k] ?? []
                for (c, col) in st.columns.enumerated() {
                    let fe = (0..<6).map { Double(vals[start + 6 * c + $0]) }
                    let feMean = fe.allSatisfy(\.isFinite) ? fe.reduce(0, +) / 6 : .nan
                    var sv = Double.nan
                    if let v = shown.values[k], c < v.count, case .depth(let d) = v[c] { sv = d }
                    let p = press.map { c < $0.columnPressureMPa.count ? $0.columnPressureMPa[c] : .nan } ?? .nan
                    let dc = design.flatMap { c < $0.columns.count ? $0.columns[c] : nil }
                    csv += String(format: "%d,%d,%d,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.5f,%.5f,%.6f,%.5f,%.5f,%.5f,%.5f\n",
                                  c, col.iu, col.iv, col.uMM, col.vMM, col.latticeMM, cov[c], foot[c], c < dent.count ? dent[c] : .nan,
                                  sv, feMean, p, dc?.targetDepthMM ?? .nan, dc?.targetDensity ?? .nan,
                                  dc.map { $0.buildableOK ? $0.buildableDepthMM : .nan } ?? .nan,
                                  c < asBuilt.count ? (asBuilt[c] ?? .nan) : .nan)
                }
                let url = dir.appendingPathComponent("M2_\(tag)_\(g)_face\(k.region).csv")
                try csv.write(to: url, atomically: true, encoding: .utf8)
                print(String(format: "FLEX-M2 %@ %@ face %d: pitch %.3f nu %d nv %d lattice mean %.2f · deepest %.2f · fe scale %.3f fold %@ · dentMax %.3f · wrote %@",
                             tag, g, k.region, st.pitchMM, st.nu, st.nv, st.latticeMMMean, face.deepestMM, f.scale,
                             f.foldShare.map { String(format: "%.3f", $0) } ?? "-", stage.dentMaxMM, url.lastPathComponent))
                if let s = face.activeStamp {
                    let sig = FlexibleStampSpread.sigmasMM(st, foot: foot)
                    print(String(format: "FLEX-M2 %@ face %d stamp: centre (%.2f, %.2f) %.1f × %.1f mm, turn %.0f°, %@ · feature %.2f mm · σ %.2f / %.2f mm, near weight %.3f", tag, k.region,
                                 s.centreU, s.centreV, s.widthMM, s.lengthMM, s.rotationDeg, s.rigid ? "rigid" : "soft",
                                 FlexibleStampSpread.featureMM(foot, stack: st), sig.near, sig.far, FlexibleStampSpread.Rule.shipped.nearWeight(sig)))
                }
            }
        }
    }

    /// The pad (100 × 100 × 20) with `stamp` on its top, `kg`, `deepest`; through Save & Exit, sims landed.
    func pad(stamp: String, kg: Double, deepest: Double) async throws -> (FlexibleMainStage, FlexibleStageModel) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let pad = FlexibleMainStage()
        pad.reduceMotion = { true }
        let pmod = pad.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await pmod.waitForIdle() }
        pmod.keepFERequest = true
        pmod.openScene()
        try await FlexibleHisProject.waitFor(90, "the pad") { pmod.sceneState == .ready }
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        _ = pmod.press(top, kg: kg)
        pmod.rest(FlexibleSquishFixture.bottomFace(mesh))
        try await FlexibleHisProject.waitFor(60, "the top's stack") { pmod.stack(top) != nil }
        pmod.setShape(top, "stamp")
        let shape = try XCTUnwrap(pmod.library?.stamps.first { $0.id == stamp })
        pmod.setStamp(top, source: .library(shape.id), shape: shape)
        pmod.edit { s in if var f = s.face(top) { f.deepestMM = deepest; s.setFace(f) } }
        try await FlexibleHisProject.waitFor(60, "the stamp's grid") { pmod.stampDent(top) != nil }
        try await FlexibleSquishFixture.settle(pmod, "the stamp pad")
        pad.didExitSettings()
        pad.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(400, "the stamp pad's sims") {
            pad.refresh()
            return pmod.lattice != nil && !pmod.squish.isEmpty && !pmod.squish.values.contains(.pending)
        }
        await pmod.squishSolver.waitForIdle()
        pad.refresh()
        return (pad, pmod)
    }

    func testDumpThePadStamps() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_M2_PROBE_DIR") }
        // ★ M2 VERIFICATION: "whole" — the library's whole-face and large stamps (the rigid flat plate,
        // the rigid foam-test foot, the soft palm), outside the six faces the rule was fitted on
        let cases: [(String, Double, Double)]
        switch ProcessInfo.processInfo.environment["FLEX_M2_PAD_CASES"] {
        case "all"?: cases = [("four_fingers", 3, 6), ("four_fingers", 10, 3), ("thumb", 10, 4)]
        case "whole"?: cases = [("flat_plate", 10, 4), ("ifd_foot", 10, 4), ("palm", 10, 4)]
        default: cases = [("four_fingers", 3, 6)]
        }
        for (s, kg, d) in cases {
            let (stage, m) = try await pad(stamp: s, kg: kg, deepest: d)
            try Self.dump(stage, m, tag: "pad_\(s)_\(Int(kg))kg_\(Int(d))mm", to: dir)
        }
    }

    func testDumpHisRound5Stamps() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_M2_PROBE_DIR") }
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
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
        try Self.dump(stage, m, tag: "his_r5", to: dir)
    }

    // MARK: the before / after frames (the shipping renderer, offscreen)

    /// The Settings page's own picture, as `FlexibleStagePage.refreshChannels` composes it: the overlay
    /// (cut to the sim's grid while its field moves the part), the channels (X-ray), the group frames, and
    /// the dent — `edited`: the column preview he sees after any edit (FlexibleSettingsSquish.columnDents
    /// of the playing group); else what the page plays right after Save & Exit (FlexibleSettingsSquish.shown).
    static func renderSettingsPage(_ m: FlexibleStageModel, _ pm: ProjectModel, edited: Bool, to url: URL,
                                   view: (String, Float, Float), size: Int = 900) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let edge = edited ? nil : FlexibleSettingsSquish.overlayEdge(model: m)
        let overlay = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0) } ?? FlexiblePageChannels.overlay(model: m))
        var c = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: true, drawnLattice: nil)
        FlexibleGroupFrames.paint(&c.tints, overlay: overlay, model: m)
        var dents = c.dents, k = c.exaggeration
        if edited {
            if let g = m.playingGroup { dents = FlexibleSettingsSquish.columnDents(model: m, overlay: overlay, regions: Set(g.regions)) }
        } else {
            var cache: (key: String, dents: [Float])?
            let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
            dents = sq.dents; k = sq.exaggeration
        }
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(overlay.mesh)
        let settle = pm.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: view.1, elevation: view.2)
        if let t = c.tints { mr.setVertexTints(t) }
        mr.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        if let d = dents { mr.setFlexDisplacements(d) }
        mr.setFlexScale(Float(k))
        let bg = DS.Color.background
        let px = try XCTUnwrap(mr.renderOffscreen(size: size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        try FlexibleLatticeEvidenceProbe.writeBGRA(px, size: size, to: url)
    }

    static let views: [(String, Float, Float)] = [("iso", .pi / 4, .pi / 6), ("top", .pi / 5, 1.2), ("backleft", -3 * .pi / 4, 0.55)]

    /// Batch M2's before / after: the Settings page with a four-fingertip stamp (C1's pad, 3 kg, 6 mm),
    /// as he edits and right after Save & Exit, batch M's spread (before) and batch M2's (after), and the
    /// main page beside it; his round-5 project's Settings page with Face 3 (Group 2's fingertips) selected.
    func testBeforeAfterFrames() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_M2_PROBE_DIR") }
        // ★ M2 VERIFICATION: FLEX_M2_BEFORE=m2 — "before" is batch M2's rule (σ_near 0.25 × depth), not batch M's
        let beforeIsM2 = ProcessInfo.processInfo.environment["FLEX_M2_BEFORE"] == "m2"
        func before(_ on: Bool) {
            if beforeIsM2 { FlexibleStampSpread.controlRule = on ? .batchM2 : nil } else { FlexibleStampSpread.controlBatchMSpread = on }
        }
        defer { FlexibleStampSpread.controlBatchMSpread = false; FlexibleStampSpread.controlRule = nil }
        let (stage, m) = try await pad(stamp: "four_fingers", kg: 3, deepest: 6)
        let pm = m.project
        for (tag, control) in [("before", true), ("after", false)] {
            before(control)
            for v in Self.views {
                try Self.renderSettingsPage(m, pm, edited: true, to: dir.appendingPathComponent("M2_\(tag)_pad4_settings_edited_\(v.0).png"), view: v)
                try Self.renderSettingsPage(m, pm, edited: false, to: dir.appendingPathComponent("M2_\(tag)_pad4_settings_saved_\(v.0).png"), view: v)
            }
        }
        before(false)
        for v in Self.views {
            try FlexibleBatchMProbe.render(stage, pm, to: dir.appendingPathComponent("M2_pad4_main_\(v.0).png"), amount: 1, view: v)
        }
        // his round-5 project: Face 3 selected (Group 2's four fingertips play), and the main page's Group 2
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let his = FlexibleMainStage()
        his.reduceMotion = { true }
        let hm = his.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await hm.waitForIdle() }
        hm.openScene()
        try await FlexibleSquishFixture.settle(hm, "his round 5")
        his.didExitSettings()
        his.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(400, "his round 5: the sims") {
            his.refresh()
            return hm.lattice != nil && !hm.squish.isEmpty && !hm.squish.values.contains(.pending)
        }
        await hm.squishSolver.waitForIdle()
        hm.select(3)
        // ★ M2 VERIFICATION: and four level views round the part — one of them looks at Face 3 face-on
        let hisViews = Self.views + [("side0", 0, 0), ("side90", .pi / 2, 0), ("side180", .pi, 0), ("side270", -.pi / 2, 0)]
        for (tag, control) in [("before", true), ("after", false)] {
            before(control)
            for v in hisViews {
                try Self.renderSettingsPage(hm, r.project, edited: true, to: dir.appendingPathComponent("M2_\(tag)_his_settings_face3_edited_\(v.0).png"), view: v)
            }
        }
        before(false)
        his.pick("group-2"); his.refresh()
        for v in hisViews {
            try FlexibleBatchMProbe.render(his, r.project, to: dir.appendingPathComponent("M2_his_main_group-2_\(v.0).png"), amount: 1, view: v)
        }
        try FlexibleBatchMProbe.renderLegend(his, to: dir.appendingPathComponent("M2_main_legend_card.png"))
    }
}
#endif
