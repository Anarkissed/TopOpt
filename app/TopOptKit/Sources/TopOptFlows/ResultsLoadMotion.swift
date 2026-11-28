// ResultsLoadMotion.swift — ★ notes25 (his iPad 2026-11-23 on release 16, img 2 + 3): "The exaggeration goes wayyy too high ... 60x
// is way too high for *half* the exaggeration." "The break/bend animations look ridiculous at those extremes ... do what you can to
// make it actually look like it was bending/breaking. Ensure the stress map changes along with the movement. I should be able to
// see through the stress map where the yield is happening ahead of time."
//
// What was there (release 16): Bend drew the solved displacement × a raised-cosine amplitude × the slider (10…300×, default 60×),
// each mesh vertex snapped to its NEAREST grid node — so neighbouring vertices of one surface took a moving node and a node of no
// material (zero by core's contract) and tore apart into spikes at 60×; its colours were the stress × the amplitude, recoloured
// on the CPU every frame. Break pushed from 1× to "the failure multiple" (the material yield ÷ the ONE highest voxel), clamped so a
// part already past it (his: 0.97) never moved, and put its marker on that voxel.
//
// What it is now:
//   * C1: the Exaggeration slider is scaled to the part — its top end is where the largest movement shown reaches 8 % of the
//     part's longest side (never above), its bottom end the true size (1×), and it opens at about 3 %.
//   * C2: the motion runs the LOAD: each frame's shape = the computed displacement × the load × the exaggeration, and its colours =
//     each place's share of its limit at your load × the same load, on ONE fixed scale (red = it gives way / yields at the shown
//     load). The load eases up, holds, eases back and rests, so a loop never jumps. The displacement is sampled smoothly (the
//     material's own grid nodes, interpolated), so a surface bends instead of tearing.
//   * C3: a print file's colours are how close each place is to giving way, so the weakest strut is the first thing to turn red,
//     exactly at the governing margin, where the marker sits. Break runs from your load to that margin and, there, the part gives
//     way at that place (a restrained local fold).
//   * ★ notes27 F1 (his 11-23: "The stress map is meant to be on the *entire* model ... It shouldn't JUST BE on the few struts"):
//     EVERY place is coloured — every strut by its own bar's margin (bars.bin), the solid by its margin per voxel, and anything
//     neither judged (an older file) by the stress field — never plain (PrintFileColours.swift).
// The colours are made on the GPU from one upload per selection (the viewer's load ramp); a frame is two uniforms and, past the
// governing load, a few hundred vertices rewritten in place.

import Foundation
import simd
import Combine

/// ★ notes25: the viewer's load ramp — one value per flat vertex (its share of its limit at your load; NaN = not judged), coloured
/// on the GPU at `load` each frame. Equal by key and load (the values are large and only change with the key).
public struct LoadRamp: Equatable {
    public var key: Int
    public var values: [Float]
    public var load: Float
    public static func == (a: LoadRamp, b: LoadRamp) -> Bool { a.key == b.key && a.load == b.load }
}

/// ★ notes25 (Break gives way): flat vertices whose displacement is rewritten in place (xyz each). Equal by key.
public struct FlexPatch: Equatable {
    public var key: Int
    public var indices: [Int32]
    public var values: [Float]
    public static func == (a: FlexPatch, b: FlexPatch) -> Bool { a.key == b.key }
}

public enum LoadMotionKind: Equatable, Sendable { case bend, breakIt }

/// The pure rules of the moving views (headless: Notes25MotionTests).
public enum LoadMotion {
    /// C1: the slider's top end — the largest movement shown reaches this share of the part's longest side, never more.
    public static let capShare = 0.08
    /// C1: where the slider opens.
    public static let standardShare = 0.03
    /// Break: how far the part gives way at its weakest place, as a share of the largest movement shown at the top (local).
    /// ★ notes28 (his notes on release 18, img 79: "showing an actual breakage of the model"): the whole movement again, as a
    /// crack that opens there (it was half, as a fold).
    public static let giveShare = 1.0
    /// ★ notes28: the far side of the crack moves back this share of the near side's give, so the crack opens both ways.
    public static let crackBackShare = 0.35
    /// Break: the give-way's reach around that place, as a share of the part's longest side.
    public static let giveRadiusShare = 0.06

    public struct Exaggeration: Equatable, Sendable {
        public let low: Double
        public let high: Double
        public let standard: Double
        public func clamp(_ x: Double) -> Double { Swift.min(high, Swift.max(low, x)) }
        public var adjustable: Bool { high > low * 1.01 }
        /// The slider's 0…1 — logarithmic, so the low end can be picked on a wide range.
        public func position(of x: Double) -> Double {
            adjustable ? log(clamp(x) / low) / log(high / low) : 0
        }
        public func value(at p: Double) -> Double {
            adjustable ? low * pow(high / low, Swift.min(1, Swift.max(0, p))) : low
        }
    }

    /// C1: the true size at the bottom (1×); at the top the largest movement shown is `capShare` of the longest side; it opens
    /// at `standardShare`. A part that already moves more than the cap: 1× only.
    public static func exaggeration(longestSideMM L: Double, largestMovementMM m: Double) -> Exaggeration {
        guard L > 0, m > 0, L.isFinite, m.isFinite else { return Exaggeration(low: 1, high: 1, standard: 1) }
        let high = Swift.max(1, capShare * L / m)
        return Exaggeration(low: 1, high: high, standard: Swift.min(high, Swift.max(1, standardShare * L / m)))
    }

    /// "1×", "6.7×", "18×", "120×".
    public static func label(_ x: Double) -> String {
        if x < 9.95 {
            var s = String(format: "%.1f", x)
            if s.hasSuffix(".0") { s.removeLast(2) }
            return s + "\u{00D7}"
        }
        if x < 99.5 { return "\(Int(x.rounded()))\u{00D7}" }
        return "\(Int((x / 10).rounded()) * 10)\u{00D7}"
    }

    /// One loop: the load eases up, holds at the top, eases back and rests (seconds).
    public struct Timeline: Equatable, Sendable {
        public let up: Double, hold: Double, down: Double, rest: Double
        public var cycle: Double { up + hold + down + rest }
    }
    public static let bendTimeline = Timeline(up: 1.6, hold: 0.6, down: 1.3, rest: 0.4)
    /// ★ notes28 (his notes on release 18, img 79): "should *end* at the break, showing an actual breakage of the model. It
    /// shouldn't return back. It should pause on the break then reset." — the load climbs to the break, the part breaks there and
    /// stays broken for the hold, then the loop starts again from the start (no way down: `down` is 0), after a short rest.
    public static let breakTimeline = Timeline(up: 2.6, hold: 2.2, down: 0, rest: 0.6)
    public static func timeline(_ k: LoadMotionKind) -> Timeline { k == .bend ? bendTimeline : breakTimeline }

    /// Zero slope at both ends (no snap where it turns).
    public static func ease(_ x: Double) -> Double { 0.5 - 0.5 * cos(Double.pi * Swift.min(1, Swift.max(0, x))) }

    static func wrap(_ t: Double, _ cycle: Double) -> Double {
        guard cycle > 0 else { return 0 }
        let u = t.truncatingRemainder(dividingBy: cycle)
        return u < 0 ? u + cycle : u
    }

    /// How far up the climb the load is at loop time `t`: 0 = where it starts, 1 = the top.
    public static func share(time t: Double, _ tl: Timeline) -> Double {
        let u = wrap(t, tl.cycle)
        if u < tl.up { return ease(u / tl.up) }
        if u < tl.up + tl.hold { return 1 }
        if u < tl.up + tl.hold + tl.down { return 1 - ease((u - tl.up - tl.hold) / tl.down) }
        return 0
    }

    /// Break: how far it has given way (0…1): nothing on the climb; at the top load it breaks — quickly, over the first quarter
    /// of the hold — and stays broken for the rest of it. ★ notes28: it never springs back; the loop starts over from the start.
    public static func giveWay(time t: Double, _ tl: Timeline) -> Double {
        let u = wrap(t, tl.cycle)
        let top = tl.up, back = tl.up + tl.hold
        if u < top { return 0 }
        if u < back { return ease((u - top) / (breakShare * tl.hold)) }
        if tl.down > 0, u < back + tl.down { return 1 - ease((u - back) / (0.5 * tl.down)) }
        return 0
    }
    /// ★ notes28: the share of the hold the break takes (a break is sudden; the rest of the hold shows it broken).
    public static let breakShare = 0.25

    /// One frame of a moving view.
    public struct Frame: Equatable, Sendable {
        /// The load shown, as a multiple of your load.
        public let load: Double
        /// The GPU displacement scale: the shape shown = the computed displacement (at your load) × this = load × exaggeration.
        public let shapeScale: Float
        /// The colours' multiplier: each place's share of its limit at your load × this = its share at the shown load (red at 1).
        public let colourLoad: Float
        /// Break: how far it has given way, 0…1.
        public let giveWay: Double
        /// The load has reached the top (Break: where it gives way).
        public let atTop: Bool
    }

    /// The shape and the colours share the ONE load (C2: linear in it, and in step).
    public static func frame(start: Double, top: Double, share: Double, giveWay: Double, exaggeration: Double) -> Frame {
        let s = Swift.min(1, Swift.max(0, share))
        let load = start + (top - start) * s
        return Frame(load: load, shapeScale: Float(load * exaggeration), colourLoad: Float(load), giveWay: giveWay,
                     atTop: s >= 1 - 1e-9)
    }

    /// ★ C3 (5): Break runs from your load (1.00×) up to the governing margin; a part that does not hold your load runs from none.
    public static func breakStart(top: Double) -> Double { top > 1 ? 1 : 0 }
}

/// What the moving views need of one selection, built once (the per-vertex sampling), never per frame.
public final class ResultsMotionPrep {
    public enum Colouring: Equatable { case stress, utilisation }
    public let colouring: Colouring
    /// Per flat vertex (xyz, mm, at your load): the smooth displacement the GPU scales.
    public let disp: [Float]
    /// Per flat vertex: its share of its limit at your load (red at 1); NaN = not judged (drawn plain).
    public let ramp: [Float]
    public let rampKey: Int
    /// The largest movement on the drawn part at your load (mm), and the part's longest side (mm).
    public let largestMovementMM: Double
    public let longestSideMM: Double
    /// The vertex that turns red first (the largest share), its rest position and its share at your load.
    public let firstRed: (position: SIMD3<Float>, share: Float)?
    /// Where it gives way first (rest, model mm): the print file's governing place, else `firstRed`'s.
    public let place: SIMD3<Float>?
    /// Break's give-way: the flat vertices around the place, their base displacement and their give-way (mm per unit of the
    /// largest movement shown, xyz).
    let giveIndices: [Int32]
    let giveBase: [Float]
    let giveVec: [Float]
    /// The give-way at the place itself (mm, at full give-way and a top of 1) — for the marker.
    let giveAtPlace: SIMD3<Float>
    let field: DisplacementField?
    let mask: [Bool]?
    let utilisationAt: (SIMD3<Float>) -> Float?

    init(colouring: Colouring, disp: [Float], ramp: [Float], rampKey: Int, largestMovementMM: Double, longestSideMM: Double,
         firstRed: (position: SIMD3<Float>, share: Float)?, place: SIMD3<Float>?, giveIndices: [Int32], giveBase: [Float],
         giveVec: [Float], giveAtPlace: SIMD3<Float>, field: DisplacementField?, mask: [Bool]?,
         utilisationAt: @escaping (SIMD3<Float>) -> Float?) {
        self.colouring = colouring; self.disp = disp; self.ramp = ramp; self.rampKey = rampKey
        self.largestMovementMM = largestMovementMM; self.longestSideMM = longestSideMM; self.firstRed = firstRed
        self.place = place; self.giveIndices = giveIndices; self.giveBase = giveBase; self.giveVec = giveVec
        self.giveAtPlace = giveAtPlace; self.field = field; self.mask = mask; self.utilisationAt = utilisationAt
    }

    /// The smooth displacement at any point (the marker and a tapped spot ride the bent part with it).
    public func displacement(at p: SIMD3<Float>) -> SIMD3<Float> {
        guard let f = field else { return .zero }
        return Self.smoothDisplacement(f, mask: mask, at: p)
    }

    // MARK: building

    /// How the colours are made: a solid result's stress against its (knocked-down) yield, or a print file's margins.
    /// ★ notes27 F1: a print file's every place (`PrintFileColouring`); nil: nothing to colour by.
    public enum ColouringInput {
        case stress(field: StressField, scaleMaxMPa: Double)
        case utilisation(PrintFileColouring?)
    }

    private static var nextKey = 0

    /// Build it for a mesh, its fields and its colouring. `place`: the print file's governing place (nil: the first to turn red).
    public static func build(mesh: ViewerMesh, displacement: DisplacementField?, stress: StressField?,
                             colouring: ColouringInput, place given: SIMD3<Double>?) -> ResultsMotionPrep {
        let pos = mesh.positions, idx = mesh.indices
        let n = pos.count / 3, flatN = (idx.count / 3) * 3
        let mask = displacement.flatMap { d in nodeMask(stress: stress, nx: d.nx, ny: d.ny, nz: d.nz) }
        // per shared vertex: the smooth displacement and the share of its limit
        var e = [SIMD3<Float>](repeating: .zero, count: n)
        var u = [Float](repeating: .nan, count: n)
        let util = utilisation(colouring)
        // ★ notes27 F1: a print file's vertex is the solid's or a strut's by the file's own triangle order
        let printFile: PrintFileColouring? = { if case let .utilisation(pf) = colouring { return pf }; return nil }()
        let kinds = printFile.map { $0.kinds(indices: idx, vertexCount: n) }
        let chunks = Swift.max(1, Swift.min(16, n / 20_000))
        e.withUnsafeMutableBufferPointer { eb in
            u.withUnsafeMutableBufferPointer { ub in
                let ep = eb.baseAddress!, up = ub.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let lo = n * c / chunks, hi = n * (c + 1) / chunks
                    for v in lo..<hi {
                        let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
                        if let d = displacement { ep[v] = smoothDisplacement(d, mask: mask, at: p) }
                        if let pf = printFile, let k = kinds {
                            up[v] = pf.share(at: p, k[v]) ?? .nan
                        } else {
                            up[v] = util(p) ?? .nan
                        }
                    }
                }
            }
        }
        var largest: Float = 0
        var best: (Int, Float)? = nil
        for v in 0..<n {
            largest = Swift.max(largest, simd_length(e[v]))
            if u[v].isFinite, best.map({ u[v] > $0.1 }) ?? true { best = (v, u[v]) }
        }
        let b = mesh.bounds
        let longest = Double(Swift.max(b.max.x - b.min.x, Swift.max(b.max.y - b.min.y, b.max.z - b.min.z)))
        let firstRed: (position: SIMD3<Float>, share: Float)? = best.map {
            (position: SIMD3<Float>(pos[3 * $0.0], pos[3 * $0.0 + 1], pos[3 * $0.0 + 2]), share: $0.1)
        }
        let place = given.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) } ?? firstRed?.position
        // per flat vertex
        var disp = [Float](repeating: 0, count: flatN * 3)
        var ramp = [Float](repeating: .nan, count: flatN)
        for j in 0..<flatN {
            let v = Int(idx[j])
            guard v < n else { continue }
            disp[3 * j] = e[v].x; disp[3 * j + 1] = e[v].y; disp[3 * j + 2] = e[v].z
            ramp[j] = u[v]
        }
        // the give-way around the place: ★ notes28 (img 79, "an actual breakage") a crack through the place, across the way it
        // moves — the near side pulled away along that way, the far side a little back, fading out around the place — so the
        // part visibly splits there (it was one smooth bump, a fold)
        var giveIndices: [Int32] = [], giveBase: [Float] = [], giveVec: [Float] = []
        var giveAtPlace = SIMD3<Float>.zero
        if let at = place, longest > 0, largest > 0 {
            let r = Float(LoadMotion.giveRadiusShare * longest)
            var w = [Float](repeating: 0, count: n)
            var dir = SIMD3<Float>.zero
            for v in 0..<n {
                let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
                let q = simd_length(p - at) / r
                guard q < 1 else { continue }
                w[v] = (1 - q * q) * (1 - q * q)
                dir += w[v] * e[v]
            }
            if simd_length(dir) < 1e-9, let far = e.max(by: { simd_length($0) < simd_length($1) }) { dir = far }
            if simd_length(dir) > 1e-12 {
                let way = simd_normalize(dir)
                let k = way * Float(LoadMotion.giveShare) * largest
                giveAtPlace = k
                for j in 0..<flatN {
                    let v = Int(idx[j])
                    guard v < n, w[v] > 0 else { continue }
                    giveIndices.append(Int32(j))
                    giveBase += [e[v].x, e[v].y, e[v].z]
                    let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
                    let side: Float = simd_dot(p - at, way) >= 0 ? 1 : -Float(LoadMotion.crackBackShare)
                    let g = w[v] * side * k
                    giveVec += [g.x, g.y, g.z]
                }
            }
        }
        nextKey += 1
        let kind: Colouring
        if case .stress = colouring { kind = .stress } else { kind = .utilisation }
        return ResultsMotionPrep(colouring: kind, disp: disp, ramp: ramp, rampKey: nextKey, largestMovementMM: Double(largest),
                                 longestSideMM: longest, firstRed: firstRed, place: place, giveIndices: giveIndices,
                                 giveBase: giveBase, giveVec: giveVec, giveAtPlace: giveAtPlace, field: displacement, mask: mask,
                                 utilisationAt: util)
    }

    /// The nodes that touch material (a voxel with stress): core zeroes every other node's displacement, so they are left out
    /// of the interpolation — a surface next to empty space keeps its own motion instead of being pinned to a zero.
    static func nodeMask(stress: StressField?, nx: Int, ny: Int, nz: Int) -> [Bool]? {
        guard let s = stress, !s.isEmpty, s.nx == nx, s.ny == ny, s.nz == nz, s.values.count >= nx * ny * nz else { return nil }
        var m = [Bool](repeating: false, count: (nx + 1) * (ny + 1) * (nz + 1))
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx where s.values[(k * ny + j) * nx + i] > 0 {
                    for c in 0...1 { for b in 0...1 { for a in 0...1 {
                        m[((k + c) * (ny + 1) + (j + b)) * (nx + 1) + (i + a)] = true
                    } } }
                }
            }
        }
        return m
    }

    /// Trilinear over the cell's eight nodes that touch material (all eight with no mask); none: the nearest node, as before.
    static func smoothDisplacement(_ f: DisplacementField, mask: [Bool]?, at p: SIMD3<Float>) -> SIMD3<Float> {
        guard !f.isEmpty else { return .zero }
        let g = (p - f.origin) / f.spacing
        let i = Swift.min(Swift.max(Int(g.x.rounded(.down)), 0), f.nx - 1)
        let j = Swift.min(Swift.max(Int(g.y.rounded(.down)), 0), f.ny - 1)
        let k = Swift.min(Swift.max(Int(g.z.rounded(.down)), 0), f.nz - 1)
        let t = SIMD3<Float>(Swift.min(1, Swift.max(0, g.x - Float(i))), Swift.min(1, Swift.max(0, g.y - Float(j))),
                             Swift.min(1, Swift.max(0, g.z - Float(k))))
        var acc = SIMD3<Float>.zero
        var wsum: Float = 0
        for c in 0...1 {
            for b in 0...1 {
                for a in 0...1 {
                    let node = ((k + c) * (f.ny + 1) + (j + b)) * (f.nx + 1) + (i + a)
                    if let mask, node < mask.count, !mask[node] { continue }
                    let w = (a == 1 ? t.x : 1 - t.x) * (b == 1 ? t.y : 1 - t.y) * (c == 1 ? t.z : 1 - t.z)
                    acc += w * f.node(i + a, j + b, k + c)
                    wsum += w
                }
            }
        }
        if wsum > 1e-6 { return acc / wsum }
        return f.displacement(at: p)
    }

    /// Each point's share of its limit at your load (red at 1), or nil where nothing judged it (a tap on the part reads it).
    static func utilisation(_ c: ColouringInput) -> (SIMD3<Float>) -> Float? {
        switch c {
        case let .stress(field, scale):
            let s = Float(scale)
            return { p in s > 0 ? field.value(at: p) / s : nil }
        case let .utilisation(pf):
            // ★ notes27 F1: a print file's every place (a tapped point is the solid's or a strut's by where it sits)
            guard let pf else { return { _ in nil } }
            return { p in pf.share(at: p, .unknown) }
        }
    }
}

/// ★ notes25: Bend and Break's clock and his exaggeration pick, and the selection's built data (never on ResultsScreen: its size is
/// pinned by WorkspaceBodySizeTests).
@MainActor
public final class ResultsLoadMotion: ObservableObject {
    var relay: AnyCancellable?
    /// Seconds into the loop.
    @Published public private(set) var clock: Double = 0
    /// His exaggeration for one selection (another selection opens at about 3 % again).
    public struct Pick: Equatable { public let selection: String; public let value: Double }
    @Published public private(set) var exaggerationPick: Pick?
    var prepCache: (key: String, prep: ResultsMotionPrep)?
    var frameCache: (key: String, state: ResultsModel.MotionState)?
    /// ★ notes27: the Strengthened row's highlight and the map's shares Load flow carries, built once per selection.
    var strengthenedCache: (key: String, tints: [SIMD4<Float>]?)?
    var mapSharesCache: (key: String, shares: [Float]?)?

    public init() {}

    /// The fields or the selection changed: build again when next asked.
    public func invalidate() { prepCache = nil; frameCache = nil; strengthenedCache = nil; mapSharesCache = nil }
    /// A motion starts: from the top of its loop.
    public func restart() { clock = 0 }
    public func advance(_ dt: Double, _ kind: LoadMotionKind) {
        clock = LoadMotion.wrap(clock + dt, LoadMotion.timeline(kind).cycle)
    }
    /// The slider's 0…1 is one loop.
    public func position(_ kind: LoadMotionKind) -> Double {
        let c = LoadMotion.timeline(kind).cycle
        return LoadMotion.wrap(clock, c) / c
    }
    public func setPosition(_ p: Double, _ kind: LoadMotionKind) {
        let c = LoadMotion.timeline(kind).cycle
        clock = Swift.min(0.999_999, Swift.max(0, p)) * c
    }
    public func pickExaggeration(_ x: Double, selection: String) { exaggerationPick = Pick(selection: selection, value: x) }
}

extension ResultsModel {
    /// One moving view's state at this frame.
    public struct MotionState {
        public let kind: LoadMotionKind
        public let prep: ResultsMotionPrep
        /// The load it runs from and to (× your load).
        public let start: Double
        public let top: Double
        public let range: LoadMotion.Exaggeration
        public let exaggeration: Double
        public let frame: LoadMotion.Frame
        /// Where it gives way first, at rest and as drawn this frame (model mm).
        public let place: SIMD3<Float>?
        public let placeShown: SIMD3<Float>?
        public let ramp: LoadRamp
        public let patch: FlexPatch?
    }

    /// Which selection his exaggeration pick belongs to.
    public var motionSelection: String { "\(selectedIndex)|\(viewScenario ?? "")" }

    /// Break can show: a displacement to move and a load it gives way at (cheap — nothing is built for it).
    /// ★ notes30: never on a load on bare vines (the check judged no load it gives way at).
    public var canBreak: Bool {
        hasFlex && (latticeAnswer.map { $0.governing != nil && $0.bareVines == nil } ?? (failurePrediction != nil))
    }

    /// ★ C3: Break's top — a print file's governing margin; a solid result's: the load at which its colours first reach the top
    /// (the material's knocked-down yield) — nil where the result cannot say (no load, no material limit).
    public var breakTop: Double? {
        if let a = latticeAnswer { return a.governing }
        guard failurePrediction != nil, let p = motionPrep(), let r = p.firstRed, r.share > 0 else { return nil }
        return 1 / Double(r.share)
    }

    /// The selection's built data (cached until the fields, the scenario or the selection change).
    public func motionPrep() -> ResultsMotionPrep? {
        guard let mesh = selectedMesh, let disp = selectedDisplacementField else { return nil }
        let field = selectedStressField
        let key = "\(selectedIndex)|\(viewScenario ?? "")|\(mesh.flat.vertexCount)|\(latticeAnswer != nil)|\(stressScaleMaxMPa)"
            + "|\(printFileParts?.barCount ?? -1)"
        let m = loadMotion
        if let c = m.prepCache, c.key == key { return c.prep }
        let colouring: ResultsMotionPrep.ColouringInput
        if let a = latticeAnswer {
            // ★ notes27 F1: every strut (bars.bin), the solid (its margin per voxel), the rest from the stress field — never plain
            let count = field.map { $0.nx * $0.ny * $0.nz } ?? 0
            colouring = .utilisation(PrintFileColouring(answer: a, parts: printFileParts, solidMargins: solidMargins?.grid(count: count),
                                                        field: field, limitMPa: stressScaleMaxMPa))
        } else if let f = field, stressScaleMaxMPa > 0 {
            colouring = .stress(field: f, scaleMaxMPa: stressScaleMaxMPa)
        } else {
            colouring = .utilisation(nil)
        }
        let prep = ResultsMotionPrep.build(mesh: mesh, displacement: disp, stress: field, colouring: colouring,
                                           place: latticeAnswer?.place)
        m.prepCache = (key, prep)
        m.frameCache = nil
        return prep
    }

    /// The moving view's frame now (cached until the clock, his exaggeration or the selection move).
    public func motionState(_ kind: LoadMotionKind, reduceMotion: Bool) -> MotionState? {
        guard let prep = motionPrep() else { return nil }
        let m = loadMotion
        let top: Double
        switch kind {
        case .bend: top = 1
        case .breakIt:
            guard let t = breakTop, t > 0 else { return nil }
            top = t
        }
        let start = kind == .bend ? 0 : LoadMotion.breakStart(top: top)
        let pick = m.exaggerationPick?.selection == motionSelection ? m.exaggerationPick?.value : nil
        let key = "\(prep.rampKey)|\(kind)|\(reduceMotion)|\(m.clock)|\(pick ?? -1)|\(top)"
        if let c = m.frameCache, c.key == key { return c.state }
        // C1: the largest movement this view shows at its top (Break: with its give-way)
        let shown = prep.largestMovementMM * top * (kind == .breakIt ? 1 + LoadMotion.giveShare : 1)
        let range = LoadMotion.exaggeration(longestSideMM: prep.longestSideMM, largestMovementMM: shown)
        let ex = range.clamp(pick ?? range.standard)
        let tl = LoadMotion.timeline(kind)
        let share = reduceMotion ? 1 : LoadMotion.share(time: m.clock, tl)
        let give = kind == .breakIt && !reduceMotion ? LoadMotion.giveWay(time: m.clock, tl) : 0
        let frame = LoadMotion.frame(start: start, top: top, share: share, giveWay: give, exaggeration: ex)
        // Break gives way: shown = ex·(load·E + give·top·K) ⇒ the patched displacement = E + (give·top/load)·K
        var patch: FlexPatch? = nil
        var placeShown = prep.place.map { $0 + prep.displacement(at: $0) * frame.shapeScale }
        if give > 0, frame.load > 1e-6, !prep.giveIndices.isEmpty {
            let f = Float(give * top / frame.load)
            var values = prep.giveBase
            for i in 0..<values.count { values[i] += f * prep.giveVec[i] }
            patch = FlexPatch(key: prep.rampKey * 10_000 + Int(give * 1000) + 1, indices: prep.giveIndices, values: values)
            placeShown = placeShown.map { $0 + prep.giveAtPlace * Float(give * top) * Float(ex) }
        }
        let state = MotionState(kind: kind, prep: prep, start: start, top: top, range: range, exaggeration: ex, frame: frame,
                                place: prep.place, placeShown: placeShown,
                                ramp: LoadRamp(key: prep.rampKey, values: prep.ramp, load: frame.colourLoad), patch: patch)
        m.frameCache = (key, state)
        return state
    }

    /// The colours for a still view (no motion) of a print file: the same ramp at your load.
    public func stillRamp() -> LoadRamp? {
        guard latticeAnswer != nil, let p = motionPrep() else { return nil }
        return LoadRamp(key: p.rampKey, values: p.ramp, load: 1)
    }

    // MARK: the words

    /// A load in whole units ("55 kg"), or nil with no load.
    func loadWords(_ multiple: Double) -> String? {
        shownLoadKg > 0 ? StrengthWords.load(multiple * shownLoadKg, loadUnit) : nil
    }

    /// Break's readout: "48 kg · 1.17× load", then at the top "55 kg · 1.34× · GIVES WAY".
    public func breakReadout(_ s: MotionState) -> String {
        let x = StrengthWords.x(s.frame.load)
        let kg = loadWords(s.frame.load).map { $0 + " \u{00B7} " } ?? ""
        return s.frame.atTop ? kg + x + " \u{00B7} GIVES WAY" : kg + x + " load"
    }

    /// The marker's three lines: "GIVES WAY HERE" (at the top) or "GIVES WAY AT", the load, "1.34× your load".
    public func breakMarkerLines(_ s: MotionState) -> (title: String, load: String?, multiple: String) {
        (s.frame.atTop ? "GIVES WAY HERE" : "GIVES WAY AT", loadWords(s.top), StrengthWords.x(s.top) + " your load")
    }

    /// Bend's readout: the exaggeration, or the true size.
    public func bendReadout(_ s: MotionState) -> String {
        s.exaggeration <= 1.0001 ? "True size" : LoadMotion.label(s.exaggeration) + " exaggerated \u{00B7} not to scale"
    }

    /// The colour key's note while a view moves.
    public func motionNote(_ s: MotionState) -> String {
        let ex = s.exaggeration <= 1.0001 ? "shown true size" : "bend shown " + LoadMotion.label(s.exaggeration) + " exaggerated"
        switch s.kind {
        case .bend: return "At \(Int((s.frame.load * 100).rounded()))% of your load \u{00B7} " + ex
        case .breakIt: return "At " + StrengthWords.x(s.frame.load) + " your load \u{00B7} " + ex
        }
    }

    /// The share of its limit at a spot, at the shown load (a tap on the part), or nil where nothing judged it.
    public func shareOfLimit(at p: SIMD3<Float>, load: Double) -> Double? {
        guard let prep = motionPrep(), let u = prep.utilisationAt(p), u.isFinite else { return nil }
        return Double(u) * load
    }
}

extension MetalMeshView {
    /// ★ notes25: Bend / Break's colours made on the GPU (the load ramp) and the give-way's rewritten vertices.
    public func loadMotion(ramp: LoadRamp?, patch: FlexPatch?) -> MetalMeshView {
#if canImport(MetalKit)
        var copy = self
        copy.inputs.loadRamp = ramp
        copy.inputs.flexPatch = patch
        return copy
#else
        self
#endif
    }
}

