// LatticeTypePicture.swift — ★ notes28 (the maintainer's decision 2026-11-24: all nine strut types on the new engine). Each
// type's card on the Lattice page wears a picture of the type, and the picture is the ENGINE'S OWN SAMPLE of it, never hand
// art: core's 40 mm sample cube laid through the new engine (`LatticeSampleLay`, the same lay as the page's live sample),
// two cells across at the page's Auto density, its bars seen from one fixed corner and flattened to lines. A type the engine
// does not lay has no picture (its card says why instead).
//
// The lay runs off the main thread, one type at a time, once per type for the app's life (core's cell never changes).

import Foundation
import SwiftUI
import simd
import TopOptDesign
import TopOptKit

/// One type's card picture: the engine's bars, as lines in a unit square (y down), far ones first.
public struct LatticeTypePicture: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var a: SIMD2<Float>, b: SIMD2<Float>
        /// The bar's width, in the square's units.
        public var width: Float
        /// 0 the farthest bar, 1 the nearest.
        public var near: Float
    }
    public var topology: String
    public var lines: [Line]
    /// ★ SHEETS (notes28 sheets SPEC 5): a sheet has no bars — its picture is the same field the engine lays (LatticeSheetField),
    /// two cells of the 40 mm sample cube, ray-cast on the CPU from the same fixed corner: `shadeSide` × `shadeSide` pixels,
    /// row by row (y down), 0 = nothing there, else the light on the wall (1 … 255). Empty for a strut type.
    public var shade: [UInt8] = []
    public var shadeSide = 0
    public init(topology: String, lines: [Line], shade: [UInt8] = [], shadeSide: Int = 0) {
        self.topology = topology; self.lines = lines; self.shade = shade; self.shadeSide = shadeSide
    }

    /// Two cells across core's 40 mm sample cube.
    public static let cellMM = 20.0
    /// The page's default bead (the picture is the type's, not his printer's).
    static let beadMM = 0.45
    /// The corner it is seen from: turned 35° about the vertical, looking 25° down.
    static let azimuth: Float = 35 * .pi / 180, elevation: Float = 25 * .pi / 180

    /// What the engine lays for the picture: the type alone, uniform cells, the page's Auto density.
    static func plan(_ id: String) -> LatticeSampleLay {
        var p = LatticeSampleLay.plain(topology: id, cellMM: cellMM, lineWidthMM: beadMM, rho: 0)
        p.settings.dial = 0.45   // ProjectModel.latticeAutoDensityPercent / 100 — his "Auto in the middle"
        return p
    }

    /// Lays the type's sample and draws it. Throws the engine's refusal (a type it does not lay).
    /// ★ SHEETS: a sheet's picture is its field, ray-cast (no lay: the field is the engine's own, `sheetField`).
    public static func make(_ id: String) async throws -> LatticeTypePicture {
        if let kind = LatticeSheetField.Kind(id: id), LatticeLayoutSession.isSheet(id) {
            return await Task.detached(priority: .utility) { sheetPicture(sheetField(kind), topology: id) }.value
        }
        let made = try await LatticeSampleLay.lay(plan(id), cube: true)
        return picture(bars: made.bars, topology: id)
    }

    // MARK: ★ SHEETS: the field, ray-cast

    /// The 40 mm sample cube's side and its picture's pixels.
    static let cubeMM = 40.0
    public static let sheetSide = 128
    /// The type's field on the sample cube: anchored at its corner, two cells across, Auto's wall (core's rule, SPEC 1.3).
    static func sheetField(_ kind: LatticeSheetField.Kind) -> LatticeSheetField {
        let wall = LatticeSheets.autoWallMM(kind.id, cellMM: cellMM, lineWidthMM: beadMM)
        return LatticeSheetField(kind: kind, cellMM: cellMM, wallMM: [Float(wall > 0 ? wall : 0.09 * cellMM)])
    }

    /// The field inside the cube [0, 40]³, seen from the fixed corner (orthographic, the bars' projection), lit from above
    /// the eye; where the cube's faces cut the wall, the cut is flat (the face's own normal), as the print file cuts it.
    public static func sheetPicture(_ f: LatticeSheetField, topology: String, side n: Int = sheetSide) -> LatticeTypePicture {
        let ca = Double(cos(azimuth)), sa = Double(sin(azimuth)), ce = Double(cos(elevation)), se = Double(sin(elevation))
        let right = SIMD3(ca, -sa, 0), down = SIMD3(se * sa, se * ca, -ce), into = SIMD3(ce * sa, ce * ca, se)
        let L = cubeMM, centre = SIMD3<Double>(repeating: L / 2)
        var lo = SIMD2<Double>(repeating: .greatestFiniteMagnitude), hi = -lo
        for c in 0..<8 {
            let p = SIMD3(c & 1 != 0 ? L : 0, c & 2 != 0 ? L : 0, c & 4 != 0 ? L : 0) - centre
            let q = SIMD2(simd_dot(p, right), simd_dot(p, down))
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        let span = Swift.max(hi.x - lo.x, hi.y - lo.y) / (1 - 2 * 0.06)
        let light = simd_normalize(-into + SIMD3(0, 0, 0.8) - 0.3 * right)
        let cap = 0.1 * f.cellMM
        var out = [UInt8](repeating: 0, count: n * n)
        for j in 0..<n { for i in 0..<n {
            let sx = (Double(i) + 0.5) / Double(n) - 0.5, sy = (Double(j) + 0.5) / Double(n) - 0.5
            let ro = centre + sx * span * right + sy * span * down - 2 * L * into
            // the cube's box along the ray
            var t0 = -Double.greatestFiniteMagnitude, t1 = Double.greatestFiniteMagnitude
            var faceAxis = 0
            for k in 0..<3 {
                let d = into[k], o = ro[k]
                if abs(d) < 1e-12 { if o < 0 || o > L { t0 = 1; t1 = 0 }; continue }
                let a = (0 - o) / d, b = (L - o) / d
                if Swift.min(a, b) > t0 { t0 = Swift.min(a, b); faceAxis = k }
                t1 = Swift.min(t1, Swift.max(a, b))
            }
            guard t0 < t1 else { continue }
            var t = t0, hitN: SIMD3<Double>?
            if f.distance(ro + into * t) < 0 {   // entered through a face while inside the wall: the flat cut
                var nrm = SIMD3<Double>.zero
                nrm[faceAxis] = -(into[faceAxis] > 0 ? 1 : -1)
                hitN = nrm
            } else {
                var steps = 0
                while t < t1, steps < 2000 {
                    let d = f.distance(ro + into * t)
                    if d < 0 {
                        let p = ro + into * t, e = 0.02
                        let g = SIMD3(f.distance(p + SIMD3(e, 0, 0)) - f.distance(p - SIMD3(e, 0, 0)),
                                      f.distance(p + SIMD3(0, e, 0)) - f.distance(p - SIMD3(0, e, 0)),
                                      f.distance(p + SIMD3(0, 0, e)) - f.distance(p - SIMD3(0, 0, e)))
                        var nrm = simd_length(g) > 1e-12 ? simd_normalize(g) : -into
                        if simd_dot(nrm, into) > 0 { nrm = -nrm }
                        hitN = nrm
                        break
                    }
                    t += Swift.min(Swift.max(0.6 * d, 0.02), cap)
                    steps += 1
                }
            }
            guard let nrm = hitN else { continue }
            let near = 1 - Swift.min(Swift.max((t - t0) / (2 * L * 0.9), 0), 1)
            let lit = 0.30 + 0.55 * Swift.max(0, simd_dot(nrm, light)) + 0.15 * near
            out[j * n + i] = UInt8(Swift.max(1, Swift.min(255, (lit * 255).rounded())))
        } }
        return LatticeTypePicture(topology: topology, lines: [], shade: out, shadeSide: n)
    }

    /// The bars (7 per bar: a xyz, b xyz, width mm) seen from the fixed corner, fitted into the unit square with a margin.
    public static func picture(bars: [Float], topology: String) -> LatticeTypePicture {
        let ca = cos(azimuth), sa = sin(azimuth), ce = cos(elevation), se = sin(elevation)
        func project(_ p: SIMD3<Float>) -> (SIMD2<Float>, Float) {
            let x = ca * p.x - sa * p.y, y = sa * p.x + ca * p.y
            return (SIMD2(x, -(ce * p.z - se * y)), ce * y + se * p.z)   // screen (y down), depth (larger = farther)
        }
        var raw: [(a: SIMD2<Float>, b: SIMD2<Float>, w: Float, depth: Float)] = []
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var dLo = Float.greatestFiniteMagnitude, dHi = -dLo
        for i in stride(from: 0, to: bars.count - 6, by: 7) {
            let (a, da) = project(SIMD3(bars[i], bars[i + 1], bars[i + 2]))
            let (b, db) = project(SIMD3(bars[i + 3], bars[i + 4], bars[i + 5]))
            raw.append((a, b, bars[i + 6], 0.5 * (da + db)))
            lo = simd_min(lo, simd_min(a, b)); hi = simd_max(hi, simd_max(a, b))
            dLo = Swift.min(dLo, 0.5 * (da + db)); dHi = Swift.max(dHi, 0.5 * (da + db))
        }
        guard !raw.isEmpty else { return LatticeTypePicture(topology: topology, lines: []) }
        let margin: Float = 0.06
        let span = Swift.max(hi.x - lo.x, hi.y - lo.y, 1e-6)
        let scale = (1 - 2 * margin) / span
        let centre = 0.5 * (lo + hi)
        func fit(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(repeating: 0.5) + (p - centre) * scale }
        let lines = raw.sorted { $0.depth > $1.depth }.map { r in
            Line(a: fit(r.a), b: fit(r.b), width: r.w * scale,
                 near: dHi > dLo ? (dHi - r.depth) / (dHi - dLo) : 1)
        }
        return LatticeTypePicture(topology: topology, lines: lines)
    }
}

/// The pictures made so far, one lay at a time (each opens its own session on the sample cube).
@MainActor
final class LatticeTypePictures: ObservableObject {
    static let shared = LatticeTypePictures()
    @Published private(set) var made: [String: LatticeTypePicture] = [:]
    private var asked: Set<String> = []
    private var chain: Task<Void, Never>?

    /// Lays `id`'s picture unless it is made or on its way.
    func ask(_ id: String) {
        guard asked.insert(id).inserted else { return }
        let before = chain
        chain = Task { [weak self] in
            await before?.value
            guard let p = try? await LatticeTypePicture.make(id) else { return }
            self?.made[id] = p
        }
    }
}

/// A card's picture of `id`, drawn in the lattice's own colour (nearer bars stronger). Empty until the engine has laid it.
struct LatticeTypePictureView: View {
    let id: String
    var greyed = false
    @ObservedObject private var pictures = LatticeTypePictures.shared

    var body: some View {
        Canvas { ctx, size in
            guard let p = pictures.made[id] else { return }
            let side = Swift.min(size.width, size.height)
            let o = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let c = LatticeStructureColour.interior
            if p.shadeSide > 0, let img = Self.image(p, greyed: greyed) {   // ★ SHEETS: the field, shaded
                ctx.draw(Image(decorative: img, scale: 1), in: CGRect(x: o.x, y: o.y, width: side, height: side))
                return
            }
            for l in p.lines {
                var path = Path()
                path.move(to: CGPoint(x: o.x + CGFloat(l.a.x) * side, y: o.y + CGFloat(l.a.y) * side))
                path.addLine(to: CGPoint(x: o.x + CGFloat(l.b.x) * side, y: o.y + CGFloat(l.b.y) * side))
                let shade = 0.55 + 0.45 * Double(l.near)
                let colour = greyed ? Color.gray.opacity(0.25 + 0.35 * Double(l.near))
                                    : Color(red: c.r * shade, green: c.g * shade, blue: c.b * shade)
                ctx.stroke(path, with: .color(colour),
                           style: StrokeStyle(lineWidth: Swift.max(0.8, CGFloat(l.width) * side), lineCap: .round))
            }
        }
        .task { pictures.ask(id) }
        .accessibilityHidden(true)
    }

    /// ★ SHEETS: the shaded field as an image in the lattice's own colour (grey when greyed), clear where nothing is.
    static func image(_ p: LatticeTypePicture, greyed: Bool) -> CGImage? {
        let n = p.shadeSide
        guard n > 0, p.shade.count == n * n else { return nil }
        let c = LatticeStructureColour.interior
        var rgba = [UInt8](repeating: 0, count: 4 * n * n)
        for (i, s) in p.shade.enumerated() where s > 0 {
            let k = Double(s) / 255
            let a = greyed ? 0.63 : 1.0   // premultiplied
            let (r, g, b) = greyed ? (0.6 * k * a, 0.6 * k * a, 0.6 * k * a) : (c.r * k, c.g * k, c.b * k)
            rgba[4 * i] = UInt8(Swift.min(255, (r * 255).rounded())); rgba[4 * i + 1] = UInt8(Swift.min(255, (g * 255).rounded()))
            rgba[4 * i + 2] = UInt8(Swift.min(255, (b * 255).rounded())); rgba[4 * i + 3] = UInt8((a * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * n,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
