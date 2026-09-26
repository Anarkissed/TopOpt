import XCTest
import simd
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import TopOptKit
@testable import TopOptFlows

/// ★ PROBE (2026-09-26): CROSS-SECTIONS of the stand's region field, so where the rim is
/// carved can be LOOKED at slice by slice (his image 2: a ledge dug into every wall at the
/// floor; image 1: the wall between face 23 and face 2). Nearest voxel, 5 px per voxel.
///   black  = air · dark red = air the region field calls solid inside a prism
///   grey   = the part outside every prism (the body)
///   white  = skin (solid, skinIn < 0) · blue = rim (solid, skinIn ≥ 0, the lattice layer draws it)
///   lilac  = the pocket (lattice) · green = pocket inside the grade band
/// Env: STAND_SLICES = "x=100;y=-44;z=150" (default), STAND_RENDER_DIR, STAND_DIM.
final class LatticeStandSliceProbe: XCTestCase {
    func testSlices() throws {
        let (_, scene) = try LatticeStandRenderProbe.stand()
        guard let f = scene.regionSDF, let pr = scene.prismSDF, let sk = scene.skinInSDF, let o = scene.outlineSDF else {
            XCTFail("no field"); return
        }
        let solid = scene.solidOccupancy
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STAND_RENDER_DIR"] ?? NSTemporaryDirectory())
        let spec = ProcessInfo.processInfo.environment["STAND_SLICES"] ?? "x=100;y=-44;y=-1;z=150;z=21"
        let band: Float = 10        // his shapeFitBandMM
        for s in spec.split(separator: ";") {
            let kv = s.split(separator: "=")
            let axis = String(kv[0]); let v = Float(kv[1])!
            // the two in-plane axes
            let (a, b): (Int, Int) = axis == "x" ? (1, 2) : axis == "y" ? (0, 2) : (0, 1)
            let ax = axis == "x" ? 0 : axis == "y" ? 1 : 2
            let dims = [f.nx, f.ny, f.nz]
            let orig = [f.origin.x, f.origin.y, f.origin.z], sp = [f.spacing.x, f.spacing.y, f.spacing.z]
            let kFix = Int(((v - orig[ax]) / sp[ax]).rounded())
            guard kFix >= 0, kFix < dims[ax] else { print("SLICE \(s): out of range"); continue }
            let W = dims[a], H = dims[b], px = 5
            var rgba = [UInt8](repeating: 0, count: W * px * H * px * 4)
            var census: [String: Int] = [:]
            for jb in 0..<H { for ia in 0..<W {
                var idx = [0, 0, 0]; idx[ax] = kFix; idx[a] = ia; idx[b] = jb
                let e = (idx[2] * f.ny + idx[1]) * f.nx + idx[0]
                let isSolid = solid.values[e] > 0.5
                let inPrism = pr.values[e] < 0
                let carved = f.values[e] >= 0
                var c: (UInt8, UInt8, UInt8)
                let name: String
                if !isSolid {
                    if inPrism && carved { c = (120, 20, 20); name = "airSolid" } else { c = (10, 10, 14); name = "air" }
                } else if !inPrism { c = (90, 90, 96); name = "body" }
                else if carved { if sk.values[e] < 0 { c = (235, 235, 235); name = "skin" } else { c = (60, 140, 255); name = "rim" } }
                else if o.values[e] < band { c = (40, 200, 140); name = "grade" }
                else { c = (170, 150, 230); name = "pocket" }
                census[name, default: 0] += 1
                // flip vertically so +b is up
                for dy in 0..<px { for dx in 0..<px {
                    let X = ia * px + dx, Y = (H - 1 - jb) * px + dy
                    let q = (Y * W * px + X) * 4
                    rgba[q] = c.0; rgba[q + 1] = c.1; rgba[q + 2] = c.2; rgba[q + 3] = 255
                } }
            } }
            let url = dir.appendingPathComponent("slice_\(axis)\(Int(v)).png")
            Self.write(rgba, W * px, H * px, url)
            let axes = ["x", "y", "z"]
            print("SLICE \(axis)=\(v) (\(axes[a]) → right, \(axes[b]) → up; \(axes[a]) from \(orig[a]), \(axes[b]) from \(orig[b]), voxel \(sp[a]) mm): " + census.keys.sorted().map { "\($0) \(census[$0]!)" }.joined(separator: " · ") + " → \(url.path)")
        }
    }

    static func write(_ rgba: [UInt8], _ w: Int, _ h: Int, _ url: URL) {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
