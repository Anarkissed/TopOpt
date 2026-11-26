// Notes30StrutStreamTests — ★ notes30, his decision 2026-11-26 (option D of the scoping pass, "start the full version"): "The
// strut engine hands over its struts while it works, the way Organic's engine does, so the floors rise in step with the real
// work." The app half (scope.md §3.5 S1-S5), against a FAKE ENGINE (the test double the scope asks for until core's StrutTap
// lands: it hands out a finished lattice's whole struts behind a line that rises at a given pace, and its map's rows behind
// the same line; what the line cannot promise — the pieces and the skin — only with the landing).
//   S1 the pacing: never a floor the line has not passed; aimed at the expected landing; 7 s at least; the catch-up.
//   S2 never vanish: every strut shown before the landing shows after it (the frame fixed at the stream's start).
//   S3 Skip all animations: unchanged — blank and the card; no stream read or drawn.
//   S4 the Settings sample streams the same way.
//   S5 the bars pass appends the stream (doubling: never a whole upload per poll) and uploads the landing once.
//   + the walls come off floor by floor; the poll's cursor shared with Organic's; the in-app counter of a broken promise.
// Each with its RED CONTROL (the picture the rule forbids).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import AppKit
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// ★ notes30: the fake engine — a finished lattice handed out as core's StrutTap would: its whole struts (both ends at nodes:
/// flags without the piece or skin bits) in order of their highest point, each once the line has risen past it; the line
/// rising from the plan's foot to past its top over `cellsS` (the cells), then at +∞ until `layS` (the pieces, the map);
/// the map's rows (raw) behind the same line.
final class FakeStrutEngine: LatticeStrutTap {
    let bars: [Float], flags: [UInt8]
    let up: SIMD3<Float>, lo: SIMD3<Float>, hi: SIMD3<Float>
    var cellsS: Double, layS: Double
    /// The finished map (its rows handed out behind the line), and every strut's reach.
    var map: LatticeLayoutSolidGrid?
    let reach: Float
    var clock: () -> Double = { CACurrentMediaTime() }
    private(set) var lay: UInt64 = 0
    private(set) var startedAt = 0.0
    private(set) var asked: (up: SIMD3<Float>, map: Bool)?
    private(set) var reads = 0
    /// The whole struts by their highest point (along up), and those heights.
    private let order: [Int]
    private let tops: [Float]
    /// RED CONTROL: a strut handed over that the finished lattice does not hold (its end moved 1 mm).
    var handOneThatMoves = false

    init(bars: [Float], flags: [UInt8], up: SIMD3<Float> = SIMD3(0, 0, 1), plan: (lo: SIMD3<Float>, hi: SIMD3<Float>)? = nil,
         cellsS: Double, layS: Double, map: LatticeLayoutSolidGrid? = nil) {
        self.bars = bars; self.flags = flags; self.up = simd_normalize(up); self.cellsS = cellsS; self.layS = layS; self.map = map
        let n = bars.count / 7
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var whole: [(Int, Float)] = []
        var reach: Float = 0
        for i in 0..<n {
            let a = SIMD3(bars[7 * i], bars[7 * i + 1], bars[7 * i + 2]), b = SIMD3(bars[7 * i + 3], bars[7 * i + 4], bars[7 * i + 5])
            lo = simd_min(lo, simd_min(a, b)); hi = simd_max(hi, simd_max(a, b))
            let ha = simd_dot(self.up, a), hb = simd_dot(self.up, b)
            reach = Swift.max(reach, abs(ha - hb))
            if i < flags.count, flags[i] & 3 != 0 { continue }
            whole.append((i, Swift.max(ha, hb)))
        }
        whole.sort { $0.1 < $1.1 }
        order = whole.map(\.0); tops = whole.map(\.1)
        self.reach = reach
        self.lo = plan?.lo ?? lo; self.hi = plan?.hi ?? hi
    }

    var wholeCount: Int { order.count }

    func streamNextLay(up: SIMD3<Float>, map: (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>)?) {
        lay += 1
        startedAt = clock()
        asked = (up, map != nil)
    }

    /// The plan's lowest and highest heights along up.
    var heights: (lo: Float, hi: Float) {
        var l = Float.greatestFiniteMagnitude, h = -l
        for i in 0..<8 {
            let p = SIMD3<Float>(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
            l = Swift.min(l, simd_dot(up, p)); h = Swift.max(h, simd_dot(up, p))
        }
        return (l, h)
    }
    /// The line at `t` (wall s): from the foot to past the top over the cells, then +∞.
    func line(at t: Double) -> Float {
        let u = (t - startedAt) / Swift.max(cellsS, 1e-6)
        if u >= 1 { return .infinity }
        if u <= 0 { return -.infinity }
        let (l, h) = heights
        return l + Float(u) * (h - l + reach)
    }
    func progress(at t: Double) -> Double { Swift.min(1, Swift.max(0, (t - startedAt) / Swift.max(cellsS, 1e-6))) }

    /// The map's rows, as the line passes them (raw), from `mapFrom` on — rows whose every voxel lies at or below the line.
    private func mapRows(line: Float, from: Int) -> (next: Int, rows: [LatticeStrutRead.MapRows], mapLine: Float) {
        guard let m = map else { return (from, [], -.infinity) }
        let nx = Int(m.dims.x), ny = Int(m.dims.y), nz = Int(m.dims.z), slab = 2 * nx * ny
        func hRange(_ z: Int) -> (Float, Float) {
            var l = Float.greatestFiniteMagnitude, h = -l
            for c in 0..<4 {
                let p = m.origin + m.voxel * SIMD3(Float(c & 1 == 0 ? 0 : nx - 1), Float(c & 2 == 0 ? 0 : ny - 1), Float(z))
                l = Swift.min(l, simd_dot(up, p)); h = Swift.max(h, simd_dot(up, p))
            }
            return (l, h)
        }
        // rows in the order the line passes them (z up for +z)
        let zs = (0..<nz).sorted { hRange($0).1 < hRange($1).1 }
        var k = 0
        while k < nz, hRange(zs[k]).1 <= line { k += 1 }
        var rows: [LatticeStrutRead.MapRows] = []
        if k > from {
            for z in zs[from..<k] {
                rows.append(.init(z0: Int32(z), z1: Int32(z + 1), rg: Array(m.rg[(z * slab)..<((z + 1) * slab)])))
            }
        }
        let mapLine: Float = k >= nz ? .infinity : hRange(zs[k]).0 - 1e-3
        return (Swift.max(k, from), rows, mapLine)
    }

    func strutRead(from: Int, most: Int, mapFrom: Int) throws -> LatticeStrutRead {
        reads += 1
        let t = clock()
        guard lay > 0 else { return LatticeStrutRead(lay: 0) }
        let line = asked == nil ? -.infinity : self.line(at: t)
        var k = 0
        while k < tops.count, tops[k] <= line { k += 1 }
        let a = Swift.min(from, k), b = most > 0 ? Swift.min(k, a + most) : k
        var out: [Float] = [], fl: [UInt8] = []
        for j in a..<b {
            let i = order[j]
            var s = Array(bars[(7 * i)..<(7 * i + 7)])
            if handOneThatMoves, j == 0 { s[2] += 1 }
            out += s
            fl.append(i < flags.count ? flags[i] : 0)
        }
        let p = progress(at: t)
        let phase = t - startedAt >= layS ? 5 : (p >= 1 ? 3 : 1)
        let mr = asked?.map == true ? mapRows(line: line, from: mapFrom) : (mapFrom, [], -.infinity)
        return LatticeStrutRead(lay: lay, phase: phase, next: b, up: up, lo: lo, hi: hi,
                                slotsDone: Int(p * 1000), slotsTotal: 1000, line: line, reach: reach,
                                bars: out, flags: fl, mapLine: mr.2, mapNext: mr.0, mapRows: mr.1)
    }
}

@MainActor
final class Notes30StrutStreamTests: XCTestCase {

    override func tearDown() {
        LatticeBuildShow.clockForTesting = nil
        LatticeBuildShow.controlOff = false
        LatticeBuildShow.controlIgnoreLine = false
        LatticeBuildShow.controlFrameFromLanded = false
        LatticeLayoutBarsPass.controlStreamReupload = false
        LatticeLayoutBarsPass.controlNoWallsMask = false
        LatticeLayoutPreview.strutTapForTesting = nil
        LatticeLayoutPreview.controlNoStream = false
        LatticeStrutStream.smoothInline = false
        AppSettings.skipAllAnimations = false
        LatticeBuildTimelapse.totalS = LatticeBuildTimelapse.hisTotalS
        super.tearDown()
    }

    // MARK: fixtures

    /// A lattice in the 40 mm cube: columns (along z) and beams (x) and diagonals every `cell` mm — whole struts — and, at the
    /// cube's faces, cut pieces (flag 1) and skin (flag 2) that only land with the lay (the cladding).
    static func lattice(cell: Float = 6, width: Float = 1.2) -> (bars: [Float], flags: [UInt8]) {
        var out: [Float] = [], flags: [UInt8] = []
        let n = Int(30 / cell)
        for i in 0...n { for j in 0...n { for k in 0..<n {
            let x = 5 + Float(i) * cell, y = 5 + Float(j) * cell, z = 5 + Float(k) * cell
            out += [x, y, z, x, y, z + cell, width]; flags.append(0)                                  // a column
            if i < n { out += [x, y, z + cell, x + cell, y, z + cell, width]; flags.append(0) }       // a beam
            if i < n, j < n { out += [x, y, z, x + cell, y + cell, z + cell, width]; flags.append(0) } // a diagonal
        }}}
        for i in 0...n { for k in 0..<n {   // the pieces cut at the faces, and a little skin
            let x = 5 + Float(i) * cell, z = 5 + Float(k) * cell
            out += [x, 5, z, x, 2, z + cell / 2, width]; flags.append(1)
            out += [x, 35, z, x, 38, z + cell / 2, width]; flags.append(1)
            out += [x, 2, z, x, 2, z + cell, width * 0.8]; flags.append(2)
        }}
        return (out, flags)
    }

    /// One whole lay through the show at 30 fps on its own clock, from the ask at `t0` to the end: the engine's line read every
    /// 0.15 s onto the stream, the landing at `t0 + 0.3 + layS`. Returns, per floor, when the line had passed it (all its
    /// struts out) and when it first showed; and the timelapse at its end.
    struct Run { var certified: [Double]; var shown: [Double]; var end: Double; var tl: LatticeBuildTimelapse
        var floorsBeforeLanding: Int; var snapTimes: [Double]; var frame: LatticeBuildTimelapse.Frame
        /// When the poll saw the cells all laid (s from the ask), and the landing.
        var cellsEnd: Double?; var landAt: Double }
    func run(cellsS: Double, layS: Double, lastLayS: Double? = nil, afterShare: Double? = nil, walls: Bool = false,
             map: LatticeLayoutSolidGrid? = nil, plan: (lo: SIMD3<Float>, hi: SIMD3<Float>)? = nil) throws -> Run {
        let (bars, flags) = Self.lattice()
        let t0 = 1000.0
        var now = t0
        let fake = FakeStrutEngine(bars: bars, flags: flags, plan: plan, cellsS: cellsS, layS: layS, map: map)
        fake.clock = { now }
        let show = LatticeBuildShow()
        show.layBegins(walls: walls, now: t0)
        LatticeStrutStream.smoothInline = true
        show.stream.reset(map: map.map { ($0.origin, $0.voxel, $0.dims) })
        now = t0 + 0.3   // the session opened, the stress given: the lay begins
        fake.streamNextLay(up: SIMD3(0, 0, 1), map: map.map { ($0.origin, $0.voxel, $0.dims) })
        let landAt = t0 + 0.3 + layS
        var mapNext = 0, cellsFrom: Double?, cellsEnd: Double?, lastPoll = -1.0
        var certified: [Double?] = [], shown: [Double?] = []
        var landed = false
        let dt = 1.0 / 30
        while now < t0 + 60 {
            if !landed, now - lastPoll >= 0.15 - 1e-9 {   // the poll
                lastPoll = now
                let r = try fake.strutRead(from: show.stream.count, most: 0, mapFrom: mapNext)
                show.stream.take(r)
                mapNext = r.mapNext
                if show.stream.plan != nil, cellsFrom == nil { cellsFrom = now }
                if cellsEnd == nil, show.stream.progress >= 1 { cellsEnd = now }
                show.streamMoved(now: now)
                show.expect(landingAt: LatticeStrutPace.expectedLanding(start: t0, cellsFrom: cellsFrom, cellsEnd: cellsEnd, now: now,
                                                                         progress: show.stream.progress, afterShare: afterShare,
                                                                         lastLayS: lastLayS))
            }
            if !landed, now >= landAt {
                landed = true
                show.landed(token: 7, box: nil, now: landAt)
            }
            if let f = show.frame {
                if certified.isEmpty { certified = Array(repeating: nil, count: f.floors); shown = certified }
                let line = fake.line(at: now)
                for k in 0..<f.floors where certified[k] == nil && (line >= f.top(k) + fake.reach || landed) { certified[k] = now }
                let r = landed ? show.reveal(barsToken: 7, floors: f.floors, at: now) : show.revealStream(at: now)
                var floorsShown = 0
                switch r {
                case .all: floorsShown = f.floors
                case .none: floorsShown = 0
                case .snaps(let n): floorsShown = n == 0 ? 0 : (n - 1) / LatticeBuildTimelapse.perFloor + 1
                }
                if walls, let o = show.wallsOpen(barsToken: landed ? 7 : nil, at: now) { floorsShown = Swift.max(floorsShown, o) }
                for k in 0..<floorsShown where shown[k] == nil { shown[k] = now }
            }
            if landed, let tl = show.timelapse, tl.done(at: now) { break }
            if landed, show.timelapse == nil { break }
            show.step(now)
            now += dt
        }
        let tl = try XCTUnwrap(show.timelapse, "the timelapse is still held at its end")
        let f = try XCTUnwrap(show.frame)
        return Run(certified: certified.map { $0 ?? .infinity }, shown: shown.map { $0 ?? .infinity },
                   end: try XCTUnwrap(tl.end) - t0, tl: tl, floorsBeforeLanding: tl.floorsBeforeLanding, snapTimes: tl.snapTimes, frame: f,
                   cellsEnd: cellsEnd.map { $0 - t0 }, landAt: landAt - t0)
    }

    // MARK: S1 the pacing

    /// ★ "so the floors rise in step with the real work": no floor shows before the engine's line has passed it (every strut
    /// of it handed over); a slow lay's floors come WHILE it lays (in step with the line), ending about a second before the
    /// expected landing; the whole at least his 7 s; the snaps hard (each its own frame, a beat between floors).
    /// RED CONTROL `controlIgnoreLine`: the pace alone — floors shown before the line has passed them.
    func testS1TheFloorsNeverPassTheLineAndRiseInStepWithTheWork() throws {
        for red in [false, true] {
            LatticeBuildShow.controlIgnoreLine = red
            let r = try run(cellsS: 9, layS: 10, lastLayS: 10.3)
            let early = zip(r.shown, r.certified).filter { $0.0 < $0.1 - 1e-9 }.count
            print(String(format: "S1%@: %d floors; certified %@; shown %@; end %.2f s; %d floors before the landing",
                         red ? " RED" : "", r.frame.floors, r.certified.map { String(format: "%.2f", $0 - 1000) }.joined(separator: " "),
                         r.shown.map { String(format: "%.2f", $0 - 1000) }.joined(separator: " "), r.end, r.floorsBeforeLanding))
            if red { XCTAssertGreaterThan(early, 0, "RED CONTROL: the pace alone shows floors the line has not passed"); continue }
            XCTAssertEqual(early, 0, "★ never a floor before the line has passed it")
            XCTAssertGreaterThanOrEqual(r.floorsBeforeLanding, r.frame.floors - 1, "★ a slow lay's floors rise WHILE it lays")
            for (s, c) in zip(r.shown, r.certified) { XCTAssertLessThan(s - c, 2.0, "★ in step with the line (within a floor's beat)") }
            XCTAssertGreaterThanOrEqual(r.end, LatticeBuildTimelapse.totalS - 1e-9, "★ at least his 7 s")
            let gaps = zip(r.snapTimes.dropFirst(), r.snapTimes).map { $0 - $1 }
            XCTAssertGreaterThanOrEqual(gaps.min() ?? 1, 1.0 / 30 - 1e-6, "★ hard snaps: each its own frame at 30 fps")
            XCTAssertGreaterThan(gaps.max() ?? 0, (gaps.min() ?? 0) * 1.5, "★ hard stops: a beat between floors")
        }
    }

    /// ★ The pace aims at the expected landing: a line that is quick (the flat part's cells in 2 s of a 9 s lay) still has its
    /// floors spread to end `marginS` before the landing the engine's progress foretells — never ahead of the line, never all at
    /// once at the end. A quick lay (1.2 s) fills exactly his 7 s. A late landing (the line still below the top) shows what is
    /// left as the catch-up: each floor WHOLE in one snap, `catchUpFloorS` apart, then topped out.
    func testS1ThePaceAimsAtTheLandingAndALateLandingCatchesUp() throws {
        typealias T = LatticeBuildTimelapse
        // a quick line in a long lay: the share after the cells learned on the lay before (as the page learns it), then the
        // landing foretold from the line's progress
        let first = try run(cellsS: 2, layS: 9)
        let share = try XCTUnwrap(LatticeStrutPace.afterShare(start: 0, cellsEnd: first.cellsEnd, landed: first.landAt))
        let slow = try run(cellsS: 2, layS: 9, lastLayS: 9.3, afterShare: share)
        let lastEnd = (slow.tl.shownFloors.last.map { $0.at + $0.dur } ?? 0) - 1000
        let foretold = try XCTUnwrap(slow.tl.expectedLanding) - 1000
        print(String(format: "S1 pace: floors end at %.2f s; the landing foretold at %.2f s, at 9.3 s; end %.2f s", lastEnd, foretold, slow.end))
        XCTAssertEqual(foretold, 9.3, accuracy: 0.1, "★ the landing foretold from the line's progress and the share learned")
        XCTAssertEqual(lastEnd, foretold - T.marginS, accuracy: 0.1, "★ the floors end a second before the foretold landing")
        XCTAssertLessThan(lastEnd, 9.3, "★ … before the engine lands")
        XCTAssertEqual(slow.floorsBeforeLanding, slow.frame.floors, "every floor before the landing")
        XCTAssertEqual(slow.end, 9.3 + T.toppedOutS, accuracy: 1e-6, "★ the cladding at the landing, then topped out")
        // a quick lay: exactly his total
        let quick = try run(cellsS: 0.5, layS: 1.2)
        XCTAssertEqual(quick.end, T.totalS, accuracy: 1e-6, "★ a quick lay: exactly his 7 s")
        XCTAssertGreaterThan(quick.floorsBeforeLanding, 0, "the first floors rose while it laid")
        // a late landing: the line has not passed the top floor when the engine lands
        let late = try run(cellsS: 14, layS: 12)
        let landing = 1000 + 12.3
        let after = late.tl.shownFloors.filter { $0.at >= landing - 1e-9 }
        print(String(format: "S1 late: %d floors before the landing, %d after (whole: %@); end %.2f s", late.floorsBeforeLanding,
                     after.count, after.map { $0.whole ? "y" : "n" }.joined(), late.end))
        XCTAssertGreaterThan(late.floorsBeforeLanding, 0, "premise: some floors stood")
        XCTAssertFalse(after.isEmpty, "premise: floors left at the landing")
        XCTAssertTrue(after.allSatisfy(\.whole), "★ the catch-up: each floor whole, in one snap")
        for (a, b) in zip(after.dropFirst(), after) { XCTAssertEqual(a.at - b.at, T.catchUpFloorS, accuracy: 1e-6) }
        XCTAssertEqual(late.end, (after.first?.at ?? 0) - 1000 + Double(after.count) * T.catchUpFloorS + T.toppedOutS, accuracy: 1e-6)
        XCTAssertLessThan((after.first?.at ?? 0) - 1000, 12.3 + 1.0, "the catch-up right after the landing")
    }

    /// ★ Walls: in the solid view a floor waits for its map too (made behind the same line): it shows only once the map is
    /// made a margin past its top. RED CONTROL: no map at all — the floors wait for the landing (as release 21).
    func testS1InTheSolidViewAFloorWaitsForItsMapBehindTheLine() throws {
        let map = Self.cubeMap()
        let with = try run(cellsS: 6, layS: 7, lastLayS: 7.3, walls: true, map: map)
        let without = try run(cellsS: 6, layS: 7, lastLayS: 7.3, walls: true, map: nil)
        print("S1 walls: with the map \(with.floorsBeforeLanding) floors before the landing; without \(without.floorsBeforeLanding)")
        XCTAssertGreaterThanOrEqual(with.floorsBeforeLanding, with.frame.floors - 1, "★ the walls come off floor by floor as it lays")
        XCTAssertEqual(without.floorsBeforeLanding, 0, "RED CONTROL: no map behind the line — nothing opens before the landing")
        XCTAssertGreaterThanOrEqual(without.end, LatticeBuildTimelapse.totalS, "and it still rises in full after")
    }

    /// The 40 mm cube's map (1 mm voxels, air round it): open lattice inside 4 … 36, solid skin round it.
    static func cubeMap(token: Int = 1) -> LatticeLayoutSolidGrid {
        let dims = SIMD3<Int32>(44, 44, 44), origin = SIMD3<Float>(-2, -2, -2)
        var rg = [Int8](); rg.reserveCapacity(2 * 44 * 44 * 44)
        for z in 0..<44 { for y in 0..<44 { for x in 0..<44 {
            let p = origin + SIMD3(Float(x), Float(y), Float(z))
            let inside = p.x >= 0 && p.x <= 40 && p.y >= 0 && p.y <= 40 && p.z >= 0 && p.z <= 40
            let open = inside && p.x > 3 && p.x < 37 && p.z > 3 && p.z < 37 && p.y < 37
            rg += [open ? 127 : -127, inside ? 127 : -127]
        }}}
        return LatticeLayoutSolidGrid(token: token, origin: origin, voxel: 1, dims: dims, rg: rg)
    }

    // MARK: S2 never vanish

    /// ★ HIS RULE "never draw a strut that later vanishes": every strut shown before the landing (the stream's, by the frame
    /// fixed at its start from the engine's plan) is shown after it (the landed lattice's, by the same frame), at every moment.
    /// RED CONTROL `controlFrameFromLanded`: the frame made again from the landed bars' box at the landing (release 21's
    /// frame) — a strut shown before is hidden after.
    func testS2EveryStrutShownBeforeTheLandingIsShownAfter() throws {
        let (bars, flags) = Self.lattice()
        for red in [false, true] {
            LatticeBuildShow.controlFrameFromLanded = red
            let t0 = 2000.0
            var now = t0
            // the engine plans its cells over a box larger than the struts land in (cells planned high above them)
            let fake = FakeStrutEngine(bars: bars, flags: flags, plan: (SIMD3(1, 1, 5), SIMD3(39, 39, 75)), cellsS: 3, layS: 3.5)
            fake.clock = { now }
            let show = LatticeBuildShow()
            show.layBegins(now: t0)
            fake.streamNextLay(up: SIMD3(0, 0, 1), map: nil)
            func key(_ v: [Float], _ i: Int) -> [Float] { Array(v[(7 * i)..<(7 * i + 6)]) }
            func shownKeys(_ v: [Float], snaps n: Int?, frame f: LatticeBuildTimelapse.Frame) -> Set<[Float]> {
                var out = Set<[Float]>()
                for i in 0..<(v.count / 7) {
                    let s = LatticeBuildTimelapse.step(SIMD3(v[7 * i], v[7 * i + 1], v[7 * i + 2]), SIMD3(v[7 * i + 3], v[7 * i + 4], v[7 * i + 5]), f)
                    if n.map({ s < $0 }) ?? true { out.insert(key(v, i)) }
                }
                return out
            }
            var before = Set<[Float]>()
            while now < t0 + 3.5 {
                let r = try fake.strutRead(from: show.stream.count, most: 0, mapFrom: 0)
                show.stream.take(r); show.streamMoved(now: now)
                if let f = show.frame, case .snaps(let n) = show.revealStream(at: now) {
                    let streamed = show.stream.bars
                    before.formUnion(shownKeys(streamed, snaps: n, frame: f))
                }
                show.step(now)
                now += 0.05
            }
            XCTAssertFalse(before.isEmpty, "premise: struts shown before the landing")
            let landedBox = try XCTUnwrap(LatticeLayoutBarsPass.box(bars))
            show.landed(token: 9, box: landedBox, now: now)
            var hidden = 0
            while let tl = show.timelapse, !tl.done(at: now), now < t0 + 30 {
                let f = try XCTUnwrap(show.frame)
                let rv = show.reveal(barsToken: 9, floors: f.floors, at: now)
                let after: Set<[Float]>
                switch rv { case .all: after = Set((0..<(bars.count / 7)).map { key(bars, $0) })
                case .none: after = []
                case .snaps(let n): after = shownKeys(bars, snaps: n, frame: f) }
                hidden = Swift.max(hidden, before.subtracting(after).count)
                show.step(now)
                now += 1.0 / 30
            }
            print("S2\(red ? " RED" : ""): \(before.count) struts shown before the landing; at worst \(hidden) of them hidden after")
            if red { XCTAssertGreaterThan(hidden, 0, "RED CONTROL: the frame made again at the landing hides a strut shown before"); continue }
            XCTAssertEqual(hidden, 0, "★ every strut shown before the landing is shown after it")
        }
    }

    /// The renderer: the lattice's purple never drops at the landing (the stream's pass handing over to the landed pass with the
    /// cladding), only rises, and the landed pass is drawn as soon as its bars are on the GPU. RED CONTROL: the frame made again
    /// at the landing — purple drops.
    func testS2TheRendererNeverTakesAStrutAwayAtTheLanding() throws {
        let (bars, flags) = Self.lattice()
        for red in [false, true] {
            LatticeBuildShow.controlFrameFromLanded = red
            guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device) else {
                throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
            }
            r.setMesh(ViewerMesh(vertices: Notes29AnimationTests.cubeV, indices: Notes29AnimationTests.cubeI,
                                 faceIDs: [Int32](repeating: 1, count: Notes29AnimationTests.cubeI.count / 3)))
            r.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
            r.beginSettle(to: LatticeSampleView.settleZUp, duration: 0)
            r.camera.setOrientation(azimuth: -0.6, elevation: 0.45)
            func frame() throws -> [UInt8] {
                try XCTUnwrap(r.renderOffscreen(width: 480, height: 360, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), stage: false))
            }
            let show = LatticeBuildShow()
            r.applyBuildShow(show)
            let t0 = CACurrentMediaTime() + 1000
            var now = t0
            LatticeBuildShow.clockForTesting = now
            let fake = FakeStrutEngine(bars: bars, flags: flags, plan: (SIMD3(1, 1, 5), SIMD3(39, 39, 75)), cellsS: 2.5, layS: 3)
            fake.clock = { now }
            show.layBegins(now: t0)
            _ = try frame()
            XCTAssertEqual(show.viewAxes.up.z, 1, accuracy: 1e-4, "premise: the part stood Z-up")
            fake.streamNextLay(up: show.viewAxes.up, map: nil)
            var purple: [Int] = [], landedAt = -1
            while now < t0 + 3 {
                LatticeBuildShow.clockForTesting = now
                let rd = try fake.strutRead(from: show.stream.count, most: 0, mapFrom: 0)
                show.stream.take(rd); show.streamMoved(now: now)
                purple.append(Notes29AnimationTests.purple(try frame()))
                now += 0.1
            }
            XCTAssertTrue(r.streamBars != nil && r.drawnLayoutBars === r.streamBars, "★ the stream's pass is drawn while it lays")
            XCTAssertGreaterThan(purple.max() ?? 0, 300, "★ struts drawn while the engine lays")
            LatticeBuildShow.clockForTesting = now
            let landedBox = try XCTUnwrap(LatticeLayoutBarsPass.box(bars))
            show.landed(token: 5, box: landedBox, now: now)
            purple.append(Notes29AnimationTests.purple(try frame()))   // (the landed bars not on the GPU yet: the stream still)
            r.applyLayoutBars(LatticeLayoutBarsInputs(token: 5, bars: bars, flags: flags), device: device)
            landedAt = purple.count
            purple.append(Notes29AnimationTests.purple(try frame()))
            XCTAssertTrue(r.drawnLayoutBars === r.layoutBars, "the landed pass once on the GPU")
            while let tl = show.timelapse, !tl.done(at: now), now < t0 + 20 {
                now += 1.0 / 15
                LatticeBuildShow.clockForTesting = now
                purple.append(Notes29AnimationTests.purple(try frame()))
            }
            let drop = zip(purple.dropFirst(), purple).map { $1 - $0 }.max() ?? 0
            print("S2 renderer\(red ? " RED" : ""): purple \(purple.prefix(40)) … landing at \(landedAt); worst drop \(drop)")
            if red { XCTAssertGreaterThan(drop, 60, "RED CONTROL: struts taken away at the landing"); continue }
            XCTAssertLessThanOrEqual(drop, 25, "★ never a strut taken away (the purple only rises)")
            XCTAssertGreaterThanOrEqual(purple[landedAt], purple[landedAt - 1] - 25, "★ the landing adds the cladding, takes nothing")
        }
    }

    // MARK: S3 Skip all animations

    /// ★ "a blank screen with a 'Refreshing Lattice' notification and progress bar": with Skip all animations the engine is
    /// never asked to stream (the sample's poll does not start), and a stream fed anyway is never drawn: the lattice area blank
    /// while it lays, whole at once when it lands. RED CONTROL: skip off — the stream drawn while it lays.
    func testS3SkipAllAnimationsDrawsNoStream() throws {
        let (bars, flags) = Self.lattice()
        for skip in [true, false] {
            AppSettings.skipAllAnimations = skip
            guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device) else {
                throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
            }
            r.setMesh(ViewerMesh(vertices: Notes29AnimationTests.cubeV, indices: Notes29AnimationTests.cubeI,
                                 faceIDs: [Int32](repeating: 1, count: Notes29AnimationTests.cubeI.count / 3)))
            r.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
            r.beginSettle(to: LatticeSampleView.settleZUp, duration: 0)
            r.camera.setOrientation(azimuth: -0.6, elevation: 0.45)
            let show = LatticeBuildShow()
            r.applyBuildShow(show)
            let t0 = CACurrentMediaTime() + 1000
            LatticeBuildShow.clockForTesting = t0
            show.layBegins(now: t0)
            let fake = FakeStrutEngine(bars: bars, flags: flags, cellsS: 0.01, layS: 1)
            fake.clock = { t0 }
            fake.streamNextLay(up: SIMD3(0, 0, 1), map: nil)
            fake.clock = { t0 + 5 }
            show.stream.take(try fake.strutRead(from: 0, most: 0, mapFrom: 0))
            show.streamMoved(now: t0 + 0.9)
            LatticeBuildShow.clockForTesting = t0 + 0.9
            let px = Notes29AnimationTests.purple(try XCTUnwrap(r.renderOffscreen(width: 480, height: 360,
                                                  clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), stage: false)))
            if skip {
                XCTAssertEqual(px, 0, "★ nothing drawn while it lays")
                XCTAssertFalse(show.drawsStream(landedToken: nil), "★ no stream drawn")
                XCTAssertTrue(show.waiting, "★ the card's lay under way")
                show.landed(token: 3, now: t0 + 1)
                XCTAssertNil(show.timelapse, "★ whole at once when it lands")
            } else {
                XCTAssertGreaterThan(px, 100, "RED CONTROL: the stream drawn while it lays")
            }
        }
    }

    // MARK: S4 the Settings sample

    /// ★ "the sample gets the same rising floors": the sample's lay, on its own session, is asked to stream and its struts are
    /// read onto its timelapse (every whole one of the lay, none it does not hold), the floors rising behind the line.
    /// RED CONTROL `LatticeBuildShow.controlOff`: no timelapse — nothing streamed.
    func testS4TheSampleStreamsTheSameWay() async throws {
        let plan = LatticeSampleLay.plain(topology: "octet", cellMM: 8, lineWidthMM: 0.45, rho: 0.25)
        let reference = try await LatticeSampleLay.lay(plan, cube: true)
        XCTAssertGreaterThan(reference.struts, 50, "premise: the sample laid")
        for red in [false, true] {
            LatticeBuildShow.controlOff = red
            let show = LatticeBuildShow()
            show.layBegins()
            var fake: FakeStrutEngine?
            LatticeLayoutPreview.strutTapForTesting = { _ in
                let f = FakeStrutEngine(bars: reference.bars, flags: reference.flags, cellsS: 0.001, layS: 0.002)
                fake = f
                return f
            }
            let stream = LatticeSampleStream(show: show)
            let made = try await LatticeSampleLay.lay(plan, cube: true, stream: stream)
            XCTAssertEqual(made.bars, reference.bars, "premise: the same sample (the engine is pinned)")
            if red {
                XCTAssertEqual(show.stream.count, 0, "RED CONTROL: no timelapse, nothing streamed")
                continue
            }
            let f = try XCTUnwrap(fake, "★ the sample's session was asked for its tap")
            XCTAssertNotNil(f.asked, "★ the sample's lay asked to stream")
            XCTAssertEqual(show.stream.bars.count / 7, f.wholeCount, "★ every whole strut handed over, read by the sample's poll")
            XCTAssertEqual(show.stream.missing(from: made.bars), 0, "★ none the lay does not hold")
            XCTAssertTrue(show.drawsStream(landedToken: nil), "★ drawn behind the line until the landing")
            show.landed(token: 1, box: LatticeLayoutBarsPass.box(made.bars))
            XCTAssertNotNil(show.frame)
        }
    }

    // MARK: S5 the bars pass appends

    /// ★ The stream's struts go to the GPU appended: one buffer grown by doubling (the old part copied once per doubling),
    /// never the whole set again per poll; the landed lattice uploads once. RED CONTROL `controlStreamReupload`: the whole set
    /// re-sent every poll — a buffer made per poll.
    func testS5TheBarsPassAppendsTheStreamAndUploadsTheLandingOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let (bars, flags) = Self.lattice(cell: 3)
        let polls = 60
        for red in [false, true] {
            LatticeLayoutBarsPass.controlStreamReupload = red
            let pass = try LatticeLayoutBarsPass(device: device)
            let stream = LatticeStrutStream()
            stream.reset()
            let n = bars.count / 7, per = (n + polls - 1) / polls
            for p in 0..<polls {
                let i = p * per, j = Swift.min(n, i + per)
                guard i < j else { break }
                var r = LatticeStrutRead(lay: 1, phase: 1, next: j, up: SIMD3(0, 0, 1), lo: .zero, hi: SIMD3(40, 40, 40),
                                         slotsDone: p, slotsTotal: polls, line: Float(p), reach: 6)
                r.bars = Array(bars[(7 * i)..<(7 * j)]); r.flags = Array(flags[i..<j])
                stream.take(r)
                pass.syncStream(stream)
            }
            XCTAssertEqual(pass.count, n, "every strut on the GPU")
            let gpu = UnsafeBufferPointer(start: try XCTUnwrap(pass.buffer).contents().assumingMemoryBound(to: SIMD4<Float>.self),
                                          count: 2 * n)
            XCTAssertEqual(Array(gpu), stream.packed, "★ the GPU holds exactly the stream, in order")
            XCTAssertEqual(stream.packed, LatticeLayoutBarsPass.pack(bars, flags: flags), "the stream packs as the landed bars do")
            print("S5\(red ? " RED" : ""): \(n) struts in \(polls) polls: \(pass.buffersMade) buffers made")
            if red { XCTAssertGreaterThanOrEqual(pass.buffersMade, polls / 2, "RED CONTROL: a buffer per poll"); continue }
            XCTAssertLessThanOrEqual(pass.buffersMade, Int(log2(Double(n) / 4096).rounded(.up)) + 2, "★ grown by doubling")
            // the landing: one whole upload, never again for the same lay
            let landed = try LatticeLayoutBarsPass(device: device)
            let inputs = LatticeLayoutBarsInputs(token: 4, bars: bars, flags: flags)
            for _ in 0..<5 { _ = Self.apply(landed, inputs) }
            XCTAssertEqual(landed.wholeUploads, 1, "★ the landed lattice uploaded once")
        }
    }
    private static func apply(_ p: LatticeLayoutBarsPass, _ i: LatticeLayoutBarsInputs) -> Bool {
        if p.token != i.token { p.upload(i); return true }
        return false
    }

    // MARK: the walls, floor by floor

    /// ★ The walls come off FLOOR BY FLOOR (option D): the part closed while it lays; then each floor's walls in one hard snap,
    /// the part opened up to that floor's top, closed above it; open as the map says once topped out. Seen from the side on
    /// the open face (a pocket's mouth along the part's up). RED CONTROL `controlNoWallsMask`: the whole part opened at the
    /// first floor.
    func testTheWallsComeOffFloorByFloor() throws {
        for red in [false, true] {
            LatticeLayoutBarsPass.controlNoWallsMask = red
            guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device) else {
                throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
            }
            r.setMesh(ViewerMesh(vertices: Notes24IntoThePartTests.cubeV, indices: Notes24IntoThePartTests.cubeI,
                                 faceIDs: [Int32](repeating: 1, count: Notes24IntoThePartTests.cubeI.count / 3)))
            r.setBodyAlpha(1)   // the solid view
            r.camera.target = SIMD3(10, 14, 10)   // looking down into the pocket's mouth (y = 20)
            r.camera.setOrientation(azimuth: 0.6, elevation: 1.25)
            r.camera.distance = 48
            let (w, h) = (480, 360)
            func frame() throws -> [UInt8] {
                try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), stage: false))
            }
            func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
                stride(from: 0, to: a.count, by: 4).filter { abs(Int(a[$0]) - Int(b[$0])) + abs(Int(a[$0 + 1]) - Int(b[$0 + 1])) > 24 }.count
            }
            let closed = try frame()
            let show = LatticeBuildShow()
            r.applyBuildShow(show)
            let t0 = CACurrentMediaTime() + 1000
            LatticeBuildShow.clockForTesting = t0
            // the struts deep in the pocket, laid standing on the face he kept (+x: the floors rise across the mouth), a column
            // per 2 mm (the frame from their box: 5 … 15 along x)
            var bar: [Float] = []
            for x in stride(from: Float(5), to: 15, by: 2) { bar += [x, 12, 10, x + 2, 12, 10, 0.6] }
            show.layBegins(walls: true, now: t0)
            _ = try frame()
            LatticeBuildShow.clockForTesting = t0 + 0.6
            let laying = differing(closed, try frame())
            let land = t0 + 1.2
            var landedBars = LatticeLayoutBarsInputs(token: 2, bars: bar, solid: Notes24IntoThePartTests.pocketMap(token: 2))
            landedBars.printUp = SIMD3(1, 0, 0)
            r.applyLayoutBars(landedBars, device: device)
            show.landed(token: 2, box: LatticeLayoutBarsPass.box(bar), printUp: landedBars.printUp, now: land)
            var levels: [Int] = []
            var opens: [Int] = []
            var t = land
            while let tl = show.timelapse, !tl.done(at: t) {
                LatticeBuildShow.clockForTesting = t
                let px = try frame()
                let o = show.wallsOpen(barsToken: 2, at: t) ?? -1
                if opens.last != o { opens.append(o); levels.append(differing(closed, px)) }
                t += 1.0 / 30
            }
            LatticeBuildShow.clockForTesting = t + 0.1
            let open = differing(closed, try frame())
            print("WALLS\(red ? " RED" : ""): laying \(laying); floors opened \(opens) → px \(levels); open \(open)")
            XCTAssertLessThan(laying, open / 20, "★ closed while the engine lays")
            let firstOpen = levels[opens.firstIndex(where: { $0 >= 1 }) ?? 0]
            if red { XCTAssertGreaterThan(firstOpen, open * 8 / 10, "RED CONTROL: the whole part opened at the first floor"); continue }
            XCTAssertGreaterThanOrEqual(opens.filter { $0 >= 1 }.count, 3, "★ floor by floor")
            for (a, b) in zip(levels, levels.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a - open / 50, "★ more off at each floor") }
            XCTAssertLessThan(firstOpen, open * 2 / 3, "★ the first floor: the rest still closed")
            XCTAssertGreaterThan(open, laying + 500, "★ then open")
        }
    }

    // MARK: the cursor, the counter, the page

    /// ★ The poll's cursor is ONE, shared with Organic's growth (LatticeGrowthPoller): lay numbers, read-again, the phase.
    func testTheCursorIsSharedWithOrganicsPoll() {
        var c = LatticeTapCursor(baseline: 3)
        XCTAssertEqual(c.take(lay: 3, phase: 1, next: 5, from: 0), .init(), "the lay before the watch: nothing")
        XCTAssertEqual(c.take(lay: 4, phase: 1, next: 5, from: 2).readAgain, true, "a new lay seen part-way: read again")
        XCTAssertEqual(c.take(lay: 4, phase: 1, next: 5, from: 0), .init(restart: false, take: true, phase: 1))
        c.landed(4)
        XCTAssertEqual(c.take(lay: 4, phase: 2, next: 9, from: 5), .init(), "landed: nothing more of it")
        var g = LatticeGrowthPoller(baseline: 0)
        let s = g.take(LatticeLayoutSession.Growth(lay: 1, phase: 1, next: 1, xyz: [0, 0, 0, 1, 1, 1], region: [1]), from: 0)
        XCTAssertTrue(s.restart); XCTAssertEqual(s.xyz.count, 6); XCTAssertEqual(g.next, 1); XCTAssertEqual(g.phase, 1)
    }

    /// ★ The in-app counter (scope §3.2): a strut handed over that is not in the finished lattice bit for bit is counted (and
    /// logged); expected 0. RED CONTROL: a fake engine that hands over a strut the lattice does not hold — counted.
    func testTheInAppCounterCountsAStrutMissingFromTheLanding() throws {
        let (bars, flags) = Self.lattice()
        for red in [false, true] {
            let fake = FakeStrutEngine(bars: bars, flags: flags, cellsS: 0.01, layS: 0.02)
            fake.handOneThatMoves = red
            fake.clock = { 0 }
            fake.streamNextLay(up: SIMD3(0, 0, 1), map: nil)
            fake.clock = { 5 }
            let s = LatticeStrutStream()
            s.reset()
            s.take(try fake.strutRead(from: 0, most: 0, mapFrom: 0))
            XCTAssertEqual(s.count, fake.wholeCount)
            XCTAssertEqual(s.missing(from: bars), red ? 1 : 0, red ? "RED CONTROL: the moved strut counted" : "★ none missing")
        }
    }

    /// ★ The page: a regular lay on his part's page asks its session to stream (the view's up, X-ray: no map), reads the struts
    /// as it lays, and at the landing every strut it handed over is in the finished lattice (the counter: 0); the lay is the
    /// same as unstreamed (the print file's). RED CONTROL: a tap handing over a strut the lattice does not hold — counted.
    func testThePageStreamsARegularLayAndKeepsEveryStrut() async throws {
        let p = try FlexiblePressFixtures.cube60Project()
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.wholePart = true
        p.lattice.enabled = true
        let first = LatticeLayoutPreview()
        first.update(project: p, on: true, solid: false)
        try await settle(first)
        let reference = try XCTUnwrap(first.bars)
        first.clear()
        for red in [false, true] {
            var fake: FakeStrutEngine?
            LatticeLayoutPreview.strutTapForTesting = { _ in
                let f = FakeStrutEngine(bars: reference.bars, flags: reference.flags, cellsS: 0.001, layS: 0.002)
                f.handOneThatMoves = red
                fake = f
                return f
            }
            let before = LatticeLayoutPreview.streamMissingTotal
            let preview = LatticeLayoutPreview()
            defer { preview.clear() }
            preview.update(project: p, on: true, solid: false)
            try await settle(preview)
            let landed = try XCTUnwrap(preview.bars)
            XCTAssertEqual(landed.bars, reference.bars, "★ the same lattice, streamed or not")
            let f = try XCTUnwrap(fake, "the page asked its session for the tap")
            XCTAssertNotNil(f.asked, "★ the lay asked to stream")
            XCTAssertGreaterThan(preview.build.stream.count, 0, "★ struts read while it laid")
            let missing = LatticeLayoutPreview.streamMissingTotal - before
            if red { XCTAssertEqual(missing, 1, "RED CONTROL: the strut the lattice does not hold, counted"); continue }
            XCTAssertEqual(missing, 0, "★ every strut handed over is in the finished lattice")
            XCTAssertEqual(preview.build.token, landed.token, "★ its timelapse builds it")
        }
    }

    // MARK: the real engine (D-core's StrutTap through the bridge)

    /// ★ The REAL engine, end to end through the page's own tap (LatticeSessionStrutTap): a stand-like part with a lattice zone
    /// through it (its lattice held by the solid round it), laid with the stream on and its map made in the lay — struts are
    /// handed over before the landing, every one of them in the finished lattice bit for bit (the app's counter and core's
    /// own), the plan's up the one asked, the map handed over, and the lay the very one laid without the stream (the print
    /// file's). RED CONTROL `controlNoStream`: the engine never asked — nothing handed over.
    func testTheRealEngineHandsOverStrutsThatAreAllInTheFinishedLattice() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notes30-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent("stand.stl").path
        try Notes29AnimationClipsProbe.standSTL().write(to: URL(fileURLWithPath: path))
        let im = try TopOptKit.importMesh(path: path)
        let session = try await LatticeLayoutSession.open(path: path)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.topology = "bccz"; s.algorithm = "uniform"; s.cellMM = 10; s.cellMaxMM = 10
        var z = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
        z.zone = .init(kind: .box, centre: SIMD3(60, 22.5, 29), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                       half: SIMD3(32, 30, 21))
        s.regions = [z]
        let plain = try await session.lay(s)
        let g = LatticeLayoutPreview.mapGeometry(try XCTUnwrap(LatticeLayoutPreview.box(im.vertices)))
        for red in [false, true] {
            LatticeLayoutPreview.controlNoStream = red
            let tap = LatticeLayoutPreview.strutTap(session)
            if red { XCTAssertNil(tap, "RED CONTROL: no tap — the lay lands whole"); continue }
            let t = try XCTUnwrap(tap)
            let stream = LatticeStrutStream()
            stream.reset(map: g)
            var cursor = LatticeTapCursor(baseline: try t.strutRead(from: Int.max, most: 1, mapFrom: Int.max).lay)
            t.streamNextLay(up: SIMD3(0, 0, 1), map: g)
            let lay = Task { try await session.lay(s) }
            var mapNext = 0, beforeLanding = 0, last = false
            while true {
                let from = cursor.next
                let rd = try t.strutRead(from: from, most: 0, mapFrom: mapNext)
                let st = cursor.take(lay: rd.lay, phase: rd.phase, next: rd.next, from: from)
                if st.take {
                    stream.take(rd); mapNext = rd.mapNext
                    if rd.phase < 4 { beforeLanding = stream.bars.count / 7 }
                }
                if last { break }
                if st.take, rd.phase >= 4 { last = true; continue }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let r = try await lay.value
            print("REAL: \(r.barCount) bars; \(stream.bars.count / 7) handed over (\(beforeLanding) before the landing); core streamed \(r.streamed), missing \(r.streamedMissing); map \(r.map.count) bytes")
            XCTAssertEqual(r.bars, plain.bars, "★ the same lattice, streamed or not (the print file's)")
            XCTAssertEqual(r.barFlags, plain.barFlags)
            XCTAssertGreaterThan(stream.bars.count / 7, r.barCount / 2, "★ most of the struts handed over")
            XCTAssertGreaterThan(beforeLanding, 0, "★ handed over before the landing")
            XCTAssertEqual(stream.missing(from: r.bars), 0, "★ every strut handed over is in the finished lattice (the app's count)")
            XCTAssertEqual(r.streamedMissing, 0, "★ … and core's own")
            XCTAssertEqual(r.streamed, stream.bars.count / 7, "every strut core handed over was read")
            let up = try XCTUnwrap(stream.plan?.up)
            XCTAssertEqual(up.z, 1, accuracy: 1e-5, "the plan's up is the one asked")
            XCTAssertTrue(stream.mapAllMade, "★ the map handed over with the stream")
            XCTAssertEqual(r.map.count, 2 * Int(g.dims.x) * Int(g.dims.y) * Int(g.dims.z), "the map made in the lay")
            let after = try await session.grid(origin: g.origin, voxel: g.voxel, dims: g.dims)
            XCTAssertEqual(r.map, after.rg, "★ the lay's map is lattice_layout_grid's")
            XCTAssertEqual(stream.map?.rg, after.rg, "★ … and the stream's")
        }
        LatticeLayoutPreview.controlNoStream = false
    }

    private func settle(_ preview: LatticeLayoutPreview) async throws {
        let end = Date().addingTimeInterval(300)
        while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(preview.laying, "the lay ended")
    }
}
#endif
