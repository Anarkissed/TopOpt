// LatticeOrganicStandProbe — OPT-IN (NEW_ENGINE_SHOT_DIR=<dir outside the repo>, ORGANIC_STAND_JOB=<LatticeReview's
// stand_file_gab.json, read in place, its model beside it>, ORGANIC_STAND_TENSOR=<its stand.tensor, read in place>): Organic
// cut 1 on HIS v2 stand with its real stress, through the app's own session and renderer. Grown and Traced with every control
// at Auto, laid Exact, drawn at the six windows in the key's colours, Grown's net skin by the light pass. The lay's time and
// counts are printed. Nothing of his is copied: the pictures go outside the repo.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeOrganicStandProbe: XCTestCase {

    @MainActor
    func testOrganicOnHisStandAtTheSixWindows() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["NEW_ENGINE_SHOT_DIR"], let jobPath = env["ORGANIC_STAND_JOB"],
              let tensorPath = env["ORGANIC_STAND_TENSOR"] else {
            throw XCTSkip("opt-in: NEW_ENGINE_SHOT_DIR, ORGANIC_STAND_JOB and ORGANIC_STAND_TENSOR")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let job = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: jobPath))) as? [String: Any])
        let layout = try XCTUnwrap(job["layout"] as? [String: Any])
        let step = (jobPath as NSString).deletingLastPathComponent + "/" + (job["model"] as? String ?? "model.step")
        let s = Self.settings(layout)
        let session = try await LatticeLayoutSession.open(path: step)
        addTeardownBlock { session.close() }
        let t = try Self.tensor(tensorPath)
        try await session.setTensor(voigt: t.voigt, nx: t.nx, ny: t.ny, nz: t.nz, origin: t.origin, spacingMM: t.spacing)
        let all = try await session.sweepLimits(s, lineMM: s.beadMM)
        let measured = try XCTUnwrap(all.first(where: \.measured), "premise: his stand's woven regions are measured")
        let limits = LatticeOrganicLook.Limits(measured)
        print(String(format: "ORGANIC-STAND Auto Sweep: D %.1f mm, struts %.2f to %.2f (Auto %.2f), cells %.1f to %.1f (Auto %.1f)",
                     measured.dMM, limits.strutLowerMM, limits.strutUpperMM, limits.strutAutoMM, limits.cellLowerMM,
                     limits.cellUpperMM, limits.cellAutoMM))

        let m = try TopOptKit.importMesh(path: step)
        let mesh = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, faceGeometry: m.faceGeometry,
                              pseudoFaces: m.pseudoFaces)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let windows: [(String, CGSize)] = [("13L", AppBuildHost.landscape13), ("13P", AppBuildHost.portrait13),
                                           ("11L", AppBuildHost.landscape11), ("11P", AppBuildHost.portrait11),
                                           ("MSL", AppBuildHost.moreSpace), ("MSP", AppBuildHost.moreSpacePortrait)]
        for mode in [LatticeOrganicLook.Mode.traced, .grown] {
            var look = LatticeOrganicLook()
            look.mode = mode
            let r = try await session.layOrganic(s, look.ask(limits: limits, layerMM: 0.2))
            let seg = LatticeLayoutPreview.segments(r.runs)
            print("ORGANIC-STAND " + LatticeLayoutPreview.organicTimeLine(mode: mode, draft: false, ms: r.ms, struts: seg.count)
                  + " · \(seg.count - Swift.min(LatticeLayoutPreview.organicLightFrom(grown: mode == .grown, netFrom: seg.lightFrom, count: seg.count), seg.count)) by the light pass · \(r.strands) strands")
            XCTAssertGreaterThan(seg.count, 1_000, "★ \(mode.title): his stand's weave")
            var laid = LatticeLayoutColours.Laid()
            laid.bars = seg.bars; laid.barFlags = seg.skin; laid.barCell = seg.cell; laid.barRegion = seg.region; laid.token = 1
            var inputs = LatticeLayoutBarsInputs(token: 1, bars: seg.bars, flags: seg.flags,
                                                 colours: LatticeLayoutColours.colours(laid, type: nil, grade: false), colourKey: 1)
            inputs.lightFrom = LatticeLayoutPreview.organicLightFrom(grown: mode == .grown, netFrom: seg.lightFrom, count: seg.count)
            for (win, size) in windows {
                guard let rr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
                rr.setMesh(mesh)
                rr.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
                XCTAssertTrue(rr.applyLayoutBars(inputs, device: device))
                rr.camera.setOrientation(azimuth: 0.55, elevation: 0.35)
                let w = Int(size.width), h = Int(size.height)
                let px = try XCTUnwrap(rr.renderOffscreen(width: w, height: h,
                                                          clear: MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)))
                try LatticeLayoutStandProbe.png(px, w, h, to: (dir as NSString).appendingPathComponent("organic-\(mode.rawValue)-\(win).png"))
            }
        }
    }

    /// The stand job's "where" as the app's settings (its regions, woven, and its Protect skins).
    static func settings(_ L: [String: Any]) -> LatticeLayoutSession.Settings {
        func ints(_ k: String) -> [Int32] { (L[k] as? [NSNumber] ?? []).map(\.int32Value) }
        func dbls(_ k: String) -> [Double] { (L[k] as? [NSNumber] ?? []).map(\.doubleValue) }
        func bools(_ k: String) -> [Bool] { (L[k] as? [Any] ?? []).map { ($0 as? Bool) ?? (($0 as? NSNumber)?.boolValue ?? false) } }
        var s = LatticeLayoutSession.Settings()
        s.allLattice = L["all_lattice"] as? Bool ?? false
        s.beadMM = (L["bead_mm"] as? NSNumber)?.doubleValue ?? 0.45
        s.minStrutLines = (L["min_strut_lines"] as? NSNumber)?.doubleValue ?? 2
        s.algorithm = L["algorithm"] as? String ?? s.algorithm
        s.topology = L["topology"] as? String ?? s.topology
        let ids = ints("region_ids"), counts = ints("region_face_counts"), faces = ints("region_faces")
        let depth = dbls("region_depth_mm"), weave = bools("region_weave"), none = ints("region_no_lattice")
        var at = 0
        for (i, id) in ids.enumerated() {
            let n = Int(counts[i])
            var r = LatticeLayoutSession.Region(id: id, noLattice: i < none.count && none[i] != 0, faces: Array(faces[at..<at + n]),
                                                depthMM: depth[i])
            r.weave = i < weave.count && weave[i]
            s.regions.append(r)
            at += n
        }
        let pids = ints("protect_ids"), pcounts = ints("protect_face_counts"), pfaces = ints("protect_faces")
        let pdepth = dbls("protect_depth_mm")
        at = 0
        for (i, id) in pids.enumerated() {
            let n = Int(pcounts[i])
            s.protect.append(.init(id: id, faces: Array(pfaces[at..<at + n]), depthMM: pdepth[i]))
            at += n
        }
        return s
    }

    /// core's TOTENSOR file (file_job.cpp read_tensor_file): magic, version 1, nx ny nz, origin, spacing, 6 float32 per voxel.
    static func tensor(_ path: String) throws -> (voigt: [Double], nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, spacing: Double) {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(String(data: d.prefix(8), encoding: .ascii), "TOTENSOR")
        func i32(_ o: Int) -> Int { Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }) }
        func f64(_ o: Int) -> Double { d.subdata(in: o..<o + 8).withUnsafeBytes { $0.loadUnaligned(as: Double.self) } }
        let nx = i32(12), ny = i32(16), nz = i32(20)
        let head = 56, n = nx * ny * nz
        XCTAssertEqual(d.count, head + 24 * n, "the tensor file's size")
        let voigt: [Double] = d.subdata(in: head..<head + 24 * n).withUnsafeBytes { raw in
            (0..<(6 * n)).map { Double(raw.loadUnaligned(fromByteOffset: 4 * $0, as: Float.self)) }
        }
        return (voigt, nx, ny, nz, SIMD3(f64(24), f64(32), f64(40)), f64(48))
    }
}
#endif
