import XCTest
import SwiftUI
import TopOptKit
@testable import TopOptFlows

/// ★★ RULING 6 (maintainer, 2026-09-30): "take a Release-build number on the stand for the two
/// emission calls per render pass. Add a cache keyed on the emission's inputs, in its own commit,
/// only if the two together exceed 8 ms or the page visibly stutters."
///
/// On his stand, per page pass, as the page runs it now:
/// - `emission` — one `variantLatticeJobRegions()` (the variant pass's one emission since ruling 3);
/// - `two emissions` — the ruling's two calls, as they were before ruling 3 merged them;
/// - `variant pass` — `latticeVariantJobPass` with a worker picked: the emission, the include gate,
///   `latticeRunSpec`, the one document (`RelatticeJobBuilder.build`) and core's own parser;
/// - `canOptimize` — the workspace's gate the page reads (`baseCanOptimize`): the include
///   refusal's emission and `makeRunRequest()`;
/// - `body alpha` — `latticePreviewBodyAlpha`'s emission;
/// - `page render` — the whole `LatticePage` rendered offscreen (ImageRenderer, staticRender): every
///   section it builds runs, the stage's emissions among them (the Optimize surface, the region
///   count, the frozen rows, the sector rows), plus layout and raster — an UPPER bound on the
///   page's own share. (`_ = page.body` alone measured 0.01 ms: its sections are built lazily, so
///   it timed nothing.)
/// - `whole pass` — all of the above in one pass.
/// 5 warm-ups, then 50 timed passes: min / median / p90 / max, the build configuration and the
/// machine named. Env: STAND_TIMING=1, HIS_PROJECT_DIR, VARIANT_ORIGINAL, VARIANT_FINGERPRINT,
/// VARIANT_FRACTION. A negative control runs the same pass with lattice OFF.
final class LatticePagePassTimingProbe: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    private static var buildConfig: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }
    private static var machine: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private func stats(_ label: String, _ ms: [Double]) -> String {
        let s = ms.sorted()
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        return String(format: "%-16@ min %7.2f  median %7.2f  p90 %7.2f  max %7.2f ms", label as NSString,
                      s.first ?? 0, q(0.5), q(0.9), s.last ?? 0)
    }

    @MainActor
    func testThePagePassOnTheStand() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STAND_TIMING"] == "1", let dirPath = env["HIS_PROJECT_DIR"],
              let originalPath = env["VARIANT_ORIGINAL"],
              let fp = env["VARIANT_FINGERPRINT"].flatMap(UInt64.init),
              let vf = env["VARIANT_FRACTION"].flatMap(Double.init)
        else { throw XCTSkip("STAND_TIMING=1, HIS_PROJECT_DIR, VARIANT_ORIGINAL, VARIANT_FINGERPRINT, VARIANT_FRACTION") }
        let original = try Data(contentsOf: URL(fileURLWithPath: originalPath))
        let core = Self.repoRoot.appendingPathComponent("core")
        let materials = core.appendingPathComponent("src/materials/materials.json").path
        let rules = core.appendingPathComponent("src/settings/rules.json").path

        // a fresh copy: opening a project may write to it
        let src = URL(fileURLWithPath: dirPath)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pass-timing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdir = root.appendingPathComponent(snap.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        for f in try FileManager.default.contentsOfDirectory(atPath: src.path) {
            try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: pdir.appendingPathComponent(f))
        }
        let model = AppModel(materialsPath: materials, rulesPath: rules, store: ProjectStore(rootDir: root))
        model.loadMaterials()
        model.open(try XCTUnwrap(model.recentProjects.first { $0.id == snap.id }))
        let pm = try XCTUnwrap(model.project)

        let ctx = LatticeVariantContext(
            runName: "M2 verticalStand", variantIndex: 22, requestedVolumeFraction: vf,
            massGrams: 40, worstCaseMargin: 2, accepted: true,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
            field: LatticeDemandField(vonMises: [1, 2, 3, 4, 5, 6, 7, 8], nx: 2, ny: 2, nz: 2,
                                      origin: .zero, spacingMM: 1,
                                      provenance: .variant(runName: "M2 verticalStand", variantIndex: 22, date: nil)),
            artifacts: RelatticeArtifacts(jobJSON: original, designBin: Data([1])), unavailable: nil)

        func time(_ body: () throws -> Void) rethrows -> [Double] {
            for _ in 0..<5 { try body() }
            var ms: [Double] = []
            for _ in 0..<50 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                try body()
                ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            return ms
        }
        // the variant pass, call for call as `latticeVariantJobPass` + `relatticeJobJSON` make it
        func variantPass() throws -> Data? {
            let e = pm.variantLatticeJobRegions()
            guard LatticeJobIncludeGate.refusal(latticeEnabled: pm.lattice.enabled, regions: e.regions) == nil,
                  let spec = pm.latticeRunSpec(emission: e) else { return nil }
            let json = try RelatticeJobBuilder.build(original: original, designFingerprint: fp, achievedVolumeFraction: vf,
                                                     designFileName: "design.bin", lattice: spec)
            let refused = TopOptKit.jobSchemaError(json).map { pm.variantJobCoreRefusal(coreError: $0, regions: e.regions) }
            return refused == nil ? json : nil
        }
        func canOptimizeSide() -> Bool {
            LatticeJobIncludeGate.optimizeRefusal(latticeEnabled: pm.lattice.enabled,
                                                  regions: pm.latticeJobRegions().regions) == nil
                && model.makeRunRequest() != nil
        }
        func bodyAlpha() -> Bool { LatticeJobIncludeGate.hasIncludeWall(pm.latticeJobRegions().regions) }
        func pageBody(forecastJob: Data?) {
            let page = LatticePage(model: model, project: pm, run: RunModel(), sim: LatticeSimModel(),
                                   page: LatticePageModel(), variantContext: ctx, previewOn: .constant(true),
                                   baseCanOptimize: true, baseSummary: "minimize plastic · self-weight",
                                   onOptimize: {}, onClose: {}, onBackToSetup: {},
                                   forecastJob: forecastJob, onMarkWalls: {}, staticRender: true)
                .frame(width: 1366, height: 1024)
            let r = ImageRenderer(content: page)
            r.scale = 1
            _ = r.cgImage
        }

        let header = "PASS-TIMING \(Self.buildConfig) on \(Self.machine) · stand \(snap.id.uuidString.prefix(8)) "
            + "algorithm \(pm.lattice.algorithm) · \(pm.latticeJobRegions().regions.count) region(s)"
        print(header)
        let doc = try variantPass()
        print("PASS-TIMING variant document \(doc.map { "\($0.count) bytes, core accepts" } ?? "REFUSED / none")")
        var lines: [String] = []
        lines.append(stats("emission", time { _ = pm.variantLatticeJobRegions() }))
        lines.append(stats("two emissions", time { _ = pm.variantLatticeJobRegions(); _ = pm.variantLatticeJobRegions() }))
        lines.append(stats("variant pass", try time { _ = try variantPass() }))
        lines.append(stats("canOptimize", time { _ = canOptimizeSide() }))
        lines.append(stats("body alpha", time { _ = bodyAlpha() }))
        lines.append(stats("page render", time { pageBody(forecastJob: doc) }))
        lines.append(stats("whole pass", try time {
            let d = try variantPass(); _ = canOptimizeSide(); _ = bodyAlpha(); pageBody(forecastJob: d)
        }))
        // negative control: the same pass with lattice OFF
        pm.lattice.enabled = false
        lines.append(stats("OFF whole pass", try time {
            let d = try variantPass(); _ = canOptimizeSide(); _ = bodyAlpha(); pageBody(forecastJob: d)
        }))
        pm.lattice.enabled = true
        for l in lines { print("PASS-TIMING " + l) }
    }
}
