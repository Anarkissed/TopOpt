// MeshThumbnail.swift — render a mesh to a small image for the Library grid.
//
// Reuses the viewer's offscreen Metal render (`renderOffscreen` → BGRA) and wraps
// the pixels in a CGImage. Works headlessly (Metal is available on the maintainer's
// Mac + device), so it is unit-tested; the on-screen look is device QA.

import Foundation
import CoreGraphics
import Metal
import TopOptDesign

public enum MeshThumbnail {
    /// Render `mesh` to a square `size`×`size` CGImage on the dark stage, or nil
    /// (no mesh / no Metal device).
    public static func cgImage(for mesh: ViewerMesh, size: Int = 400) -> CGImage? {
        guard !mesh.isEmpty,
              let device = MTLCreateSystemDefaultDevice(),
              let renderer = MeshRenderer(device: device) else { return nil }
        renderer.setMesh(mesh)   // frames the camera to the part
        let bg = DS.Color.background
        let clear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        guard let bgra = renderer.renderOffscreen(size: size, clear: clear) else { return nil }
        return image(from: bgra, size: size)
    }

    /// BGRA8 bytes → a CGImage (premultiplied-first, little-endian = BGRA layout).
    static func image(from bgra: [UInt8], size: Int) -> CGImage? {
        guard bgra.count == size * size * 4,
              let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
