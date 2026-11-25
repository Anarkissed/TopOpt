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
    public static func make(_ id: String) async throws -> LatticeTypePicture {
        let made = try await LatticeSampleLay.lay(plan(id), cube: true)
        return picture(bars: made.bars, topology: id)
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
}
