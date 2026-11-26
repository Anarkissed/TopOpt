// Notes29AnimationTests — ★ his notes on release 20 (2026-11-25, img 97: a regular lattice half-drawn during a refresh, loose
// vertical struts over the bare part):
//   "We need to think of an animation to implement so we never have to deal with images like this. Make it like the organic
//    lattice, but make it feel like it is being *built* … hard stops and starts, not organic growth … Even though the lattice is
//    built in usually a second, let the animation run for at least 5 seconds."
//   "Add a setting in the main menu settings to 'Skip all animations' which will turn off ALL animations and allow for a blank
//    screen with a 'Refreshing Lattice' notification and progress bar. Let it run at the real speed of the refresh."
//   "add a couple more seconds to the organic animations — the end always feels too rushed."
// ★ and his review of the first clips (img 98): "None of the parts' walls open up, I can't see through the part to the other
//   side and no shading exists. Try again. I think the perfect amount is about 6-8 seconds for the build, total … As for
//   organic … let's do 8 seconds for the entire animation." — and, the clips seen, HIS PICK: "Let's go with 7 seconds for ALL
//   animations. It looks great!"
// Each with its RED CONTROL (the picture before): `LatticeBuildShow.controlOff` (no timelapse: the last lattice and its map
// stay mid-lay and the struts can land before their own map), `AppSettings.skipAllAnimations` off,
// `LatticeGrowthReplay.endAsRelease20`.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes29AnimationTests: XCTestCase {

    override func tearDown() {
        LatticeBuildShow.clockForTesting = nil
        LatticeBuildShow.controlOff = false
        AppSettings.skipAllAnimations = false
        LatticeGrowthReplay.endAsRelease20(false)
        MeshRenderer.growthClockForTesting = nil
        FlexibleSaid.recording = false
        super.tearDown()
    }

    // MARK: the timelapse's clock

    /// ★ His total ("about 6-8 seconds for the build, total": 6, 7 and 8 rendered for his pick) from the ask to the finished
    /// lay, whatever the lay took; a lay nothing of which streamed is covered by the closed site and its floors still come in
    /// full (at least `buildLeastS`) after it lands; nothing of it shows before it lands; ★ notes30: floor by floor — in the solid
    /// view each floor's walls first, then its columns and bays — in HARD snaps (each one more, all at once, a beat between
    /// floors), ending on the whole.
    func testTheTimelapseLastsHisTotalAndEndsOnTheFinishedLay() {
        typealias T = LatticeBuildTimelapse
        defer { T.totalS = T.hisTotalS }
        for total in T.totalChoicesS { T.totalS = total
        for layS in [0.2, 1.0, 1.2, 3.0, 4.5, 9.0] {
            for floors in [T.floorsLeast, 5, T.floorsMost] { for walls in [false, true] {
                var tl = T(start: 100, walls: walls)
                tl.floorsUnframed = floors
                for k in 0..<40 {
                    let t = 100 + Double(k) * layS / 40
                    tl.advance(to: t)
                    XCTAssertNil(tl.shown(at: t), "★ nothing of the lay before it lands")
                }
                tl.land(at: 100 + layS)
                let end = try! XCTUnwrap(tl.end)
                XCTAssertGreaterThanOrEqual(end - 100, total - 1e-9, "★ at least \(total) s (lay \(layS) s)")
                tl.advance(to: end)
                let snaps = tl.snapTimes
                XCTAssertEqual(snaps.count, floors * tl.snapsPerFloor, "every floor's snaps")
                XCTAssertGreaterThanOrEqual(snaps.first ?? 0, 100 + layS - 1e-9, "the first snap only after the lay lands")
                XCTAssertGreaterThanOrEqual(end - (snaps.first ?? end), T.buildLeastS + T.toppedOutS - 1e-6, "★ a late lay still rises in full")
                if Swift.max(layS, T.siteLeastS) + T.buildLeastS + T.toppedOutS <= total {
                    XCTAssertEqual(end - 100, total, accuracy: 1e-9, "★ a quick lay: exactly his total")
                }
                // the first snap: the lowest floor's walls (the solid view), else its columns
                let first = try! XCTUnwrap(tl.shown(at: snaps[0]))
                XCTAssertEqual(first.opened, walls ? 1 : 0)
                XCTAssertEqual(first.snaps, walls ? 0 : 1, walls ? "★ the walls before the columns" : "the columns first")
                // sampled every millisecond: one step at a time, at once (no in-between), then stillness
                var last: [Int]? = nil, changes = 0
                var t = 100.0
                while t <= end + 0.01 {
                    let s = tl.shown(at: t)
                    let now = s.map { [$0.opened, $0.snaps] }
                    if now != last {
                        if let l = last, let n = now {
                            XCTAssertEqual((n[0] - l[0]) + (n[1] - l[1]), 1, "★ a hard snap: one step at a time, never a fade (t \(t))")
                        }
                        changes += 1; last = now
                    }
                    t += 0.001
                }
                XCTAssertEqual(last, [walls ? floors : 0, floors * T.perFloor], "★ it ends on the whole lattice")
                XCTAssertEqual(changes, snaps.count, "every snap seen")
                XCTAssertTrue(tl.done(at: end), "over at its end")
                let gaps = zip(snaps.dropFirst(), snaps).map { $0 - $1 }
                XCTAssertGreaterThan(gaps.max() ?? 0, (gaps.min() ?? 0) * 1.5, "★ hard stops: a beat of stillness between floors")
                XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, 1.0 / 30 - 1e-6, "every snap its own frame at 30 fps")
            }}
        }
        }
        XCTAssertEqual(T.floors(heightMM: 85), 6)
        XCTAssertEqual(T.floors(heightMM: 40), 4)
        XCTAssertEqual(T.floors(heightMM: 12), T.floorsLeast)
        XCTAssertEqual(T.floors(heightMM: 400), T.floorsMost)
    }

    // MARK: the renderer: never a partial lattice mid-lay

    static let cubeV: [Float] = [0, 0, 0, 40, 0, 0, 40, 40, 0, 0, 40, 0, 0, 0, 40, 40, 0, 40, 40, 40, 40, 0, 40, 40]
    static let cubeI: [Int32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6,
                                 1, 6, 5]

    /// A frame of struts in the 40 mm cube: columns (along the part's z, its up once stood Z-up) and beams (x), every `cell` mm.
    static func frameBars(cell: Float, width: Float = 1.2) -> [Float] {
        var out: [Float] = []
        let n = Int(36 / cell)
        for i in 0...n { for j in 0...n { for k in 0..<n {
            let x = 2 + Float(i) * cell, y = 2 + Float(j) * cell, z = 2 + Float(k) * cell
            out += [x, y, z, x, y, z + cell, width]                              // a column
            if i < n { out += [x, y, z + cell, x + cell, y, z + cell, width] }   // a beam
        }}}
        return out
    }

    /// The pixels the lattice's purple covers (the bars' colour, lit).
    static func purple(_ f: [UInt8]) -> Int {
        stride(from: 0, to: f.count, by: 4).filter { Int(f[$0]) > Int(f[$0 + 1]) + 25 && f[$0] > 70 }.count
    }

    /// ★ img 97 made impossible: from the moment the lay is asked for until it lands, NO strut is drawn (neither the last
    /// lattice nor any of the new one); the new struts are only ever drawn with their own map; then they come floor by floor,
    /// each snap exactly the struts the shader's rule puts up to it, ending on the whole lattice. RED CONTROL (no timelapse):
    /// the last lattice stays on screen mid-lay, and the new one is drawn whole at once.
    func testNoPartialLatticeIsEverDrawnMidLay() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(ViewerMesh(vertices: Self.cubeV, indices: Self.cubeI, faceIDs: [Int32](repeating: 1, count: Self.cubeI.count / 3)))
        r.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
        r.beginSettle(to: LatticeSampleView.settleZUp, duration: 0)
        r.camera.setOrientation(azimuth: -0.6, elevation: 0.45)
        let (w, h) = (480, 360)
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        func frame() throws -> [UInt8] { try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: clear, stage: false)) }
        let oldBars = Self.frameBars(cell: 12), newBars = Self.frameBars(cell: 6)
        let old = LatticeLayoutBarsInputs(token: 1, bars: oldBars), new = LatticeLayoutBarsInputs(token: 2, bars: newBars)
        // the whole new lattice, as a reference
        r.applyLayoutBars(new, device: device)
        let whole = Self.purple(try frame())
        XCTAssertGreaterThan(whole, 2_000, "premise: the new lattice drawn whole")
        for red in [false, true] {
            LatticeBuildShow.controlOff = red
            let show = LatticeBuildShow()
            r.applyBuildShow(show)
            r.applyLayoutBars(old, device: device)
            let t0 = CACurrentMediaTime() + 1000
            LatticeBuildShow.clockForTesting = t0
            let before = Self.purple(try frame())
            XCTAssertGreaterThan(before, 1_000, "premise: the last lattice on screen")
            show.layBegins(now: t0)
            var midLay: [Int] = []
            for k in 0..<6 {   // the engine laying for 1.2 s
                LatticeBuildShow.clockForTesting = t0 + Double(k) * 0.2
                midLay.append(Self.purple(try frame()))
            }
            let land = t0 + 1.2
            LatticeBuildShow.clockForTesting = land
            r.applyLayoutBars(new, device: device)
            show.landed(token: 2, now: land)
            if red {
                XCTAssertGreaterThan(midLay.min() ?? 0, 1_000, "RED CONTROL: the last lattice stays on screen while the engine lays")
                XCTAssertEqual(Double(Self.purple(try frame())), Double(whole), accuracy: Double(whole) / 50, "RED CONTROL: the new one whole at once")
                continue
            }
            XCTAssertEqual(midLay, [Int](repeating: 0, count: 6), "★ no strut drawn while the engine lays")
            XCTAssertEqual(r.lastBuildSnaps, 0)
            // the frame rising: sampled every 1/30 s to the end
            let tl = try XCTUnwrap(show.timelapse), end = try XCTUnwrap(tl.end)
            var t = land, seen: [Int] = [], counts: [Int] = []
            _ = try frame()
            let fr = try XCTUnwrap(r.lastBuildFrame, "the renderer put the struts on floors")
            XCTAssertGreaterThan(abs(fr.up.z), 0.99, "the part stood Z-up: its floors along its z")
            let steps = stride(from: 0, to: newBars.count, by: 7).map { i in
                LatticeBuildTimelapse.step(SIMD3(newBars[i], newBars[i + 1], newBars[i + 2]), SIMD3(newBars[i + 3], newBars[i + 4], newBars[i + 5]), fr)
            }
            XCTAssertEqual(Set(steps.filter { $0 % LatticeBuildTimelapse.perFloor == 0 }).count, fr.floors, "every floor has its columns")
            while t < end + 0.5 {
                LatticeBuildShow.clockForTesting = t
                let px = Self.purple(try frame())
                if let n = r.lastBuildSnaps, n > 0 {
                    XCTAssertEqual(r.layoutBars?.token, 2, "only the landed lay's struts")
                    if seen.last != n { seen.append(n); counts.append(px) }
                } else if r.lastBuildSnaps == nil {
                    if seen.last != Int.max { seen.append(.max); counts.append(px) }
                }
                t += 1.0 / 30
            }
            print("TIMELAPSE: \(fr.floors) floors; snaps seen \(seen.count); purple per snap \(counts); whole \(whole)")
            XCTAssertEqual(seen.last, .max, "★ it ends on the whole lattice")
            XCTAssertEqual(Double(counts.last ?? 0), Double(whole), accuracy: Double(whole) / 50, "★ the finished lay, every strut")
            XCTAssertGreaterThanOrEqual(seen.count, fr.floors, "★ floor by floor")
            for (a, b) in zip(counts, counts.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a - whole / 100, "it only ever rises") }
            XCTAssertLessThan(counts.first ?? whole, whole / 3, "★ the first snap a small part of it (the lowest floor's columns)")
            XCTAssertGreaterThanOrEqual(end - t0, LatticeBuildTimelapse.totalS - 1e-9)
        }
    }

    /// ★ The page: a regular lay's struts land WITH their own map (img 97 was the new struts over the last lay's map), and the
    /// last lattice is hidden while the next one lays. RED CONTROL: the struts published before their map (as before).
    func testTheStrutsLandWithTheirOwnMapAndTheLastLatticeHidesWhileTheNextLays() async throws {
        for red in [false, true] {
            LatticeBuildShow.controlOff = red
            let p = try FlexiblePressFixtures.cube60Project()
            p.lattice.flexible = nil
            p.lattice.chooseLatticeType(.structural)
            p.lattice.wholePart = true
            p.lattice.enabled = true
            XCTAssertFalse(LatticeLayoutPreview.organic(p.lattice), "premise: a strut type")
            let preview = LatticeLayoutPreview()
            defer { preview.clear() }
            var published: [LatticeLayoutBarsInputs] = []
            let sub = preview.$bars.sink { if let b = $0 { published.append(b) } }
            defer { sub.cancel() }
            preview.update(project: p, on: true, solid: true)
            try await settle(preview)
            let first = try XCTUnwrap(preview.bars, "premise: laid")
            XCTAssertGreaterThan(first.bars.count, 0, "premise: struts")
            let landed = Dictionary(grouping: published, by: \.token).compactMap { $0.value.first }
            if red {
                XCTAssertTrue(landed.contains { $0.solid?.token != $0.token },
                              "RED CONTROL: the struts were on screen before their own map (img 97's frame)")
                continue
            }
            for b in landed { XCTAssertEqual(b.solid?.token, b.token, "★ the struts land with their own map, never another's") }
            // the next lay: the last lattice hidden from the ask to the landing
            p.lattice.cellMM = (p.lattice.cellMM > 0 ? p.lattice.cellMM : 8) + 2
            p.lattice.cellSizeMode = .fixed
            preview.update(project: p, on: true, solid: true)
            XCTAssertTrue(preview.laying, "premise: laying again")
            XCTAssertTrue(preview.build.waiting, "★ the site cleared")
            XCTAssertEqual(preview.build.reveal(barsToken: first.token, floors: 4, at: LatticeBuildShow.now), .none,
                           "★ the last lattice not drawn while the next one lays")
            try await settle(preview)
            let second = try XCTUnwrap(preview.bars)
            XCTAssertNotEqual(second.token, first.token, "premise: a new lay")
            XCTAssertEqual(second.solid?.token, second.token, "★ with its own map")
            XCTAssertEqual(preview.build.token, second.token, "★ its timelapse builds it")
        }
    }

    private func settle(_ preview: LatticeLayoutPreview) async throws {
        let end = Date().addingTimeInterval(300)
        while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(preview.laying, "the lay ended")
    }

    /// ★ His review of the first clips (img 98: "None of the parts' walls open up … no shading exists"), in the solid view: the
    /// part stands closed while the engine lays (never opened by the last lay's map), its walls come off in hard snaps once the
    /// lay lands with its own map, and it stands open — its inside shaded — before the frame rises; with the 4× anti-aliased cut
    /// (his iPad's) as without. RED CONTROL (no timelapse): open by the last map the whole time the engine lays.
    func testTheWallsComeOffInSnapsAfterTheLayLandsSeenInside() throws {
        for samples in [1, 4] { for red in [false, true] {
            LatticeBuildShow.controlOff = red
            guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: samples) else {
                throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
            }
            r.setMesh(ViewerMesh(vertices: Notes24IntoThePartTests.cubeV, indices: Notes24IntoThePartTests.cubeI,
                                 faceIDs: [Int32](repeating: 1, count: Notes24IntoThePartTests.cubeI.count / 3)))
            r.setBodyAlpha(1)   // the solid view
            r.camera.target = SIMD3(10, 14, 10)
            r.camera.setOrientation(azimuth: 0.6, elevation: 1.25)
            r.camera.distance = 48
            let (w, h) = (480, 360)
            let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            func frame() throws -> [UInt8] { try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: clear, stage: false)) }
            func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
                stride(from: 0, to: a.count, by: 4).filter { abs(Int(a[$0]) - Int(b[$0])) + abs(Int(a[$0 + 1]) - Int(b[$0 + 1])) > 24 }.count
            }
            let closed = try frame()   // the bare part
            let bar: [Float] = [10, 9, 10, 10, 11, 10, 0.6]   // a strut deep in the pocket
            let show = LatticeBuildShow()
            r.applyBuildShow(show)
            r.applyLayoutBars(LatticeLayoutBarsInputs(token: 1, bars: bar, solid: Notes24IntoThePartTests.pocketMap(token: 1)),
                              device: device)
            let t0 = CACurrentMediaTime() + 1000
            LatticeBuildShow.clockForTesting = t0
            let lastOpen = try frame()
            let opened = differing(closed, lastOpen)
            XCTAssertGreaterThan(opened, 2_000, "premise: the last lattice's map opens the pocket")
            show.layBegins(walls: true, now: t0)
            LatticeBuildShow.clockForTesting = t0 + 0.6
            let laying = differing(closed, try frame())
            if red {
                XCTAssertGreaterThan(laying, opened / 2, "RED CONTROL: open by the last map while the engine lays")
                continue
            }
            XCTAssertLessThan(laying, opened / 20, "★ closed while the engine lays (\(samples)×)")
            XCTAssertEqual(r.lastBuildStanding, 1)
            let land = t0 + 1.2
            r.applyLayoutBars(LatticeLayoutBarsInputs(token: 2, bars: bar, solid: Notes24IntoThePartTests.pocketMap(token: 2)),
                              device: device)
            show.landed(token: 2, now: land)
            // ★ notes30: floor by floor (Notes30StrutStreamTests.testTheWallsComeOffFloorByFloor shows each floor's share)
            var steps: [Int] = [], opens: [Int] = []
            var t = land
            while let tl = show.timelapse, !tl.done(at: t) {
                LatticeBuildShow.clockForTesting = t
                let px = try frame()
                let o = show.wallsOpen(barsToken: 2, at: t) ?? -1
                if opens.last != o { opens.append(o); steps.append(differing(closed, px)) }
                t += 1.0 / 30
            }
            LatticeBuildShow.clockForTesting = t + 0.05
            let open = differing(closed, try frame())
            XCTAssertNil(r.lastBuildStanding, "open as the map says once topped out")
            XCTAssertNotNil(r.insideMap, "★ the inside shaded by this lay's map")
            print("WALLS (\(samples)×): laying \(laying) px changed; floors opened \(opens) → \(steps); open \(open) (the last lattice's \(opened))")
            XCTAssertGreaterThanOrEqual(opens.filter { $0 >= 1 }.count, LatticeBuildTimelapse.floorsLeast, "★ the walls off floor by floor")
            for (a, c) in zip(steps, steps.dropFirst()) { XCTAssertGreaterThanOrEqual(c, a - open / 50, "★ more off at each floor") }
            XCTAssertEqual(Double(steps.last ?? 0), Double(open), accuracy: Double(open) / 20, "the last floor: off")
            XCTAssertGreaterThan(open, opened * 8 / 10, "★ then open")
        }}
    }

    // MARK: Skip all animations
    /// ★ "a blank screen with a 'Refreshing Lattice' notification and progress bar … at the real speed of the refresh":
    /// with it on, a lay leaves the lattice area blank and the finished lattice shows at once (no timelapse); Organic grows
    /// nothing on screen; the view jumps (no eased turn); the card is drawn with its words and its bar moves on only as the
    /// refresh's steps really end. RED CONTROL: off — the timelapse runs, the view turns, no card.
    func testSkipAllAnimationsShowsTheProgressCardAndNoMotion() throws {
        for skip in [true, false] {
            AppSettings.skipAllAnimations = skip
            // the lattice: blank while it lays, whole the moment it lands
            let show = LatticeBuildShow()
            let t0 = CACurrentMediaTime() + 1000
            show.layBegins(now: t0)
            XCTAssertEqual(show.reveal(barsToken: 1, floors: 4, at: t0 + 0.5), .none, "blank while it lays, either way")
            show.landed(token: 2, now: t0 + 1)
            if skip {
                XCTAssertEqual(show.reveal(barsToken: 2, floors: 4, at: t0 + 1), .all, "★ the finished lattice at once")
                XCTAssertNil(show.timelapse, "★ no timelapse")
            } else {
                XCTAssertNotEqual(show.reveal(barsToken: 2, floors: 4, at: t0 + 1.01), .all, "RED CONTROL: the frame rises")
            }
            // Organic: nothing grows on screen
            let g = LatticeGrowth()
            g.layBegins([], lineMM: 0.45, opening: .xray, now: t0)
            g.append(xyz: [0, 0, 0, 1, 1, 1], region: [1])
            XCTAssertEqual(g.layOnScreen, !skip, skip ? "★ no walls, no replay" : "RED CONTROL: the growth plays")
            XCTAssertEqual(g.count, skip ? 0 : 1)
            g.stop()
            // the view: jumps to Top, never turns
            let cam = OrbitCameraModel()
            cam.snap(toID: "Top", animated: true)
            XCTAssertEqual(cam.isAnimating, !skip, skip ? "★ the view jumps" : "RED CONTROL: the view turns")
            cam.stopAnimation()
            // the card
            let progress = LatticeRefreshProgress()
            let start = Date()
            progress.begin([.init(words: "Laying the struts", expectedS: 1), .init(words: "Cutting the part open", expectedS: 1)], now: start)
            XCTAssertEqual(progress.fraction(at: start.addingTimeInterval(0.5)), 0.25, accuracy: 1e-9, "★ by the step's own time")
            XCTAssertEqual(progress.fraction(at: start.addingTimeInterval(9)), 0.45, accuracy: 1e-9,
                           "★ a slow step holds the bar (90 % of it): never ahead of the work")
            progress.reached("Cutting the part open", now: start.addingTimeInterval(9))
            XCTAssertEqual(progress.fraction(at: start.addingTimeInterval(9)), 0.5, accuracy: 1e-9, "★ on as the step really ends")
            let suite = "notes29-skip-\(UUID().uuidString)"
            let d = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { d.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: d)
            settings.skipAnimations = skip
            XCTAssertEqual(AppSettings(defaults: d).skipAnimations, skip, "remembered on this device")
            let said = drawnWords(LatticeRefreshingCard(progress: progress, settings: settings))
            if skip {
                XCTAssertTrue(said.contains(LatticeRefreshingCard.title), "★ \"Refreshing Lattice\" on screen: \(said)")
            } else {
                XCTAssertFalse(said.contains(LatticeRefreshingCard.title), "RED CONTROL: no card while the animations play")
            }
            progress.end()
            XCTAssertTrue(drawnWords(LatticeRefreshingCard(progress: progress, settings: settings)).isEmpty, "gone with the lay")
        }
        AppSettings.skipAllAnimations = false
    }

    /// The setting's row: in the main menu's Settings, its caption five words at most, its (i).
    func testTheSettingsRowSaysItInFiveWordsAndHasItsInfo() throws {
        XCTAssertEqual(AppSettingsCopy.skipTitle, "Skip all animations", "his words")
        XCTAssertLessThanOrEqual(AppSettingsCopy.skipCaption.split(separator: " ").count, 5, "★ a caption of five words at most")
        XCTAssertLessThanOrEqual(AppSettingsCopy.skipInfo.split(separator: ".").count, 3, "the (i): three sentences at most")
        let suite = "notes29-row-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let view = AppSettingsView(settings: AppSettings(defaults: d), projection: ViewProjection(defaults: d),
                                   compute: ComputeLocationModel(defaults: d), storage: {}, done: {})
        XCTAssertTrue(drawnWords(view).contains(AppSettingsCopy.skipCaption), "★ the row is in Settings, its caption under it")
        XCTAssertFalse(AppSettings(defaults: d).skipAnimations, "off by default: the animations play")
    }

    final class SaidBox { var said: [String] = [] }
    /// What `v` draws in words (FlexibleSaid), hosted at 600 × 800.
    private func drawnWords<V: View>(_ v: V) -> [String] {
        FlexibleSaid.recording = true
        defer { FlexibleSaid.recording = false }
        let box = SaidBox()
        let root = v.onPreferenceChange(FlexibleSaidKey.self) { box.said = $0 }
            .frame(width: 600, height: 800).environment(\.colorScheme, .dark)
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let w = NSWindow(contentRect: hv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = hv
        hv.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(0.4)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        w.contentView = nil
        return box.said
    }

    // MARK: the Organic end

    private func pieces(_ n: Int, at x: Float) -> (xyz: [Float], region: [Int32]) {
        var xyz: [Float] = []
        for k in 0..<n { xyz += [x, Float(k), 0, x, Float(k) + 1, 0] }
        return (xyz, [Int32](repeating: 1, count: n))
    }

    /// One Organic lay begun at t0 and landing `layS` later, with the replay behind (polls still unshown) or caught up: the
    /// entire animation (the lay's start to the growth gone), the end (the landing to the growth gone), and the catch-up's first
    /// and last steps (pieces).
    private func organic(layS: Double, somethingLeft: Bool, polls given: Int? = nil)
        -> (entire: Double, end: Double, firstStep: Double, lastStep: Double) {
        let g = LatticeGrowth()
        let t0 = CACurrentMediaTime() + 1000
        g.layBegins([], lineMM: 0.45, opening: .xray, now: t0)
        let polls = given ?? Swift.max(2, Int(layS / LatticeGrowthReplay.pollS))
        for poll in 0..<polls { let p = pieces(100, at: Float(poll)); g.append(xyz: p.xyz, region: p.region) }
        var land = t0 + layS
        if !somethingLeft { while g.shownCount(at: land) < g.count, land < t0 + 300 { land += 0.05 } }
        g.seal(landed: true, now: land)
        let gone = (g.fadeStarted ?? land) + LatticeGrowth.fadeS
        XCTAssertEqual(g.alpha(at: gone + 0.01), 0, "gone at its end")
        var first = 0.0, lastStep = 0.0
        if somethingLeft, let f = g.fadeStarted {   // (probed in time order: the replay's playhead only moves on)
            let step = 1 / LatticeGrowthReplay.stepsPerS
            let from = g.shownCount(at: land)
            first = Double(g.shownCount(at: land + step + 1e-6) - from)
            let beforeLast = g.shownCount(at: f - step + 1e-6)
            lastStep = Double(g.shownCount(at: f + 1e-6) - beforeLast)
        }
        XCTAssertEqual(g.shownCount(at: (g.fadeStarted ?? land)), g.count, "every piece shown before the sink")
        g.stop()
        return (gone - t0, gone - land, first, lastStep)
    }

    /// ★ His first word ("add a couple more seconds … the end always feels too rushed"), his review of the clips ("let's do
    /// 8 seconds for the entire animation") and his pick ("7 seconds for ALL animations"): from the lay's start to the growth
    /// gone, at least 7 s — a quick lay exactly 7 s,
    /// its end stretched to fill it (the catch-up easing out: it slows into the lattice) — and however long the lay, its end never
    /// shorter than the lengthened one (2 to 3 s longer than release 20's). RED CONTROL: release 20 — a quick lay all over in
    /// under 5 s, its end about a second (a third of one once caught up).
    func testTheOrganicAnimationLastsHisSevenSecondsAndItsEndIsNeverRushed() {
        LatticeGrowthReplay.endAsRelease20(true)
        let oldQuick = organic(layS: 3.5, somethingLeft: true), oldSlow = organic(layS: 9, somethingLeft: true)
        let oldCaught = organic(layS: 9, somethingLeft: false)
        LatticeGrowthReplay.endAsRelease20(false)
        let quick = organic(layS: 3.5, somethingLeft: true), quickCaught = organic(layS: 3.5, somethingLeft: false, polls: 2)
        let slow = organic(layS: 9, somethingLeft: true), slowCaught = organic(layS: 9, somethingLeft: false)
        print(String(format: "ORGANIC: a quick lay %.2f → %.2f s in all (caught up %.2f); a slow lay's end %.2f → %.2f s (caught up %.2f → %.2f); catch-up steps %.0f first, %.0f last",
                     oldQuick.entire, quick.entire, quickCaught.entire, oldSlow.end, slow.end, oldCaught.end, slowCaught.end,
                     quick.firstStep, quick.lastStep))
        XCTAssertLessThan(oldQuick.entire, 5, "RED CONTROL: release 20 — a quick lay over in under 5 s")
        XCTAssertLessThanOrEqual(oldSlow.end, 1.1, "RED CONTROL: release 20's end about a second")
        XCTAssertLessThanOrEqual(oldCaught.end, 0.4, "RED CONTROL: caught up, the sink alone")
        let his = 7.0   // ★ his pick: "7 seconds for ALL animations"
        XCTAssertEqual(LatticeGrowthReplay.minTotalS, his, "his 7 s")
        XCTAssertEqual(LatticeBuildTimelapse.totalS, his, "★ the build's too: ALL animations")
        XCTAssertGreaterThanOrEqual(quick.entire, his - 1e-9, "★ the entire animation 7 s")
        XCTAssertLessThan(quick.entire, his + 1 / LatticeGrowthReplay.stepsPerS + 1e-6, "★ … a quick lay exactly (to a step)")
        XCTAssertEqual(quickCaught.entire, his, accuracy: 1e-6, "★ caught up: the rest fills it")
        XCTAssertGreaterThanOrEqual(slow.end - oldSlow.end, 2, "★ a slow lay's end: a couple more seconds")
        XCTAssertLessThanOrEqual(slow.end - oldSlow.end, 3)
        XCTAssertGreaterThanOrEqual(slowCaught.end - oldCaught.end, 2)
        XCTAssertLessThanOrEqual(slowCaught.end - oldCaught.end, 3)
        XCTAssertGreaterThan(quick.firstStep, 3 * quick.lastStep, "★ it slows into the end (eased out)")
        XCTAssertGreaterThanOrEqual(LatticeGrowth.landingS, his - 1e-9, "the most a landing takes covers the 7 s")
    }
}
#endif
