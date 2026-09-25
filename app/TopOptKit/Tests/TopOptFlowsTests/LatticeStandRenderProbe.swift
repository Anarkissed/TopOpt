import XCTest
import Metal
import simd
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import TopOptKit
@testable import TopOptFlows
@testable import TopOptDesign

/// ★ PROBE (2026-09-25): the real stand rendered by the app's own lattice layer, body hidden,
/// from several angles — PNGs in the scratchpad, so the rim can be LOOKED at, not inferred.
final class LatticeStandRenderProbe: XCTestCase {
    static func stand() throws -> (ViewerMesh, LatticeSDFScene) {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [15, 2, 23], regionIDs: [])
        let key23 = LatticeSelectableRef.face(group: gid, face: 23).key
        let solidGrid = LatticePreviewOccupancy.occupancy(positions: mesh.positions, indices: mesh.indices, bounds: mesh.bounds, maxDim: 128)
        func solidAt(_ p: SIMD3<Double>) -> Bool {
            let g = (SIMD3<Float>(p) - solidGrid.origin) / solidGrid.spacing
            let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
            guard i >= 0, j >= 0, k >= 0, i < solidGrid.nx, j < solidGrid.ny, k < solidGrid.nz else { return false }
            return solidGrid.values[(k * solidGrid.ny + j) * solidGrid.nx + i] > 0.5
        }
        let regions = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include], primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 12,
            selectableDepthMM: [LatticeSelectableRef.face(group: gid, face: 2).key: 13, key23: 20],
            selectableExpandMM: [key23: 4.15],
            facets: { LatticeFaceFacets.facets(face: $0, in: mesh) },
            solidAt: solidAt,
            resolve: { LatticeRegionEmission.planeFor(face: $0, in: mesh) }).regions
        let n = 8
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for i in 0..<(n * n * n) { tensor[6 * i] = 10; tensor[6 * i + 1] = 3; tensor[6 * i + 2] = 1 }
        var o = LatticeOrganicInput(tensor: tensor, dims: (n, n, n), originMM: SIMD3(Double(mesh.bounds.min.x), Double(mesh.bounds.min.y), Double(mesh.bounds.min.z)),
                                    spacingMM: 30, minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                    separationMinMM: 3, separationMaxMM: 3, rhoMin: 0.05, rhoMax: 0.9, showRepairs: false)
        o.solidRimMM = 3.41
        // one tiny span, so the renderer draws capsules and the march runs SOLID-ONLY as in
        // the app (the rim band and nothing else)
        var segs: [OrganicSpanIndex.Segment] = [.init(a: SIMD3<Float>(100, -22, 60), b: SIMD3<Float>(101, -22, 60), r: 0.3)]
        if ProcessInfo.processInfo.environment["STAND_SIDE_SPANS"] == "1" {
            // struts running out to the leg's two side faces (y = −49 and y = 4) and 3 mm past
            // them, over the leg's height — does the capsule pipeline draw anything in the air?
            for z in stride(from: Float(30), through: 190, by: 8) { for x in stride(from: Float(-12), through: 4, by: 4) {
                segs.append(.init(a: SIMD3<Float>(x, -44, z), b: SIMD3<Float>(x, -52, z), r: 0.5))
                segs.append(.init(a: SIMD3<Float>(x, -1, z), b: SIMD3<Float>(x, 7, z), r: 0.5))
            } }
        }
        if ProcessInfo.processInfo.environment["STAND_DENSE_SPANS"] == "1" {
            // a strut through every pocket voxel, random direction, 3 mm long — the density
            // the app's trace reaches, so the capsule pipeline is exercised everywhere
            var rng = SystemRandomNumberGenerator()
            let inc = regions.filter { $0.role == .include }
            let sp = solidGrid.spacing
            for k in 0..<solidGrid.nz { for j in 0..<solidGrid.ny { for i in 0..<solidGrid.nx {
                guard solidGrid.values[(k * solidGrid.ny + j) * solidGrid.nx + i] > 0.5 else { continue }
                let p = SIMD3<Double>(solidGrid.origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * sp)
                guard inc.contains(where: { LatticeRegionMask.contains(p, region: $0) }) else { continue }
                for _ in 0..<2 {
                    let d = simd_normalize(SIMD3<Float>(Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng)))
                    let c = SIMD3<Float>(p) + SIMD3<Float>(Float.random(in: -0.8...0.8, using: &rng), Float.random(in: -0.8...0.8, using: &rng), Float.random(in: -0.8...0.8, using: &rng))
                    segs.append(.init(a: c - d * 1.5, b: c + d * 1.5, r: 0.3))
                }
            } } }
        }
        let spans = OrganicSpanIndex(gridOrigin: mesh.bounds.min, gridSpacing: 2, gridDims: SIMD3<Int32>(4, 4, 4), segments: segs)
        let injectSpan = ProcessInfo.processInfo.environment["STAND_ONE_SPAN"] == "1"
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", organicSpans: injectSpan ? spans : nil, stageMode: .aesthetic,
                                    algorithm: "organic", organic: o, regions: regions, whenEmpty: .latticeNothing)
        print("RENDER scene capsules \(scene.organicCapsules.count)")
        return (mesh, scene)
    }

    static func writePNG(_ d: MeshRenderer.LatticeMaskDump, to url: URL) {
        var rgba = [UInt8](repeating: 0, count: d.width * d.height * 4)
        for i in 0..<(d.width * d.height) {
            if d.mask[i] {
                rgba[i * 4] = d.rgb[i * 3]; rgba[i * 4 + 1] = d.rgb[i * 3 + 1]; rgba[i * 4 + 2] = d.rgb[i * 3 + 2]; rgba[i * 4 + 3] = 255
            } else { rgba[i * 4] = 20; rgba[i * 4 + 1] = 20; rgba[i * 4 + 2] = 30; rgba[i * 4 + 3] = 255 }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: d.width, height: d.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: d.width * 4,
                                space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    @MainActor
    func testRenderTheStand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let (mesh, scene) = try Self.stand()
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("renderer") }
        try XCTSkipUnless(renderer.latticePipelinesDidBuild)
        renderer.setMesh(mesh)
        renderer.setLatticeScene(scene, token: 1)
        renderer.latticeParams = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold(cellMM: 4.0)
        renderer.setBodyAlpha(0)
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STAND_RENDER_DIR"] ?? NSTemporaryDirectory())
        let views: [(String, Float, Float)] = ProcessInfo.processInfo.environment["STAND_VIEWS"].map { v in
            v.split(separator: ";").map { t in let c = t.split(separator: ","); return (String(c[0]), Float(c[1])!, Float(c[2])!) }
        } ?? [("a", 0.6, 0.35), ("b", -0.6, 0.35), ("c", 2.5, 0.35), ("d", -2.5, 0.35), ("e", 1.57, 0.6), ("f", 0.0, 0.05)]
        for (name, az, el) in views {
            renderer.camera.setOrientation(azimuth: az, elevation: el)
            guard let d = renderer.latticeMaskDump(size: 900) else { print("RENDER \(name): no dump"); continue }
            var blue = 0, green = 0, lilac = 0
            for i in 0..<d.mask.count where d.mask[i] {
                let r = Int(d.rgb[i * 3]), g = Int(d.rgb[i * 3 + 1]), b = Int(d.rgb[i * 3 + 2])
                if g > r + 30 && g > b { green += 1 } else if b > r + 60 && b > g + 30 { blue += 1 } else { lilac += 1 }
            }
            let url = dir.appendingPathComponent("stand_\(name).png")
            Self.writePNG(d, to: url)
            print("RENDER \(name) az \(az) el \(el): covered \(d.covered) · blue \(blue) green \(green) other \(lilac) → \(url.path)")
        }
    }
}
