import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE ONE-OUTLINE PROOF ON HIS PROJECTS (the reviewer, 2026-10-10 21:27: "point-sample core's region_contains
/// through the bridge against the preview's function, outside a 0.01 mm band; the positive control goes red on
/// today's mitred wire; record the bridge cost and the vertex counts"). Instrumentation, run by hand on a COPY of
/// a project (never his store): OUTLINE_PROJECT_DIR=<copy>, OUTLINE_OUT=<dir>. Opens the project through the app,
/// takes the stage job's include face regions exactly as they are emitted, and samples each region's prism.
@MainActor
final class LatticeOneOutlineProjectProof: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testThePreviewAndCoreAgreeOnHisRegions() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["OUTLINE_PROJECT_DIR"] else { throw XCTSkip("OUTLINE_PROJECT_DIR") }
        let src = URL(fileURLWithPath: dir)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outline-proof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdir = root.appendingPathComponent(snap.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        for f in try FileManager.default.contentsOfDirectory(atPath: src.path) {
            try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: pdir.appendingPathComponent(f))
        }
        let core = Self.repoRoot.appendingPathComponent("core")
        let model = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                             rulesPath: core.appendingPathComponent("src/settings/rules.json").path,
                             store: ProjectStore(rootDir: root))
        model.loadMaterials()
        model.open(try XCTUnwrap(model.recentProjects.first { $0.id == snap.id }))
        let pm = try XCTUnwrap(model.project)
        let all = pm.latticeJobRegions().regions
        let includes = all.enumerated().filter { $0.element.role == .include }
        print("OUTLINE-PROOF project \(pm.name): \(all.count) regions, \(includes.count) include")

        var rows: [String] = [], totalPts = 0, totalBad = 0, totalMitredBad = 0, totalMs = 0.0
        for (k, (_, r)) in includes.enumerated() where r.kind == .face && !r.outlineLoops.isEmpty {
            let rid = k + 1
            let n = LatticeRegionMask.unit(r.normal)
            let (bu, bv) = LatticeRegionMask.basis(n)
            let poly = r.outlinePolygon
            guard !poly.isEmpty else { continue }
            var lo = SIMD2<Double>(repeating: 1e9), hi = SIMD2<Double>(repeating: -1e9)
            for l in poly { for q in l { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
            lo -= 3; hi += 3
            func toBoundary(_ uv: SIMD2<Double>) -> Double {
                var best = Double.greatestFiniteMagnitude
                for loop in poly { for i in loop.indices {
                    let a = loop[i], b = loop[(i + 1) % loop.count], d = b - a, l2 = simd_dot(d, d)
                    let t = l2 > 1e-18 ? Swift.max(0, Swift.min(1, simd_dot(uv - a, d) / l2)) : 0
                    best = Swift.min(best, simd_length(uv - (a + d * t)))
                } }
                return best
            }
            var pts: [SIMD3<Double>] = []
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<1500 {
                let uv = SIMD2(Double.random(in: lo.x...hi.x, using: &rng), Double.random(in: lo.y...hi.y, using: &rng))
                guard toBoundary(uv) > 0.01 else { continue }
                pts.append(r.origin + bu * uv.x + bv * uv.y + n * Double.random(in: 0.05...Swift.max(0.06, r.depthMM - 0.05), using: &rng))
            }
            // core: this region alone, as the job sends it (its own containment; no other region competes)
            let t0 = Date()
            let c = try XCTUnwrap(TopOptKit.steppedRegionOwners(regions: [r.wireDictionary], points: pts),
                                  TopOptKit.lastCoreRefusal ?? "").owners.map { $0 == 1 }
            let ms = Date().timeIntervalSince(t0) * 1000
            // the preview's own containment (the prism, the slab ignored — core has no slab)
            let p = pts.map { LatticeRegionMask.contains($0, region: r) }
            let bad = zip(c, p).filter { $0 != $1 }.count
            // the positive control: today's mitred wire (each loop's offsetRing; seams pushed by min(depth, cap)·tilt)
            var mitred = r.wireDictionary
            var g = mitred["geometry"] as! [String: Any]
            let e = r.inPlaneOffsetMM
            let rings: [[SIMD2<Double>]] = r.outlineLoops.enumerated().map { (l, loop) in
                let sm = l < r.outlineSeams.count ? r.outlineSeams[l] : []
                let tl = l < r.outlineSeamTilt.count ? r.outlineSeamTilt[l] : []
                let cl = l < r.outlineSeamDepthMM.count ? r.outlineSeamDepthMM[l] : []
                let grow: [Double] = loop.indices.map { i in
                    guard i < sm.count, sm[i] else { return -e }
                    guard i < tl.count, tl[i] > 1e-9 else { return 0 }
                    return -((i < cl.count && cl[i] > 0 ? Swift.min(r.depthMM, cl[i]) : r.depthMM) * tl[i])
                }
                return grow.contains(where: { abs($0) > 1e-9 }) ? LatticeOutlineRibbon.offsetRing(loop, by: 0, seams: [], edgeOffset: grow) : loop
            }
            g["outline_uv"] = rings.map { $0.map { [$0.x, $0.y] } }
            var hu = r.halfUMM, hw = r.halfWMM
            for l in rings { for q in l { hu = Swift.max(hu, abs(q.x)); hw = Swift.max(hw, abs(q.y)) } }
            g["half_u_mm"] = hu; g["half_w_mm"] = hw
            mitred["geometry"] = g
            let m = try XCTUnwrap(TopOptKit.steppedRegionOwners(regions: [mitred], points: pts)).owners.map { $0 == 1 }
            let mBad = zip(m, p).filter { $0 != $1 }.count
            totalPts += pts.count; totalBad += bad; totalMitredBad += mBad; totalMs += ms
            let verts = poly.map(\.count).reduce(0, +)
            if bad > 0 || mBad > 0 || r.inPlaneOffsetMM != 0 || !r.outlineSeamTilt.isEmpty {
                rows.append(String(format: "r%d face %@: %d pts, %d disagree, mitred %d; %d loops / %d vertices (raw %d); expand %.2f; core %.1f ms",
                                   rid, r.faceID.map(String.init) ?? "-", pts.count, bad, mBad, poly.count, verts,
                                   r.outlineLoops.map(\.count).reduce(0, +), r.inPlaneOffsetMM, ms))
            }
            XCTAssertEqual(bad, 0, "★ region \(rid): the preview and core disagree on \(bad) of \(pts.count) points")
        }
        let summary = String(format: "OUTLINE-PROOF %@: %d points over %d face regions, %d disagree (mitred wire: %d); core %.0f ms total",
                             pm.name, totalPts, includes.count, totalBad, totalMitredBad, totalMs)
        print(summary); for r in rows { print("  " + r) }
        if let out = env["OUTLINE_OUT"] {
            try ([summary] + rows).joined(separator: "\n").write(toFile: out + "/outline_proof.txt", atomically: true, encoding: .utf8)
        }
    }
}
