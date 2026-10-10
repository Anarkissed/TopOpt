import XCTest
import Metal
import simd
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import TopOptFlows

/// PROBE: render his part through the real mesh renderer, body visible, from the back and
/// the front, octet and organic, and SAVE the pictures — so the cap wall (or its absence)
/// is seen rather than inferred. Also prints each region's outline extent against the mesh.
final class LatticeCapRenderProbe: XCTestCase {
    private func savePNG(_ bgra: [UInt8], _ size: Int, _ path: String) {
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for i in stride(from: 0, to: size * size * 4, by: 4) {
            rgba[i] = bgra[i + 2]; rgba[i + 1] = bgra[i + 1]; rgba[i + 2] = bgra[i]; rgba[i + 3] = 255
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    }

    func testRenderTheCapFromBothSides() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regs = [(15, 12.0), (2, 11.0)].compactMap { f, d in
            LatticeRegionEmission.planeFor(face: FaceID(f), in: mesh).flatMap {
                LatticeRegionEmission.spec(for: $0, role: .include, depthMM: d, faceID: f) }
        }
        try XCTSkipIf(regs.isEmpty)
        print(String(format: "MESH bounds min (%.1f %.1f %.1f) max (%.1f %.1f %.1f)", mesh.bounds.min.x, mesh.bounds.min.y, mesh.bounds.min.z, mesh.bounds.max.x, mesh.bounds.max.y, mesh.bounds.max.z))
        for (i, r) in regs.enumerated() {
            let n = LatticeRegionMask.unit(r.normal); let (bu, bv) = LatticeRegionMask.basis(n)
            var lo = SIMD3<Double>(repeating: 1e9), hi = SIMD3<Double>(repeating: -1e9)
            for loop in r.outlineLoops { for q in loop { let p = r.origin + bu * q.x + bv * q.y; lo = simd_min(lo, p); hi = simd_max(hi, p) } }
            print(String(format: "REGION %d n=(%.0f,%.0f,%.0f) depth %.1f origin (%.1f %.1f %.1f) outline extent (%.1f %.1f %.1f)-(%.1f %.1f %.1f) loops %d", i, n.x, n.y, n.z, r.depthMM, r.origin.x, r.origin.y, r.origin.z, lo.x, lo.y, lo.z, hi.x, hi.y, hi.z, r.outlineLoops.count))
        }
        let n = 56
        let e = mesh.bounds.max - mesh.bounds.min
        let sp = Double(max(e.x, max(e.y, e.z))) / Double(n)
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for i in 0..<(n * n * n) { tensor[6 * i] = 10; tensor[6 * i + 1] = 3; tensor[6 * i + 2] = 1 }
        var input = LatticeOrganicInput(tensor: tensor, dims: (n, n, n), originMM: SIMD3<Double>(mesh.bounds.min),
                                        spacingMM: sp, minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                        separationMinMM: 3.47, separationMaxMM: 5.2, rhoMin: 0.073, rhoMax: 0.9)
        input.solidRimMM = 1.71
        let out = "/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-face-regions-union-split-grid-c52969/906f4155-8092-43dd-96dd-35bc9038cb31/scratchpad"
        for (label, algo, org) in [("octet", "", nil), ("organic", "organic", input)] as [(String, String, LatticeOrganicInput?)] {
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                        algorithm: algo, organic: org, maxDim: 128, regions: regs, whenEmpty: .latticeNothing)
            guard let r = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
            r.setMesh(mesh); r.setLatticeScene(scene, token: 1)
            r.latticeParams = LatticeProxyParams(latticeID: "octet", cellMM: 11, minRelativeDensity: 0.073, maxRelativeDensity: 0.9)
            r.latticeSteppedCellMM = []
            r.setBodyAlpha(1)
            for (view, az, el) in [("back", Double.pi, 0.35), ("front", 0.0, 0.35), ("backlow", Double.pi + 0.5, 0.12)] {
                r.camera.setOrientation(azimuth: Float(az), elevation: Float(el))
                let px = try XCTUnwrap(r.renderOffscreen(size: 640, stage: false))
                savePNG(px, 640, "\(out)/cap-\(label)-\(view).png")
            }
            print("RENDERED \(label): cap verts \(r.shellClipForTests.declCount >= 0 ? "-" : "")")
        }
    }
}

extension LatticeCapRenderProbe {
    /// The cap fragment's decision, on the CPU: for every cap triangle centroid, the part
    /// SDF a voxel and a half inward. Kept ⇔ inside.
    func testWhereTheCapFragmentWouldKeep() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regs = [(15, 12.0), (2, 11.0)].compactMap { f, d in
            LatticeRegionEmission.planeFor(face: FaceID(f), in: mesh).flatMap {
                LatticeRegionEmission.spec(for: $0, role: .include, depthMM: d, faceID: f) }
        }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                    maxDim: 128, regions: regs, whenEmpty: .latticeNothing)
        let cap = LatticeRegionCap.build(regions: regs)
        let g = scene.solidOccupancy
        let voxel = max(g.spacing.x, max(g.spacing.y, g.spacing.z))
        var kept = 0, dropped = 0, outside = 0
        var samples: [String] = []
        for t in 0..<cap.triangleCount {
            var c = SIMD3<Float>(0, 0, 0), nrm = SIMD3<Float>(0, 0, 0)
            for k in 0..<3 {
                let b = (t * 3 + k) * 6
                c += SIMD3<Float>(cap.interleaved[b], cap.interleaved[b+1], cap.interleaved[b+2]) / 3
                nrm = SIMD3<Float>(cap.interleaved[b+3], cap.interleaved[b+4], cap.interleaved[b+5])
            }
            let inward = -simd_normalize(nrm)
            let p = c + inward * (1.5 * voxel)
            let gi = (p - g.origin) / g.spacing
            let i = Int(gi.x.rounded()), j = Int(gi.y.rounded()), k = Int(gi.z.rounded())
            guard i >= 0, j >= 0, k >= 0, i < g.nx, j < g.ny, k < g.nz else { outside += 1; continue }
            let v = g.values[(k * g.ny + j) * g.nx + i]
            if v > 0.5 { kept += 1 } else { dropped += 1 }
            if samples.count < 4 { samples.append(String(format: "c=(%.1f %.1f %.1f) n=(%.0f %.0f %.0f) p=(%.1f %.1f %.1f) sdf=%.2f", c.x, c.y, c.z, nrm.x, nrm.y, nrm.z, p.x, p.y, p.z, v)) }
        }
        print("CAP-CPU triangles \(cap.triangleCount): kept \(kept) dropped \(dropped) outsideGrid \(outside) voxel \(voxel)")
        for s in samples { print("CAP-CPU  \(s)") }
        print(String(format: "CAP-CPU sdf grid origin (%.1f %.1f %.1f) dims %dx%dx%d spacing %.2f", g.origin.x, g.origin.y, g.origin.z, g.nx, g.ny, g.nz, g.spacing.x))
    }
}

extension LatticeCapRenderProbe {
    func testWhereTheMaterialIsPastEachCap() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                    maxDim: 128, regions: [], whenEmpty: .latticeNothing)
        let g = scene.partSDF
        func sdf(_ p: SIMD3<Float>) -> Float {
            let gi = (p - g.origin) / g.spacing
            let i = min(max(Int(gi.x.rounded()), 0), g.nx - 1), j = min(max(Int(gi.y.rounded()), 0), g.ny - 1), k = min(max(Int(gi.z.rounded()), 0), g.nz - 1)
            return g.values[(k * g.ny + j) * g.nx + i]
        }
        for (label, y) in [("front cap +2.5 (y=-10.9)", Float(-10.9)), ("back cap +2.5 (y=-35.4)", Float(-35.4)), ("mid-slot (y=-22)", Float(-22))] {
            var line = ""
            for z in stride(from: Float(0), through: 60, by: 3) { line += String(format: "z%.0f:%+.1f ", z, sdf(SIMD3(90, y, z))) }
            print("SDF-LINE x=90 \(label): \(line)")
        }
        var across = ""
        for y in stride(from: Float(3.7), through: -48.9, by: -2.6) { across += String(format: "y%.0f:%+.1f ", y, sdf(SIMD3(90, y, 6))) }
        print("SDF-LINE x=90 z=6 across the slot: \(across)")
        var across2 = ""
        for y in stride(from: Float(3.7), through: -48.9, by: -2.6) { across2 += String(format: "y%.0f:%+.1f ", y, sdf(SIMD3(90, y, 30))) }
        print("SDF-LINE x=90 z=30 across the slot: \(across2)")
    }
}

extension LatticeCapRenderProbe {
    func testTheSignOfThePartSDF() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                    maxDim: 128, regions: [], whenEmpty: .latticeNothing)
        let g = scene.partSDF, occ = scene.occupancy
        func at(_ grid: LatticeVoxelGrid, _ p: SIMD3<Float>) -> Float {
            let gi = (p - grid.origin) / grid.spacing
            let i = min(max(Int(gi.x.rounded()), 0), grid.nx - 1), j = min(max(Int(gi.y.rounded()), 0), grid.ny - 1), k = min(max(Int(gi.z.rounded()), 0), grid.nz - 1)
            return grid.values[(k * grid.ny + j) * grid.nx + i]
        }
        for (label, p) in [("outside front (y=+20)", SIMD3<Float>(90, 20, 100)), ("cradle air (x90 z150 y-22)", SIMD3<Float>(90, -22, 150)),
                           ("front wall interior (y=-2 z=100)", SIMD3<Float>(20, -2, 100)), ("between walls (y=-22 z=100 x=20)", SIMD3<Float>(20, -22, 100)),
                           ("base (y=-22 z=10)", SIMD3<Float>(90, -22, 10))] {
            print(String(format: "SDF-SIGN %@: sdf %+.2f occupancy %.0f", label, at(g, p), at(occ, p)))
        }
        var neg = 0, pos = 0
        for v in g.values { if v < 0 { neg += 1 } else if v > 0 { pos += 1 } }
        print("SDF-SIGN negative voxels \(neg) positive \(pos) of \(g.values.count); occupancy inside \(occ.values.filter { $0 > 0.5 }.count)")
    }
}
