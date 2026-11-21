// FlexibleGroupPaletteTests — the squeeze groups' colour palette for groups 5 and up (task
// 2026-09-29-flexible-screens, round 5 batch C5). His answer (2026-09-30) to "The design system has
// only four group colours that aren't purple. What should groups 5 and up do?": "Add more colour
// tokens". The palette is EIGHT DS tokens (DS.Color.squeezeGroupPalette), never purple; beyond it the
// colours cycle and the group's NUMBER shows on its rail tab and on its faces.
//
// ★ THE NUMBERS ARE COMPUTED, NEVER EYEBALLED (the data-viz method's checks): ΔE is the Euclidean
// distance in OKLab × 100 (Björn Ottosson's OKLab); colour blindness is Machado, Oliveira &
// Fernandes 2009 at severity 1.0 (protanopia, deuteranopia); contrast is WCAG 2.x. The floors:
//   * every PAIR of group colours ≥ 15 for normal vision and ≥ 8 under protan / deutan — ALL pairs,
//     not only neighbours: any two groups' faces can sit side by side on the part;
//   * each colour ≥ 4.5 : 1 on the stage's background and ≥ 3 : 1 on the frame's near-black gap;
//     the badge's dark number ≥ 4.5 : 1 on every colour;
//   * ≥ 15 from what the pages already MEAN: the warning amber (Fix N things, the fix pop-up, a
//     group's miss), the danger red (a refused face, a point's ×), the resting faces' cyan, the
//     selected face's white, the depth prism's purple;
//   * groups 2 and 3 (the common ones) ≥ 12 from the dent heat's rainbow (D-R5-M1) — S's orange
//     and red sat ON it (1.7 and 0.7: red IS the reddest dent).
// Every comparison has a RED control that runs the same instrument on round 5 S's palette (or a
// colour that must fail) and shows it failing.
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleGroupPaletteTests: XCTestCase {

    // MARK: - the instruments (pure)

    enum CVD { case protan, deutan }
    // Machado, Oliveira & Fernandes (2009), severity 1.0, on LINEAR sRGB
    static let protan: [[Double]] = [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
    static let deutan: [[Double]] = [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]

    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func linear(_ c: RGBA) -> SIMD3<Double> { SIMD3(linear(c.r), linear(c.g), linear(c.b)) }
    static func oklab(_ l: SIMD3<Double>) -> SIMD3<Double> {
        let lc = cbrt(0.4122214708 * l.x + 0.5363325363 * l.y + 0.0514459929 * l.z)
        let mc = cbrt(0.2119034982 * l.x + 0.6806995451 * l.y + 0.1073969566 * l.z)
        let sc = cbrt(0.0883024619 * l.x + 0.2817188376 * l.y + 0.6299787005 * l.z)
        return SIMD3(0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc,
                     1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc,
                     0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc)
    }
    static func simulate(_ l: SIMD3<Double>, _ m: [[Double]]) -> SIMD3<Double> {
        func c(_ v: Double) -> Double { max(0, min(1, v)) }
        return SIMD3(c(m[0][0] * l.x + m[0][1] * l.y + m[0][2] * l.z),
                     c(m[1][0] * l.x + m[1][1] * l.y + m[1][2] * l.z),
                     c(m[2][0] * l.x + m[2][1] * l.y + m[2][2] * l.z))
    }
    /// OKLab ΔE × 100, normal vision (cvd nil) or simulated.
    static func dE(_ a: RGBA, _ b: RGBA, _ cvd: CVD? = nil) -> Double {
        var la = linear(a), lb = linear(b)
        if let cvd { let m = cvd == .protan ? protan : deutan; la = simulate(la, m); lb = simulate(lb, m) }
        return 100 * simd_distance(oklab(la), oklab(lb))
    }
    static func cvd(_ a: RGBA, _ b: RGBA) -> Double { min(dE(a, b, .protan), dE(a, b, .deutan)) }
    static func luminance(_ c: RGBA) -> Double { let l = linear(c); return 0.2126 * l.x + 0.7152 * l.y + 0.0722 * l.z }
    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    /// Worst ΔE over ALL pairs (normal, colour-blind) and the pair.
    static func worstPairs(_ p: [RGBA]) -> (normal: Double, cvd: Double, normalPair: (Int, Int), cvdPair: (Int, Int)) {
        var n = Double.infinity, c = Double.infinity, np = (0, 0), cp = (0, 0)
        for i in p.indices { for j in p.indices where j > i {
            let a = dE(p[i], p[j]), b = cvd(p[i], p[j])
            if a < n { n = a; np = (i + 1, j + 1) }
            if b < c { c = b; cp = (i + 1, j + 1) }
        } }
        return (n, c, np, cp)
    }
    /// The dent heat's ramp (D-R5-M1: the FEA rainbow on both pages), sampled finely.
    static let heat: [RGBA] = (0...200).map { ResultsModel.stressColor(fraction: Double($0) / 200) }
    static func toHeat(_ c: RGBA) -> Double { heat.map { dE(c, $0) }.min() ?? 0 }
    /// Purple, stricter than the page's instrument (250–330°): no hue from 235° to 340° (indigo,
    /// violet, magenta) unless it is grey.
    static func purplish(_ c: RGBA) -> Bool {
        let (h, s) = FlexibleShownValuesTests.hueSat(c)
        return s > 0.15 && h >= 235 && h <= 340
    }

    /// Round 5 S's palette — every RED control runs on it.
    static let roundFiveS: [RGBA] = [DS.Color.accentGreen, DS.Color.warning, DS.Color.danger, DS.Color.accent]

    // MARK: - the palette

    func testThePaletteIsEightDSTokensInAFixedOrderNeverPurple() {
        let p = FlexibleSqueezeGroups.palette
        XCTAssertGreaterThanOrEqual(p.count, 8, "at least eight colours (his: add more colour tokens)")
        XCTAssertEqual(p, DS.Color.squeezeGroupPalette, "every colour is a DS token, in the design system's own order")
        XCTAssertEqual(p, FlexibleGroupColour.allCases.map(\.rgba), "the swatches are the palette, in order")
        XCTAssertEqual(Set(p.map { "\($0.r)|\($0.g)|\($0.b)" }).count, p.count, "no colour twice")
        XCTAssertEqual(p[0], DS.Color.accentGreen, "group 1 keeps the pressed faces' green")
        XCTAssertEqual(p[3], DS.Color.accent, "group 4 keeps its blue (round 5 S)")
        for (i, c) in p.enumerated() {
            XCTAssertFalse(FlexibleShownValuesTests.isPurple(c), "slot \(i + 1) is never purple (the page's instrument)")
            XCTAssertFalse(Self.purplish(c), "slot \(i + 1): no violet / indigo / magenta either")
        }
        for n in 1...24 { XCTAssertFalse(Self.purplish(FlexibleSqueezeGroups.colour(number: n)), "group \(n)") }
        // ★ RED CONTROLS: both instruments see the DS purple; the stricter one sees indigo too
        XCTAssertTrue(FlexibleShownValuesTests.isPurple(DS.Color.accentPurple), "control: the page's instrument sees purple")
        XCTAssertTrue(Self.purplish(RGBA(hex: 0x5E5CE6)), "control: the stricter instrument sees indigo (#5E5CE6)")
        XCTAssertLessThan(Self.roundFiveS.count, 8, "control: round 5 S had four")
    }

    func testEveryPairIsTellableApartForEveryoneAndUnderColourBlindness() {
        let p = FlexibleSqueezeGroups.palette
        let w = Self.worstPairs(p)
        print(String(format: "FLEX-C5 palette all pairs: worst normal ΔE %.1f (groups %d–%d) · worst protan/deutan ΔE %.1f (groups %d–%d)",
                     w.normal, w.normalPair.0, w.normalPair.1, w.cvd, w.cvdPair.0, w.cvdPair.1))
        XCTAssertGreaterThanOrEqual(w.normal, 15, "every pair tellable apart (normal vision)")
        XCTAssertGreaterThanOrEqual(w.cvd, 8, "every pair tellable apart under protanopia and deuteranopia")
        // the first four (most parts have at most four groups): ≥ 10 for a colour-blind reader
        let w4 = Self.worstPairs(Array(p.prefix(4)))
        XCTAssertGreaterThanOrEqual(w4.cvd, 10, "the first four: apart for a colour-blind reader too")
        // ★ RED CONTROL: the same instrument fails round 5 S's four (green vs orange under deuteranopia)
        let s = Self.worstPairs(Self.roundFiveS)
        print(String(format: "FLEX-C5 control (round 5 S): worst normal ΔE %.1f · worst protan/deutan ΔE %.1f (groups %d–%d)",
                     s.normal, s.cvd, s.cvdPair.0, s.cvdPair.1))
        XCTAssertLessThan(s.cvd, 8, "control: S's green and orange collapse for a colour-blind reader")
        XCTAssertLessThan(s.cvd, 10, "control: …and fail the first-four bar")
        // ★ RED CONTROL: a near-twin is caught (the DS's success green IS group 1's green)
        XCTAssertLessThan(Self.worstPairs(p + [DS.Color.okGreen]).normal, 15, "control: a twin of group 1 fails")
    }

    func testEveryColourReadsOnTheDarkStageAndUnderItsNumber() {
        var lines: [String] = []
        for (i, c) in FlexibleSqueezeGroups.palette.enumerated() {
            let bg = Self.contrast(c, DS.Color.background), gap = Self.contrast(c, DS.Color.chipSolid)
            let ink = Self.contrast(c, FlexibleGroupNumbers.ink)
            lines.append(String(format: "%d %@ bg %.1f gap %.1f number %.1f", i + 1, FlexibleGroupColour.allCases[i].name, bg, gap, ink))
            XCTAssertGreaterThanOrEqual(bg, 4.5, "slot \(i + 1) reads on the stage")
            XCTAssertGreaterThanOrEqual(gap, 3, "slot \(i + 1) reads against the frame's near-black gap")
            XCTAssertGreaterThanOrEqual(ink, 4.5, "slot \(i + 1): its number is readable on it")
        }
        print("FLEX-C5 contrast: " + lines.joined(separator: " · "))
        // ★ RED CONTROL: the stage-navigation blue sinks into the stage (2.0 : 1)
        XCTAssertLessThan(Self.contrast(DS.Color.accentDeep, DS.Color.background), 4.5, "control: accentDeep fails")
    }

    func testNoGroupColourIsAWarningARefusalTheRestsTheSelectionOrTheHeat() {
        let meanings: [(String, RGBA)] = [("warning amber", DS.Color.warning), ("danger red", DS.Color.danger),
                                          ("resting cyan", DS.Color.accentCyan), ("selected white", DS.Color.textPrimary),
                                          ("depth-prism purple", DS.Color.accentPurple)]
        var lines: [String] = []
        for (i, c) in FlexibleSqueezeGroups.palette.enumerated() {
            let near = meanings.map { ($0.0, Self.dE(c, $0.1)) }.min { $0.1 < $1.1 }!
            lines.append(String(format: "%d %@ nearest %@ %.1f heat %.1f", i + 1, FlexibleGroupColour.allCases[i].name, near.0, near.1, Self.toHeat(c)))
            for (name, m) in meanings {
                XCTAssertGreaterThanOrEqual(Self.dE(c, m), 15, "slot \(i + 1) is not the \(name)")
            }
        }
        print("FLEX-C5 meanings: " + lines.joined(separator: " · "))
        // groups 2 and 3 — the ones S had as orange and red — sit OFF the dent heat
        for n in [2, 3] {
            XCTAssertGreaterThanOrEqual(Self.toHeat(FlexibleSqueezeGroups.colour(number: n)), 12, "group \(n) is not a heat colour")
        }
        // ★ RED CONTROLS: S's orange and red ARE the warning and the danger token, and lie on the heat
        XCTAssertLessThan(Self.dE(Self.roundFiveS[1], DS.Color.warning), 15, "control: S's group 2 is the warning amber")
        XCTAssertLessThan(Self.dE(Self.roundFiveS[2], DS.Color.danger), 15, "control: S's group 3 is the danger red")
        XCTAssertLessThan(Self.toHeat(Self.roundFiveS[1]), 12, "control: S's orange is on the heat")
        XCTAssertLessThan(Self.toHeat(Self.roundFiveS[2]), 12, "control: S's red is the reddest dent")
        print(String(format: "FLEX-C5 control: S's orange → warning %.1f, heat %.1f · S's red → danger %.1f, heat %.1f",
                     Self.dE(Self.roundFiveS[1], DS.Color.warning), Self.toHeat(Self.roundFiveS[1]),
                     Self.dE(Self.roundFiveS[2], DS.Color.danger), Self.toHeat(Self.roundFiveS[2])))
    }

    // MARK: - round 5 S's stored picks

    /// S stored picks by name ("orange", "red"); those colours are gone. A stored name keeps its SLOT:
    /// orange (S's group 2 colour) is now group 2's pink, red (group 3's) group 3's mint — so a pick
    /// that differed from its number still differs, and one that matched still matches.
    func testRoundFiveSStoredNamesKeepTheirSlot() {
        XCTAssertEqual(FlexibleGroupColour.stored("orange"), .pink)
        XCTAssertEqual(FlexibleGroupColour.stored("red"), .mint)
        XCTAssertEqual(FlexibleGroupColour.stored("green"), .green)
        XCTAssertEqual(FlexibleGroupColour.stored("blue"), .blue)
        XCTAssertNil(FlexibleGroupColour.stored("violet"))
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        for r in [1, 2, 3] { s.setFace(FlexibleFaceSettings(faceRegionID: r)) }
        FlexibleSqueezeGroups.newGroup(with: 2, in: &s)
        FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
        // his S-era pick: group 1 red, group 3 green (a swap)
        s.groupColours = ["1": "red", "3": "green"]
        let gs = FlexibleSqueezeGroups.groups(s)
        XCTAssertEqual(gs.map { FlexibleSqueezeGroups.colourChoice(of: $0, in: s) }, [.mint, .pink, .green])
        XCTAssertEqual(Set(gs.map { FlexibleSqueezeGroups.colourChoice(of: $0, in: s) }).count, 3, "still three different colours")
        // re-picking group 2's own colour leaves the settings in normal form (an S-era "orange" for
        // group 2 is its number's own colour and drops out)
        var t = s
        t.groupColours = ["1": "red", "2": "orange", "3": "green"]
        FlexibleSqueezeGroups.setColour(.pink, group: gs[1].id, in: &t)
        XCTAssertEqual(t.groupColours, ["1": "mint", "3": "green"], "normal form, today's names")
        // ★ RED CONTROL: read with the plain raw value, S's "red" is lost and group 1 falls back to
        // its number's green — the same colour as group 3
        let plain = FlexibleGroupColour(rawValue: "red") ?? .byNumber(1)
        XCTAssertEqual(plain, FlexibleSqueezeGroups.colourChoice(of: gs[2], in: s), "control: two greens")
    }

    // MARK: - beyond the palette: cycle, and show the number

    func testBeyondTheEighthGroupTheColoursCycleAndTheNumberShowsWhereAColourIsShared() {
        func settings(_ n: Int) -> FlexibleStageSettings {
            var s = FlexibleStageSettings(materialID: "varioshore_tpu")
            for r in 1...n { s.setFace(FlexibleFaceSettings(faceRegionID: r)) }
            for r in 2...n { FlexibleSqueezeGroups.newGroup(with: r, in: &s) }
            return s
        }
        let eight = settings(8), nine = settings(9), ten = settings(10)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(eight).count, 8)
        XCTAssertEqual(Set(FlexibleSqueezeGroups.groups(eight).map { FlexibleSqueezeGroups.colourChoice(of: $0, in: eight) }).count, 8,
                       "eight groups, eight colours")
        XCTAssertEqual(FlexibleGroupNumbers.shared(in: eight), [], "every colour is its own: no numbers")
        XCTAssertEqual(FlexibleSqueezeGroups.colour(number: 9, in: nine), FlexibleSqueezeGroups.colour(number: 1, in: nine), "group 9 cycles to green")
        XCTAssertEqual(FlexibleGroupNumbers.shared(in: nine), [1, 9], "green is worn twice: groups 1 and 9 show their number")
        XCTAssertEqual(FlexibleGroupNumbers.shared(in: ten), [1, 2, 9, 10])
        // the rule keys on the COLOURS, not on a count: a stored pick that makes two groups share
        // (an old file; the page itself swaps) numbers them too
        var picked = settings(3)
        picked.groupColours = ["3": "green"]
        XCTAssertEqual(FlexibleGroupNumbers.shared(in: picked), [1, 3])
        // ★ RED CONTROL: a count rule ("number every group past the eighth") misses group 1 — the
        // other green — and numbers nothing on the 3-group file
        let countRule: (FlexibleStageSettings) -> Set<Int> = { s in Set(FlexibleSqueezeGroups.groups(s).map(\.number).filter { $0 > 8 }) }
        XCTAssertNotEqual(countRule(nine), FlexibleGroupNumbers.shared(in: nine), "control: the count rule leaves one green unnumbered")
        XCTAssertNotEqual(countRule(picked), FlexibleGroupNumbers.shared(in: picked), "control: …and misses the stored pick")
    }

    /// A synthetic face: `nu` × `nv` columns of 1 mm on z = 0, pressed along −Z (out of the face: +Z).
    static func face(_ nu: Int, _ nv: Int, xAxis: SIMD3<Double> = SIMD3(1, 0, 0), yAxis: SIMD3<Double> = SIMD3(0, 1, 0),
                     load: SIMD3<Double> = SIMD3(0, 0, -1)) -> FlexStackInfo {
        var grid = [Int](repeating: -1, count: nu * nv), cols: [FlexColumn] = []
        for v in 0..<nv { for u in 0..<nu {
            grid[v * nu + u] = cols.count
            cols.append(FlexColumn(iu: u, iv: v, uMM: Double(u) + 0.5, vMM: Double(v) + 0.5, areaMM2: 1,
                                   entryT: 0, exitT: 10, latticeMM: 10, exitFace: 0))
        } }
        return FlexStackInfo(frameValid: true, frameReason: "", load: load, xAxis: xAxis, yAxis: yAxis, centroid: .zero,
                             rotationDeg: 0, uMin: 0, vMin: 0, uExtentMM: Double(nu), vExtentMM: Double(nv),
                             areaMM2: Double(nu * nv), projectedAreaMM2: Double(nu * nv), normalSpreadDeg: 0,
                             normalSpreadFlag: false, buildAngleDeg: 0, side: false, principalAxisTied: false, pitchMM: 1,
                             nu: nu, nv: nv, cell: grid, columns: cols, exitFaces: [], exitRegions: [], exitUnresolvedFraction: 0,
                             footprintAreaMM2: Double(nu * nv), latticedColumns: nu * nv, latticeMMMin: 10, latticeMMMean: 10,
                             latticeMMMax: 10, stackMMMax: 10)
    }

    /// The glyph a plate shows to someone OUTSIDE the face (+Z) with +V up and +U to the right.
    static func readBack(_ cells: [Int: Bool], _ st: FlexStackInfo) -> [[Bool]] {
        let us = cells.keys.map { st.columns[$0].iu }, vs = cells.keys.map { st.columns[$0].iv }
        let u0 = us.min()! + 1, vTop = vs.max()! - 1, w = us.max()! - us.min()! - 1
        return (0..<5).map { fy in (0..<w).map { fx in cells[st.column(u0 + fx, vTop - fy)] ?? false } }
    }

    /// The number is PAINTED on the face's heat — upright, read from outside, clear of the frame and its
    /// gap, where the map squishes least — and a face too small for it stays unnumbered.
    func testTheNumberIsPaintedUprightOnTheHeatWhereTheFaceSquishesLeast() throws {
        let st = Self.face(30, 20)
        // up = +V laid into the face; right = up × out = +U (read from outside, +Z)
        let ax = FlexibleGroupNumbers.axes(st, up: SIMD3(0, 1, 0), fallback: SIMD3(1, 0, 0))
        XCTAssertEqual(ax.right, .init(du: 1, dv: 0)); XCTAssertEqual(ax.up, .init(du: 0, dv: 1))
        // a top face (up is its normal): the fallback lays the up
        let top = FlexibleGroupNumbers.axes(st, up: SIMD3(0, 0, 1), fallback: SIMD3(-1, 0, 0))
        XCTAssertEqual(top.up, .init(du: -1, dv: 0)); XCTAssertEqual(top.right, .init(du: 0, dv: 1), "right = up × out")
        // a dome: deepest at the face's middle
        let squish = st.columns.map { c -> Double in
            let du = (c.uMM - 15) / 15, dv = (c.vMM - 10) / 10
            return max(0, 1 - du * du - dv * dv)
        }
        let plate = try XCTUnwrap(FlexibleGroupNumbers.plate(9, st, right: ax.right, up: ax.up, squish: squish))
        XCTAssertEqual(Self.readBack(plate, st), FlexibleGroupNumbers.bitmap(9), "a 9, upright, read from outside")
        XCTAssertEqual(plate.count, 5 * 7, "the digit (3 × 5) and its one-pixel plate")
        let depth = FlexibleGroupFrames.distances(st)
        let clear = FlexibleGroupFrames.width(nu: 30, nv: 20) + 1   // the frame and its gap (20 columns: a gap)
        XCTAssertTrue(plate.keys.allSatisfy { depth[$0] > clear }, "wholly on the heat: never on the frame or its gap")
        let under = plate.keys.map { squish[$0] }.reduce(0, +) / Double(plate.count)
        let mean = squish.reduce(0, +) / Double(squish.count)
        let peak = squish.indices.max { squish[$0] < squish[$1] }!
        XCTAssertNil(plate[peak], "never over the dent's peak")
        XCTAssertLessThan(under, mean, "over the dull part of the map (mean squish under it \(under) vs the face's \(mean))")
        print(String(format: "FLEX-C5 plate: 9 at u %d–%d v %d–%d · squish under it %.3f vs the face's mean %.3f",
                     plate.keys.map { st.columns[$0].iu }.min()!, plate.keys.map { st.columns[$0].iu }.max()!,
                     plate.keys.map { st.columns[$0].iv }.min()!, plate.keys.map { st.columns[$0].iv }.max()!, under, mean))
        // two digits; a bigger face takes a bigger scale
        XCTAssertEqual(Self.readBack(try XCTUnwrap(FlexibleGroupNumbers.plate(12, st, right: ax.right, up: ax.up, squish: nil)), st),
                       FlexibleGroupNumbers.bitmap(12))
        let big = Self.face(80, 60)
        let bigPlate = try XCTUnwrap(FlexibleGroupNumbers.plate(9, big, right: ax.right, up: ax.up, squish: nil))
        XCTAssertEqual(bigPlate.count, (3 * 2 + 4) * (5 * 2 + 4), "60 columns across: two columns per font pixel")
        // too small: a 6 × 6 face has no 5 × 7 of heat
        XCTAssertNil(FlexibleGroupNumbers.plate(9, Self.face(6, 6), right: ax.right, up: ax.up, squish: nil))
        // ★ RED CONTROLS: the read-back sees a mirror (right = out × up) and an upside-down plate
        let mirrored = try XCTUnwrap(FlexibleGroupNumbers.plate(9, st, right: .init(du: -1, dv: 0), up: ax.up, squish: squish))
        XCTAssertNotEqual(Self.readBack(mirrored, st), FlexibleGroupNumbers.bitmap(9), "control: a mirrored 9")
        let flipped = try XCTUnwrap(FlexibleGroupNumbers.plate(9, st, right: .init(du: -1, dv: 0), up: .init(du: 0, dv: -1), squish: squish))
        XCTAssertNotEqual(Self.readBack(flipped, st), FlexibleGroupNumbers.bitmap(9), "control: an upside-down 9")
        // ★ RED CONTROL: placed with no regard to the map, the plate lands nearer the peak
        let blind = try XCTUnwrap(FlexibleGroupNumbers.plate(9, st, right: ax.right, up: ax.up, squish: nil))
        let blindUnder = blind.keys.map { squish[$0] }.reduce(0, +) / Double(blind.count)
        XCTAssertGreaterThan(blindUnder, under, "control: the middle squishes more (\(blindUnder))")
    }
}
