// FlexibleBatchM2Probe — batch M2's opt-in data dump (task 2026-09-29-flexible-screens, round 5,
// batch M2: V10 "the Settings page's stamp dent is a steep trench … and disagrees with the main page").
// Per stamp face: every column's place, its footprint, the Settings page's dent and the main page's
// 3D-sim heat (calibrated mm) — CSVs the spread is fitted against. Opt-in:
//     FLEX_M2_PROBE_DIR=<dir> swift test --filter FlexibleBatchM2Probe
#if canImport(MetalKit)
import XCTest
import simd
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
                    print(String(format: "FLEX-M2 %@ face %d stamp: centre (%.2f, %.2f) %.1f × %.1f mm, turn %d°", tag, k.region,
                                 s.centreU, s.centreV, s.widthMM, s.lengthMM, s.rotationDeg))
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
        let cases: [(String, Double, Double)] = ProcessInfo.processInfo.environment["FLEX_M2_PAD_CASES"] == "all"
            ? [("four_fingers", 3, 6), ("four_fingers", 10, 3), ("thumb", 10, 4)]
            : [("four_fingers", 3, 6)]
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
}
#endif
