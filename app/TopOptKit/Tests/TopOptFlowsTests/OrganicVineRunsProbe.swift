// OrganicVineRunsProbe — OPT-IN (VINE_RUNS_DIR=<folder>): his 11-19 note "redo the entirety of how you generate the organic
// vines ... show me an image first". Writes the engine's own runs (centre-line points and widths, as core's preview gives
// them) for the Lattice page's samples, so the vine look can be prototyped on the real lay outside the app. Writes only to
// the folder given; nothing is judged here.
// File: "VRUN" u32 version 1, u32 run count, then per run u32 point count, i32 region, u8 marks, end_a, end_b, pad, then
// per point x y z width (float32, little-endian). Beside it <name>.box: lo xyz, hi xyz (float32) of the sample body.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class OrganicVineRunsProbe: XCTestCase {

    static func write(_ runs: [LatticeLayoutSession.Run], lo: SIMD3<Float>, hi: SIMD3<Float>, to url: URL) throws {
        var d = Data("VRUN".utf8)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        u32(1); u32(UInt32(runs.count))
        for r in runs {
            u32(UInt32(r.points.count)); u32(UInt32(bitPattern: r.region))
            d.append(contentsOf: [r.marks.rawValue, r.endA, r.endB, 0])
            for (k, p) in r.points.enumerated() { f32(p.x); f32(p.y); f32(p.z); f32(r.widthMM[k]) }
        }
        try d.write(to: url)
        var b = Data()
        for v in [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z] { var x = v.bitPattern.littleEndian; b.append(Data(bytes: &x, count: 4)) }
        try b.write(to: url.deletingPathExtension().appendingPathExtension("box"))
    }

    @MainActor
    func testWriteTheSamplesRuns() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VINE_RUNS_DIR"] else { throw XCTSkip("opt-in: VINE_RUNS_DIR") }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for cube in [true, false] {
            let body = try TopOptKit.latticeSampleBody(cube: cube)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vine-probe-\(UUID().uuidString).stl")
            try MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data()).write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            try MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data())
                .write(to: out.appendingPathComponent(cube ? "cube.stl" : "part.stl"))
            let session = try await LatticeLayoutSession.open(path: url.path)
            addTeardownBlock { session.close() }
            let box = LatticeLayoutPreview.box(body.vertices)
            let b = try XCTUnwrap(box)
            var s = LatticeLayoutSession.Settings()
            s.beadMM = 0.45
            s.minStrutLines = 2
            var r = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            r.zone = .init(kind: .box, centre: SIMD3<Double>((b.lo + b.hi) / 2),
                           axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], half: SIMD3<Double>((b.hi - b.lo) / 2) + 1)
            r.weave = true
            s.regions = [r]
            let lim = try await session.sweepLimits(s, regions: [1], lineMM: 0.45).map(LatticeOrganicLook.Limits.init)
            for mode in [LatticeOrganicLook.Mode.traced, .grown] {
                for percent in [50.0, 100.0] {
                    var look = LatticeOrganicLook()
                    look.mode = mode
                    var ask = look.ask(limits: lim.map { $0.looked(percent: percent) }, layerMM: 0.2)
                    ask.quality = .exact
                    let groups = [LatticeLayoutSession.OrganicGroup(regions: [1], ask: ask)]
                    let made = try await session.synthetic(s, groups: groups, walls: [(region: 1, foci: 1)], fromEmpty: true)
                    XCTAssertTrue(made.refused.isEmpty, "\(made.refused.map(\.text))")
                    let laid = try await session.layOrganic(s, groups: groups)
                    XCTAssertTrue(laid.refused.isEmpty, "\(laid.refused.map(\.text))")
                    let name = "\(cube ? "cube" : "part")-\(mode == .grown ? "grown" : "traced")-\(Int(percent)).vrun"
                    try Self.write(laid.runs, lo: SIMD3<Float>(b.lo), hi: SIMD3<Float>(b.hi), to: out.appendingPathComponent(name))
                    print("VINE-RUNS \(name): \(laid.runs.count) runs, \(laid.segments) segments")
                }
            }
        }
    }
}
#endif
