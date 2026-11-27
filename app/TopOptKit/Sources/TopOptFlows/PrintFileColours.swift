// PrintFileColours.swift — ★ notes27 F1 (his iPad 2026-11-23 ~23:45 on release 17, img 1: "The stress map is meant to be on the
// *entire* model, the stress colours should change as the bend/breaks happen. It shouldn't JUST BE on the few struts. What
// happened here?").
//
// What happened (release 17): a print file's colours came from two things only — core's 20 listed weakest struts (each drawn as a
// tube round its ends) and the solid's own margin per voxel (fields.bin block 2), which the app keeps in the saved report since
// release 17. Every other place was "not judged" and drew plain. His Organic v8.1 was made at 18:33 by the release-16 app, so its
// saved report has no solid margins: only the listed struts were coloured (about six of them in view) and the solid drew plain.
//
// What it is now: EVERY place on the part is coloured by how close it is to giving way at your load (red at 1), on C's one fixed
// scale — the GPU multiplies it by the load each frame, so the colours move with Bend and Break:
//   * every strut: core's bars.bin (each bar's two ends and width, in strut_margins.bin's order). Each print-file vertex takes its
//     nearest bar's margin (the bars in a grid of cells). The file's first `base_triangles` are the solid, the rest the struts;
//   * the solid: its own margin per voxel (fields.bin block 2);
//   * what neither judged (an older file with no bars.bin, a bar core did not judge, a voxel with no margin): the stress field
//     against the material's limit at his infill (the solid result's own scale), never above the share of the place core says
//     gives way first (its one answer: nothing gives way before it). Never plain.
// Pure: Notes27ResultsTests.

import Foundation
import simd

/// ★ notes27 F1: what a print file's saved report carries to colour every strut — bars.bin's bars, strut_margins.bin's margins
/// (both fetched from the Mac and kept in the report by `LatticeFileButton.withStrength`) and how many of the file's first
/// triangles are the solid.
public struct PrintFileParts: Sendable {
    /// The report key the app keeps bars.bin under (base64 of the file as core wrote it).
    public static let barsKey = "app_bars"
    /// The report key the app keeps strut_margins.bin under (base64, one float32 per bar).
    public static let marginsKey = "app_strut_margins"
    /// bars.bin's first eight bytes.
    public static let magic: [UInt8] = Array("TOBARS1".utf8) + [0]
    /// Per bar: ax ay az bx by bz width_mm (model mm), in strut_margins.bin's order. Empty: an older file.
    public let bars: [Float]
    /// Per bar: its margin (NaN: core did not judge it). May be shorter than the bars (then the rest are not judged).
    public let margins: [Float]
    /// The print file's first triangles that are the solid (core's `base_triangles`), nil when the report does not say.
    public let baseTriangles: Int?
    /// ★ notes27 (his 11-24: the Strengthened row lights the struts it changed): per bar, what the strengthening did to it —
    /// bit 0 thickened, bit 1 a brace it added (bars.bin's optional flags, below). Empty: the file does not say.
    public let flags: [UInt8]

    public var barCount: Int { bars.count / 7 }

    /// bars.bin's flags bits.
    public static let thickenedBit: UInt8 = 1, braceBit: UInt8 = 2

    public init(bars: [Float], margins: [Float], baseTriangles: Int?, flags: [UInt8] = []) {
        self.bars = bars; self.margins = margins; self.baseTriangles = baseTriangles; self.flags = flags
    }

    /// bars.bin: "TOBARS1\0", uint32 N, uint32 F, then N × 7 float32 (little-endian); with F = 1, N bytes of flags follow (bit 0:
    /// the strengthening thickened the bar, bit 1: a brace it added). nil when it is not that.
    public static func parse(_ d: Data) -> (bars: [Float], flags: [UInt8])? {
        guard d.count >= 16 else { return nil }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (bars: [Float], flags: [UInt8])? in
            guard Array(raw[0..<8]) == magic else { return nil }
            let n = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian)
            let f = raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
            guard n > 0, n <= (raw.count - 16) / 28 else { return nil }
            var out = [Float](repeating: 0, count: n * 7)
            for i in 0..<(n * 7) {
                out[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: 16 + 4 * i, as: UInt32.self).littleEndian)
            }
            let at = 16 + 28 * n
            let flags = f == 1 && raw.count >= at + n ? Array(raw[at..<(at + n)]) : []
            return (out, flags)
        }
    }
    public static func parseBars(_ d: Data) -> [Float]? { parse(d)?.bars }

    /// From a saved report: nil when it carries neither bars nor the solid's triangle count.
    public static func decode(report r: [String: Any]) -> PrintFileParts? {
        let file = (r[barsKey] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(parse)
        let bars = file?.bars ?? []
        let margins: [Float] = (r[marginsKey] as? String).flatMap { SolidMarginVoxels.unb64($0) } ?? []
        let base = (r["base_triangles"] as? NSNumber)?.intValue
        guard !bars.isEmpty || base != nil else { return nil }
        return PrintFileParts(bars: bars, margins: margins, baseTriangles: base.flatMap { $0 > 0 ? $0 : nil },
                              flags: file?.flags ?? [])
    }

    /// ★ notes27: the bars the strengthening changed (thickened or braced), from bars.bin's flags; without them, only the bars
    /// past the limit it never thickens a strut beyond unless it must (`limitMM`, his thickest strut) — those it surely thickened.
    /// nil: nothing it changed can be told.
    public func changed(limitMM: Double?) -> [Bool]? {
        let n = barCount
        guard n > 0 else { return nil }
        var out: [Bool]
        if flags.count == n {
            out = flags.map { $0 & (Self.thickenedBit | Self.braceBit) != 0 }
        } else if let l = limitMM, l > 0 {
            out = (0..<n).map { Double(bars[7 * $0 + 6]) > l + 0.005 }
        } else {
            return nil
        }
        return out.contains(true) ? out : nil
    }

    /// The margin of bar `i` (NaN when core did not judge it).
    func margin(_ i: Int) -> Float { i >= 0 && i < margins.count ? margins[i] : .nan }

    /// Per shared vertex of a mesh: the solid (the file's first `base_triangles`), a strut (the rest), or not known (no count,
    /// or a count that is not this mesh's).
    public func kinds(indices: [UInt32], vertexCount n: Int) -> [PrintFileColouring.Kind] {
        var out = [PrintFileColouring.Kind](repeating: .unknown, count: n)
        let tris = indices.count / 3
        guard let base = baseTriangles, base <= tris else { return out }
        for t in 0..<tris {
            let k: PrintFileColouring.Kind = t < base ? .solid : .strut
            for c in 0..<3 {
                let v = Int(indices[3 * t + c])
                if v < n, out[v] != .strut { out[v] = k }   // a vertex both share is the strut's
            }
        }
        return out
    }

    /// Per shared vertex, whether it is on a bar `changed` marks (a strut's vertex: its own bar; the solid's: never). nil: no bars.
    func onChanged(positions pos: [Float], indices: [UInt32], changed: [Bool]) -> [Bool]? {
        guard let grid = BarGrid(bars: bars) else { return nil }
        let n = pos.count / 3
        let kinds = kinds(indices: indices, vertexCount: n)
        var lit = [Bool](repeating: false, count: n)
        let chunks = Swift.max(1, Swift.min(16, n / 20_000))
        lit.withUnsafeMutableBufferPointer { lb in
            let lp = lb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                for v in (n * c / chunks)..<(n * (c + 1) / chunks) {
                    let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
                    if let b = Self.bar(grid, p, kinds[v]), b < changed.count { lp[v] = changed[b] }
                }
            }
        }
        return lit
    }

    /// A strut vertex's bar (its nearest, wherever it is); a vertex not known to be a strut: a bar whose surface it is on.
    static func bar(_ g: BarGrid, _ p: SIMD3<Float>, _ kind: PrintFileColouring.Kind) -> Int? {
        guard kind != .solid, let hit = g.nearest(p, rings: kind == .strut ? 2 : 0),
              kind == .strut || hit.gap <= Swift.max(0.25, 0.25 * hit.radius) else { return nil }
        return hit.index
    }
}

/// ★ notes27 F1: the bars in a grid of cells — each bar listed in every cell its capsule (its radius plus a little) reaches — for
/// the nearest bar to a point. "Nearest" is by the gap to its surface: the distance to its axis less its radius.
struct BarGrid {
    let lo: SIMD3<Float>
    let h: Float
    let nx: Int, ny: Int, nz: Int
    /// CSR: cell c's bars are items[start[c] ..< start[c + 1]].
    let start: [Int32]
    let items: [Int32]
    let a: [SIMD3<Float>]
    let ab: [SIMD3<Float>]
    let len2: [Float]
    let r: [Float]
    /// How far past a bar's surface it is listed (mm).
    let pad: Float

    init?(bars: [Float]) {
        let n = bars.count / 7
        guard n > 0 else { return nil }
        var a = [SIMD3<Float>](repeating: .zero, count: n), ab = a
        var len2 = [Float](repeating: 0, count: n), r = [Float](repeating: -1, count: n)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var widthSum: Double = 0, valid = 0
        for i in 0..<n {
            let p = SIMD3(bars[7 * i], bars[7 * i + 1], bars[7 * i + 2])
            let q = SIMD3(bars[7 * i + 3], bars[7 * i + 4], bars[7 * i + 5])
            let w = bars[7 * i + 6]
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, q.x.isFinite, q.y.isFinite, q.z.isFinite, w.isFinite, w >= 0 else {
                continue   // left out (r < 0)
            }
            a[i] = p; ab[i] = q - p; len2[i] = simd_length_squared(q - p); r[i] = w / 2
            lo = simd_min(lo, simd_min(p, q) - SIMD3(repeating: w / 2))
            hi = simd_max(hi, simd_max(p, q) + SIMD3(repeating: w / 2))
            widthSum += Double(w); valid += 1
        }
        guard valid > 0 else { return nil }
        // a cell about a bar's width (never below 0.4 mm), at most ~2 million cells
        var h = Swift.max(0.4, Float(widthSum / Double(valid)))
        let pad = 0.5 * h
        lo -= SIMD3(repeating: pad + h); hi += SIMD3(repeating: pad + h)
        let ext = hi - lo
        while Double(ext.x / h + 1) * Double(ext.y / h + 1) * Double(ext.z / h + 1) > 2_000_000 { h *= 1.25 }
        let nx = Swift.max(1, Int((ext.x / h).rounded(.up))), ny = Swift.max(1, Int((ext.y / h).rounded(.up)))
        let nz = Swift.max(1, Int((ext.z / h).rounded(.up)))
        let cells = nx * ny * nz
        // the cells a bar reaches: those whose centre is within its radius + pad + half a cell's diagonal of its axis
        let halfDiag = h * 0.8660254
        func each(_ i: Int, _ body: (Int) -> Void) {
            guard r[i] >= 0 else { return }
            let reach = r[i] + pad + halfDiag
            let b = a[i] + ab[i]
            let mn = simd_min(a[i], b) - SIMD3(repeating: reach - halfDiag) - lo
            let mx = simd_max(a[i], b) + SIMD3(repeating: reach - halfDiag) - lo
            let i0 = Swift.max(0, Int((mn.x / h).rounded(.down))), i1 = Swift.min(nx - 1, Int((mx.x / h).rounded(.down)))
            let j0 = Swift.max(0, Int((mn.y / h).rounded(.down))), j1 = Swift.min(ny - 1, Int((mx.y / h).rounded(.down)))
            let k0 = Swift.max(0, Int((mn.z / h).rounded(.down))), k1 = Swift.min(nz - 1, Int((mx.z / h).rounded(.down)))
            guard i0 <= i1, j0 <= j1, k0 <= k1 else { return }
            for k in k0...k1 {
                for j in j0...j1 {
                    for ii in i0...i1 {
                        let c = lo + SIMD3(Float(ii) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * h
                        if Self.axisDistance(c, a[i], ab[i], len2[i]) <= reach { body((k * ny + j) * nx + ii) }
                    }
                }
            }
        }
        var count = [Int32](repeating: 0, count: cells + 1)
        for i in 0..<n { each(i) { count[$0 + 1] += 1 } }
        for c in 0..<cells { count[c + 1] += count[c] }
        var fill = count
        var items = [Int32](repeating: 0, count: Int(count[cells]))
        for i in 0..<n {
            each(i) { c in
                items[Int(fill[c])] = Int32(i)
                fill[c] += 1
            }
        }
        self.lo = lo; self.h = h; self.nx = nx; self.ny = ny; self.nz = nz
        self.start = count; self.items = items; self.a = a; self.ab = ab; self.len2 = len2; self.r = r; self.pad = pad
    }

    static func axisDistance(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ ab: SIMD3<Float>, _ l2: Float) -> Float {
        let t = l2 > 0 ? Swift.min(1, Swift.max(0, simd_dot(p - a, ab) / l2)) : 0
        return simd_length(p - (a + t * ab))
    }

    /// The nearest bar to `p` (its index, the gap to its surface, its radius), looking `rings` cells out at most beyond p's own
    /// cell; nil when none is listed there.
    func nearest(_ p: SIMD3<Float>, rings: Int) -> (index: Int, gap: Float, radius: Float)? {
        let g = (p - lo) / h
        let ci = Int(g.x.rounded(.down)), cj = Int(g.y.rounded(.down)), ck = Int(g.z.rounded(.down))
        var best: (index: Int, gap: Float, radius: Float)? = nil
        func scan(_ i: Int, _ j: Int, _ k: Int) {
            guard i >= 0, j >= 0, k >= 0, i < nx, j < ny, k < nz else { return }
            let c = (k * ny + j) * nx + i
            for s in Int(start[c])..<Int(start[c + 1]) {
                let b = Int(items[s])
                let gap = Self.axisDistance(p, a[b], ab[b], len2[b]) - r[b]
                if best.map({ gap < $0.gap }) ?? true { best = (b, gap, r[b]) }
            }
        }
        scan(ci, cj, ck)
        // every bar whose surface is within `pad` of p is listed in p's own cell: further out, look round
        if let b = best, b.gap <= pad { return b }
        guard rings > 0 else { return best }
        for ring in 1...rings {
            for k in (ck - ring)...(ck + ring) {
                for j in (cj - ring)...(cj + ring) {
                    for i in (ci - ring)...(ci + ring)
                    where abs(i - ci) == ring || abs(j - cj) == ring || abs(k - ck) == ring {
                        scan(i, j, k)
                    }
                }
            }
            if let b = best, b.gap <= pad + Float(ring) * h { return b }
        }
        return best
    }
}

/// ★ notes27 F1: a print file's colour at any place — its share of its limit at your load (red at 1).
public struct PrintFileColouring: @unchecked Sendable {
    /// What a mesh vertex is, from the file's triangle order (`base_triangles`): the solid, a strut, or not known (a tap).
    public enum Kind: UInt8, Sendable { case unknown = 0, solid = 1, strut = 2 }

    /// One of core's listed weakest struts as a tube along end → middle → end (an older file with no bars.bin).
    struct Tube { var pts: [SIMD3<Float>]; var r: Float; var share: Float; var lo: SIMD3<Float>; var hi: SIMD3<Float> }

    let tubes: [Tube]
    let bars: BarGrid?
    let parts: PrintFileParts?
    /// The solid's margin per voxel on the field's grid (NaN where not judged).
    let solidMargins: [Float]?
    /// The stress field (MPa) and the limit its share is taken against (the material's yield at his infill).
    let field: StressField?
    let limitMPa: Float
    /// Never above these (core's answer): the solid's and the struts' own smallest margins, else the governing one.
    let solidCap: Float
    let strutCap: Float
    let anyCap: Float

    /// `answer`: core's one answer (its listed weakest struts and margins); `solidMargins`: on `field`'s grid; `limitMPa`: the
    /// stress the field's share is taken against.
    public init(answer: LatticeStrengthAnswer, parts: PrintFileParts?, solidMargins: [Float]?, field: StressField?,
                limitMPa: Double) {
        func cap(_ m: Double?) -> Float { m.map { $0 > 0 ? Float(1 / $0) : .infinity } ?? .infinity }
        anyCap = cap(answer.governing)
        solidCap = cap(answer.solidMargin ?? answer.governing)
        strutCap = cap(answer.strutMargin ?? answer.governing)
        self.parts = parts
        bars = parts.flatMap { BarGrid(bars: $0.bars) }
        tubes = answer.weakest.compactMap { s in
            guard s.margin > 0 else { return nil }
            let f = { (d: SIMD3<Double>) in SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z)) }
            let pts = s.ends.count >= 2 ? [f(s.ends[0]), f(s.at), f(s.ends[1])] : [f(s.at)]
            let r = Float(s.widthMM / 2 + Swift.max(0.3, 0.2 * s.widthMM)) + (s.ends.count >= 2 ? 0 : Float(s.lengthMM / 2))
            let lo = pts.reduce(pts[0]) { simd_min($0, $1) } - SIMD3(repeating: r)
            let hi = pts.reduce(pts[0]) { simd_max($0, $1) } + SIMD3(repeating: r)
            return Tube(pts: pts, r: r, share: Float(1 / s.margin), lo: lo, hi: hi)
        }
        let n = field.map { $0.nx * $0.ny * $0.nz } ?? 0
        self.solidMargins = solidMargins.flatMap { $0.count == n && n > 0 ? $0 : nil }
        self.field = field.flatMap { $0.isEmpty ? nil : $0 }
        self.limitMPa = Float(limitMPa)
    }

    /// Whether bars.bin is here (every strut by its own margin).
    public var hasBars: Bool { bars != nil }

    /// Per shared vertex of a mesh: the solid, a strut, or not known (`PrintFileParts.kinds`).
    public func kinds(indices: [UInt32], vertexCount n: Int) -> [Kind] {
        parts?.kinds(indices: indices, vertexCount: n) ?? [Kind](repeating: .unknown, count: n)
    }

    /// A place's share of its limit at your load (red at 1); nil only with nothing to read (no field, no margins).
    public func share(at p: SIMD3<Float>, _ kind: Kind) -> Float? {
        if kind != .solid, let g = bars {
            // a strut's vertex: its nearest bar, wherever it is; a place not known: a bar whose surface it is on
            if let b = PrintFileParts.bar(g, p, kind) {
                let m = parts?.margin(b) ?? .nan
                if m.isFinite, m > 0 { return 1 / m }
                return solidOrField(p, cap: strutCap)   // a bar core did not judge
            }
        } else if kind != .solid, bars == nil, let t = tubeShare(p) {
            return t   // an older file: the listed weakest struts
        }
        return solidOrField(p, cap: kind == .solid ? solidCap : kind == .strut ? strutCap : anyCap)
    }

    /// The listed weakest struts (an older file): the largest share of those whose tube holds `p`.
    func tubeShare(_ p: SIMD3<Float>) -> Float? {
        var best: Float? = nil
        for t in tubes where all(p .>= t.lo) && all(p .<= t.hi) {
            var d = Float.infinity
            if t.pts.count == 1 { d = simd_length(p - t.pts[0]) }
            for q in 0..<(t.pts.count - 1) {
                d = Swift.min(d, BarGrid.axisDistance(p, t.pts[q], t.pts[q + 1] - t.pts[q], simd_length_squared(t.pts[q + 1] - t.pts[q])))
            }
            if d <= t.r { best = Swift.max(best ?? 0, t.share) }
        }
        return best
    }

    /// The solid's own margin there (its voxel; on a skin, the smallest beside it), else the stress field's share (capped).
    func solidOrField(_ p: SIMD3<Float>, cap: Float) -> Float? {
        guard let g = field else { return nil }
        let c = (p - g.origin) / g.spacing
        let i = Int(c.x.rounded(.down)), j = Int(c.y.rounded(.down)), k = Int(c.z.rounded(.down))
        if let m = solidMargins {
            func at(_ i: Int, _ j: Int, _ k: Int) -> Float? {
                guard i >= 0, j >= 0, k >= 0, i < g.nx, j < g.ny, k < g.nz else { return nil }
                let v = m[(k * g.ny + j) * g.nx + i]
                return v.isFinite && v > 0 ? v : nil
            }
            var mm = at(i, j, k)
            if mm == nil {
                for (a, b, cc) in Self.sides { if let v = at(i + a, j + b, k + cc) { mm = Swift.min(mm ?? v, v) } }
            }
            if let mm { return 1 / mm }
        }
        guard limitMPa > 0 else { return nil }
        // the field: its voxel (clamped into the grid, as StressField reads it); on a skin, the most stressed voxel beside it
        func vm(_ i: Int, _ j: Int, _ k: Int) -> Float {
            let ii = Swift.min(Swift.max(i, 0), g.nx - 1), jj = Swift.min(Swift.max(j, 0), g.ny - 1)
            let kk = Swift.min(Swift.max(k, 0), g.nz - 1)
            let idx = (kk * g.ny + jj) * g.nx + ii
            return idx < g.values.count && g.values[idx].isFinite ? g.values[idx] : 0
        }
        var v = vm(i, j, k)
        if v <= 0 { for (a, b, cc) in Self.sides { v = Swift.max(v, vm(i + a, j + b, k + cc)) } }
        return Swift.min(Swift.max(0, v) / limitMPa, cap)
    }

    static let sides = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
}

// MARK: - ★ notes27 (his 11-24): when the part wears colours
//
// "You can colour the struts without the stress map on when the "Strengthened" row is selected and opened in the "Checks" modal.
// Otherwise, the colours only happen when the stress map view is on. The stress map colours should give the highest stress of every
// point when not animated. When animated the colours should change according to the stress as it moves across the part."
//   * the stress map off and the Strengthened row not open: the plain part;
//   * the Strengthened row open: the struts the strengthening changed, in one clear highlight (gold), its legend in the row;
//   * the stress map on, still: each place at your load; Bend / Break: the colours follow the load (ResultsLoadMotion);
//   * Load flow: only with the stress map, its band carrying each place's stress as it passes (LoadLightFlow.loadFrame).

extension ResultsModel {
    /// The one clear highlight of the struts the strengthening changed: a shaded gold.
    public static let strengthenedHighlight = SIMD3<Float>(1.0, 0.72, 0.18)
    /// The Strengthened row's legend while it lights them.
    public static let strengthenedLegend = "In gold on the part: the struts it changed"

    /// Per bar, whether the strengthening changed it (bars.bin's flags; else the bars past his thickest strut); nil: nothing to
    /// light.
    public var strengthenedBars: [Bool]? {
        guard let parts = printFileParts, let g = reportBlocks?.printFile?.strengthening, g.rounds > 0 else { return nil }
        return parts.changed(limitMM: g.groups.count <= 1 ? g.limitMM : nil)   // one limit only when one strut group
    }

    /// Per flat vertex: gold on the struts the strengthening changed, the plain part elsewhere; nil when none can be lit.
    /// Built once per selection.
    public func strengthenedTints(for mesh: ViewerMesh) -> [SIMD4<Float>]? {
        let key = "\(selectedIndex)|\(mesh.flat.vertexCount)|\(printFileParts?.barCount ?? -1)|\(printFileParts?.flags.count ?? -1)"
        let m = loadMotion
        if let c = m.strengthenedCache, c.key == key { return c.tints }
        let tints = Self.strengthenedTints(mesh: mesh, parts: printFileParts, changed: strengthenedBars)
        m.strengthenedCache = (key, tints)
        return tints
    }

    static func strengthenedTints(mesh: ViewerMesh, parts: PrintFileParts?, changed: [Bool]?) -> [SIMD4<Float>]? {
        guard let parts, let changed, let lit = parts.onChanged(positions: mesh.positions, indices: mesh.indices, changed: changed),
              lit.contains(true) else { return nil }
        let gold = SIMD4<Float>(strengthenedHighlight, 1), n = lit.count
        return mesh.indices.map { Int($0) < n && lit[Int($0)] ? gold : .zero }
    }

    /// The Strengthened check with its legend when its struts can be lit ("… · In gold on the part: the struts it changed").
    public func withStrengthenedLegend(_ c: ResultsCheck) -> ResultsCheck {
        guard c.title.hasPrefix("Strengthened"), strengthenedBars != nil else { return c }
        var out = c
        out.more = (c.more.map { $0 + ". " } ?? "") + Self.strengthenedLegend
        return out
    }

    /// The still stress map per flat vertex, as each place's share of the scale's top: a print file's share of its limit at your
    /// load (its ramp), a solid result's stress over the yield. What Load flow's band carries. Built once per selection.
    public func mapShares(for mesh: ViewerMesh) -> [Float]? {
        let key = "\(selectedIndex)|\(viewScenario ?? "")|\(mesh.flat.vertexCount)|\(latticeAnswer != nil)|\(stressScaleMaxMPa)"
            + "|\(printFileParts?.barCount ?? -1)"
        let m = loadMotion
        if let c = m.mapSharesCache, c.key == key { return c.shares }
        var shares: [Float]? = nil
        if latticeAnswer != nil, let p = motionPrep(), p.ramp.count == mesh.flat.vertexCount {
            shares = p.ramp.map { $0.isFinite ? Swift.max(0, $0) : 0 }
        } else if let f = selectedStressField, stressScaleMaxMPa > 0 {
            let fp = mesh.flat.positions, top = Float(stressScaleMaxMPa)
            shares = (0..<mesh.flat.vertexCount).map { j in
                Swift.max(0, f.value(at: SIMD3(fp[3 * j], fp[3 * j + 1], fp[3 * j + 2]))) / top
            }
        }
        m.mapSharesCache = (key, shares)
        return shares
    }
}
