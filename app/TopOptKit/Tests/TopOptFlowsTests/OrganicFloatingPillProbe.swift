import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ WHAT ARE THE LITTLE PILLS? (his walk, 2026-09-09: "I'm seeing these small
/// pill-like branches that don't make any sense. What is their purpose? They seem
/// completely useless, right?")
///
/// Not an opinion about a picture. For a GROWN organic set, straight out of core, this
/// reports:
///
///   • the length and radius distribution of every emitted span
///   • for each span, the gap between it and its NEAREST neighbouring span, surface to
///     surface — a span whose gap is positive touches nothing and draws as a pill
///     floating in the air
///   • the same two numbers after the preview's depth stagger has deformed the set
///
/// If the floaters are already there before the stagger, they are core's. If the
/// stagger creates them, they are mine.
final class OrganicFloatingPillProbe: XCTestCase {

    private func bendingTensor(n: Int) -> [Double] {
        var t = [Double](repeating: 0, count: 6 * n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let e = (k * n + j) * n + i
            let x = Double(i) / Double(n - 1)
            let y = 2 * Double(j) / Double(n - 1) - 1
            let z = 2 * Double(k) / Double(n - 1) - 1
            let m = 1 - x
            t[6 * e] = 12 * m * y
            t[6 * e + 1] = 0.6 * m
            t[6 * e + 2] = 0.3 * m
            t[6 * e + 3] = 4 * (1 - y * y)
            t[6 * e + 4] = 0.8 * z * m
            t[6 * e + 5] = 2 * (1 - z * z)
        } } }
        return t
    }

    private func pct(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let i = Swift.min(s.count - 1, Swift.max(0, Int((p * Double(s.count - 1)).rounded())))
        return s[i]
    }

    /// Shortest distance between two segments.
    private func segDist(_ p1: SIMD3<Double>, _ q1: SIMD3<Double>,
                         _ p2: SIMD3<Double>, _ q2: SIMD3<Double>) -> Double {
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
        var s = 0.0, t = 0.0
        if a <= 1e-12 && e <= 1e-12 { return simd_length(r) }
        if a <= 1e-12 { s = 0; t = Swift.min(Swift.max(f / e, 0), 1) }
        else {
            let c = simd_dot(d1, r)
            if e <= 1e-12 { t = 0; s = Swift.min(Swift.max(-c / a, 0), 1) }
            else {
                let b = simd_dot(d1, d2), den = a * e - b * b
                s = den != 0 ? Swift.min(Swift.max((b * f - c * e) / den, 0), 1) : 0
                t = (b * s + f) / e
                if t < 0 { t = 0; s = Swift.min(Swift.max(-c / a, 0), 1) }
                else if t > 1 { t = 1; s = Swift.min(Swift.max((b - c) / a, 0), 1) }
            }
        }
        return simd_length((p1 + d1 * s) - (p2 + d2 * t))
    }

    /// The gap, surface to surface, from each span to its nearest neighbour.
    private func gaps(_ spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)]) -> [Double] {
        let cell = 3.0
        var bins: [SIMD3<Int32>: [Int]] = [:]
        func key(_ p: SIMD3<Double>) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)),
                  Int32((p.z / cell).rounded(.down)))
        }
        for (i, s) in spans.enumerated() {
            var seen = Set<SIMD3<Int32>>()
            for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                let k = key(s.a + (s.b - s.a) * t)
                if seen.insert(k).inserted { bins[k, default: []].append(i) }
            }
        }
        var out = [Double](repeating: .infinity, count: spans.count)
        for (i, s) in spans.enumerated() {
            var cands = Set<Int>()
            var seen = Set<SIMD3<Int32>>()
            for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                let k0 = key(s.a + (s.b - s.a) * t)
                guard seen.insert(k0).inserted else { continue }
                for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    if let l = bins[k0 &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] { cands.formUnion(l) }
                } } }
            }
            var best = Double.infinity
            for j in cands where j != i {
                let o = spans[j]
                let d = segDist(s.a, s.b, o.a, o.b) - (s.r + o.r)
                if d < best { best = d }
                if best < -1e-9 { break }
            }
            out[i] = best
        }
        return out
    }

    private func report(_ tag: String, _ spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)]) {
        let len = spans.map { simd_length($0.b - $0.a) }
        let rad = spans.map { $0.r }
        let g = gaps(spans)
        let floating = g.enumerated().filter { $0.element > 0 }
        print("── \(tag): \(spans.count) spans")
        print(String(format: "   length mm  min %.3f  p05 %.3f  p50 %.3f  p95 %.3f  max %.3f",
                     len.min() ?? 0, pct(len, 0.05), pct(len, 0.5), pct(len, 0.95), len.max() ?? 0))
        print(String(format: "   radius mm  min %.3f  p50 %.3f  p95 %.3f  max %.3f",
                     rad.min() ?? 0, pct(rad, 0.5), pct(rad, 0.95), rad.max() ?? 0))
        print(String(format: "   TOUCHING NOTHING: %d of %d (%.1f %%)",
                     floating.count, spans.count,
                     100 * Double(floating.count) / Double(Swift.max(1, spans.count))))
        if !floating.isEmpty {
            let fl = floating.map { simd_length(spans[$0.offset].b - spans[$0.offset].a) }
            let fr = floating.map { spans[$0.offset].r }
            let fg = floating.map { $0.element }
            print(String(format: "   floaters: length p50 %.3f mm, radius p50 %.3f mm, gap p50 %.3f mm, gap max %.3f mm",
                         pct(fl, 0.5), pct(fr, 0.5), pct(fg, 0.5), fg.max() ?? 0))
        }
        // The short-and-fat family he is pointing at: under half a cell long, drawn at
        // more than the median radius.
        let rMed = pct(rad, 0.5)
        var stubby = 0
        for (i, l) in len.enumerated() where l < 1.5 && rad[i] > rMed { stubby += 1 }
        print(String(format: "   short (<1.5 mm) AND fatter than median: %d (%.1f %%)",
                     stubby, 100 * Double(stubby) / Double(Swift.max(1, spans.count))))
    }


    /// Chains: spans joined where they share an endpoint (core writes polylines, so a
    /// curve is a run of segments end to end). A component that is one or two segments
    /// long and touches no chain is a pill lying on its own.
    private func chains(_ spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)]) -> [[Int]] {
        func key(_ p: SIMD3<Double>) -> SIMD3<Int64> {
            SIMD3(Int64((p.x * 1e4).rounded()), Int64((p.y * 1e4).rounded()), Int64((p.z * 1e4).rounded()))
        }
        var at: [SIMD3<Int64>: [Int]] = [:]
        for (i, s) in spans.enumerated() {
            at[key(s.a), default: []].append(i); at[key(s.b), default: []].append(i)
        }
        var parent = Array(0..<spans.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
        for (_, l) in at { for j in l.dropFirst() { union(l[0], j) } }
        var groups: [Int: [Int]] = [:]
        for i in 0..<spans.count { groups[find(i), default: []].append(i) }
        return Array(groups.values)
    }

    private func chainReport(_ tag: String, _ spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)]) {
        let cs = chains(spans)
        let lens = cs.map { c in c.reduce(0.0) { $0 + simd_length(spans[$1].b - spans[$1].a) } }
        let singles = cs.enumerated().filter { $0.element.count <= 2 }
        print("── \(tag): \(cs.count) chains from \(spans.count) spans")
        print(String(format: "   chain length mm  p05 %.3f  p50 %.3f  p95 %.3f  max %.3f",
                     pct(lens, 0.05), pct(lens, 0.5), pct(lens, 0.95), lens.max() ?? 0))
        print(String(format: "   chains of 1-2 segments: %d (%.1f %%)  ·  chains under 1 mm long: %d (%.1f %%)",
                     singles.count, 100 * Double(singles.count) / Double(Swift.max(1, cs.count)),
                     lens.filter { $0 < 1 }.count,
                     100 * Double(lens.filter { $0 < 1 }.count) / Double(Swift.max(1, cs.count))))
        // A short chain that also touches no OTHER chain is a pill in mid-air.
        var owner = [Int](repeating: -1, count: spans.count)
        for (ci, c) in cs.enumerated() { for i in c { owner[i] = ci } }
        let g = gapsToOtherChains(spans, owner: owner)
        var lonely = 0
        for (ci, c) in cs.enumerated() where lens[ci] < 2.0 {
            let best = c.map { g[$0] }.min() ?? .infinity
            if best > 0 { lonely += 1 }
        }
        print("   short chains touching NO other chain: \(lonely)")
    }

    /// Nearest gap from each span to a span in a DIFFERENT chain.
    private func gapsToOtherChains(_ spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)],
                                   owner: [Int]) -> [Double] {
        let cell = 3.0
        var bins: [SIMD3<Int32>: [Int]] = [:]
        func key(_ p: SIMD3<Double>) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)),
                  Int32((p.z / cell).rounded(.down)))
        }
        for (i, s) in spans.enumerated() {
            var seen = Set<SIMD3<Int32>>()
            for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                let k = key(s.a + (s.b - s.a) * t)
                if seen.insert(k).inserted { bins[k, default: []].append(i) }
            }
        }
        var out = [Double](repeating: .infinity, count: spans.count)
        for (i, s) in spans.enumerated() {
            var cands = Set<Int>(); var seen = Set<SIMD3<Int32>>()
            for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                let k0 = key(s.a + (s.b - s.a) * t)
                guard seen.insert(k0).inserted else { continue }
                for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    if let l = bins[k0 &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] { cands.formUnion(l) }
                } } }
            }
            var best = Double.infinity
            for j in cands where owner[j] != owner[i] {
                let o = spans[j]
                let d = segDist(s.a, s.b, o.a, o.b) - (s.r + o.r)
                if d < best { best = d }
            }
            out[i] = best
        }
        return out
    }

    /// Where the little pieces come from: grown, with the ties and the emission's
    /// repairs switched on and off one at a time.
    func testWhereTheFloatingPillsComeFrom() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 20.0
        let n = 32
        let sp = edge / Double(n)
        let cell = 3.0
        let t = bendingTensor(n: n)
        let cand = [Bool](repeating: true, count: n * n * n)
        let sepa = [Double](repeating: cell, count: n * n * n)

        func run(_ tag: String, grow: Bool, ties: Bool, repairs: Bool) {
            guard let tr = TopOptKit.organicTrace(
                nx: n, ny: n, nz: n, spacingMM: sp, origin: .zero,
                candidate: cand, stressTensor: t, separationMM: sepa,
                minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
                fieldDims: (8, 8, 8), fieldOrigin: .zero, fieldSpacingMM: edge / 8,
                bandMM: 2.0, rhoMin: 0.05, rhoMax: 0.9,
                grow: grow, layerHeightMM: 0.2,
                anchorAtBoundary: false, transferTies: ties, tieSwirl: 1.0,
                showRepairs: repairs)
            else { XCTFail("no trace: \(tag)"); return }
            print("\n════ \(tag) · spans \(tr.spans.count) · curves \(tr.curveCount) · connectors "
                  + "\(tr.connectorCount) · filleted \(tr.census.filletedSpans)")
            pieces(tr.spans)
        }

        run("GROWN · ties ON · repairs ON", grow: true, ties: true, repairs: true)
        run("GROWN · ties OFF · repairs ON", grow: true, ties: false, repairs: true)
        run("GROWN · ties ON · repairs OFF", grow: true, ties: true, repairs: false)
        run("TRACED · repairs ON", grow: false, ties: true, repairs: true)
    }

    /// A PIECE is a set of spans welded by overlap — what a printer would lay down as
    /// one lump of plastic. Reports how many pieces there are, how long they are, and
    /// how much of the total length sits in the small ones.
    private func pieces(_ spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)]) {
        let cell = 3.0
        var bins: [SIMD3<Int32>: [Int]] = [:]
        func key(_ p: SIMD3<Double>) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)),
                  Int32((p.z / cell).rounded(.down)))
        }
        for (i, s) in spans.enumerated() {
            var seen = Set<SIMD3<Int32>>()
            for t in stride(from: 0.0, through: 1.0, by: 0.2) {
                let k = key(s.a + (s.b - s.a) * t)
                if seen.insert(k).inserted { bins[k, default: []].append(i) }
            }
        }
        var parent = Array(0..<spans.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
        for (i, s) in spans.enumerated() {
            var cands = Set<Int>(); var seen = Set<SIMD3<Int32>>()
            for t in stride(from: 0.0, through: 1.0, by: 0.2) {
                let k0 = key(s.a + (s.b - s.a) * t)
                guard seen.insert(k0).inserted else { continue }
                for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    if let l = bins[k0 &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] { cands.formUnion(l) }
                } } }
            }
            for j in cands where j > i {
                let o = spans[j]
                if segDist(s.a, s.b, o.a, o.b) <= s.r + o.r { union(i, j) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in 0..<spans.count { groups[find(i), default: []].append(i) }
        let ps = Array(groups.values)
        let lens = ps.map { c in c.reduce(0.0) { $0 + simd_length(spans[$1].b - spans[$1].a) } }
        let total = lens.reduce(0, +)
        let smallCut = 3.0                        // one cell
        let small = lens.filter { $0 < smallCut }
        print("   \(ps.count) separate PIECES; total length \(String(format: "%.0f", total)) mm")
        print(String(format: "   piece length mm  p05 %.2f  p50 %.2f  p95 %.2f  max %.0f",
                     pct(lens, 0.05), pct(lens, 0.5), pct(lens, 0.95), lens.max() ?? 0))
        print(String(format: "   pieces under one cell (3 mm): %d of %d (%.1f %%), holding %.2f %% of the length",
                     small.count, ps.count, 100 * Double(small.count) / Double(Swift.max(1, ps.count)),
                     100 * small.reduce(0, +) / Swift.max(1e-9, total)))
        // the pill family: a piece of ONE span, drawn fatter than the median strut
        let rMed = pct(spans.map { $0.r }, 0.5)
        var pills = 0, pillLen = 0.0
        for c in ps where c.count == 1 {
            let s = spans[c[0]]
            if s.r > rMed { pills += 1; pillLen += simd_length(s.b - s.a) }
        }
        print(String(format: "   single-span pieces fatter than the median strut: %d (%.3f %% of length)",
                     pills, 100 * pillLen / Swift.max(1e-9, total)))
    }

    /// ★★★ HIS SWITCHES, AS SAVED (project.json, 2026-09-09 17:57): grown, ties on,
    /// depth variation OFF, and `organicShowRepairs = false`. What does hiding the
    /// repairs cost the picture, and what becomes of the loose pieces it shows?
    func testWhatHidingTheRepairsCosts() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 20.0, n = 32, sp = edge / Double(n), cell = 3.0
        let t = bendingTensor(n: n)
        let cand = [Bool](repeating: true, count: n * n * n)
        let sepa = [Double](repeating: cell, count: n * n * n)
        func trace(_ repairs: Bool) -> TopOptKit.OrganicTrace? {
            TopOptKit.organicTrace(
                nx: n, ny: n, nz: n, spacingMM: sp, origin: .zero,
                candidate: cand, stressTensor: t, separationMM: sepa,
                minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
                fieldDims: (8, 8, 8), fieldOrigin: .zero, fieldSpacingMM: edge / 8,
                bandMM: 2.0, rhoMin: 0.05, rhoMax: 0.9,
                grow: true, layerHeightMM: 0.2, anchorAtBoundary: false,
                transferTies: true, tieSwirl: 1.0, showRepairs: repairs)
        }
        guard let hidden = trace(false), let shown = trace(true) else { XCTFail("no trace"); return }
        print("\n════ THE EMISSION'S LENGTH CENSUS (grown, ties on)")
        print(String(format: "   input %.0f mm", shown.census.inputLengthMM))
        for st in shown.census.stages { print(String(format: "   %-22@ %.0f mm", st.name as NSString, st.lengthMM)) }
        print("   written components \(shown.census.writtenComponents) · filleted spans \(shown.census.filletedSpans)")

        // Does each hidden-picture span survive into the file?
        func key(_ p: SIMD3<Double>) -> SIMD3<Int64> {
            SIMD3(Int64((p.x * 20).rounded()), Int64((p.y * 20).rounded()), Int64((p.z * 20).rounded()))
        }
        var bins: [SIMD3<Int64>: [Int]] = [:]
        for (i, s) in shown.spans.enumerated() { bins[key(0.5 * (s.a + s.b)), default: []].append(i) }
        var survived = 0
        for s in hidden.spans {
            let m = 0.5 * (s.a + s.b), k = key(m)
            var found = false
            outer: for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                let kk: SIMD3<Int64> = k &+ SIMD3<Int64>(Int64(dx), Int64(dy), Int64(dz))
                for j in bins[kk] ?? [] {
                    let o = shown.spans[j]
                    let om: SIMD3<Double> = (o.a + o.b) * 0.5
                    let dd: Double = simd_length(om - m)
                    if dd < 0.05 { found = true; break outer }
                }
            } } }
            if found { survived += 1 }
        }
        print(String(format: "\n   of the %d spans the hidden picture draws, %d (%.1f %%) are still in the file after the repairs",
                     hidden.spans.count, survived,
                     100 * Double(survived) / Double(Swift.max(1, hidden.spans.count))))
    }

    /// ★ WHAT RADIUS COMES BACK WHEN A WIDTH IS STATED? (2026-09-09). The sample now
    /// hands core the width he typed; this says what core does with it.
    func testTheRadiusCoreReturnsForAStatedWidth() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 20.0, n = 32, sp = edge / Double(n), cell = 3.0
        let t = bendingTensor(n: n)
        let cand = [Bool](repeating: true, count: n * n * n)
        let sepa = [Double](repeating: cell, count: n * n * n)
        for width in [0.0, 0.6, 0.9, 1.8] {
            guard let tr = TopOptKit.organicTrace(
                nx: n, ny: n, nz: n, spacingMM: sp, origin: .zero,
                candidate: cand, stressTensor: t, separationMM: sepa,
                minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
                fieldDims: (8, 8, 8), fieldOrigin: .zero, fieldSpacingMM: edge / 8,
                bandMM: 2.0, rhoMin: 0.05, rhoMax: 0.9,
                strutDiameterMM: width, grow: false, layerHeightMM: 0.2,
                anchorAtBoundary: false, showRepairs: false) else { XCTFail("no trace"); return }
            let rad = tr.spans.map { $0.r }.sorted()
            let len = tr.spans.reduce(0.0) { $0 + simd_length($1.b - $1.a) }
            print(String(format: "── stated width %.2f mm → radius p05 %.3f  p50 %.3f  p95 %.3f · %d spans · %.0f mm",
                         width, pct(rad, 0.05), pct(rad, 0.5), pct(rad, 0.95), tr.spans.count, len))
        }
    }
}
