// Notes30LivePreviewTests — ★ his words 2026-11-26, on N3's merge note ("With Live preview on, every settled change replays the
// full 7 s"): "No, live Preview should have no animations. It should automatically change as fast as possible. No progress
// bar, no animation, nothing. Just change it."
//
// With Live preview in force (the page passes `live`: its `latticeLiveHere`), a lay — the strut lattice and Organic alike —
//   * plays no build timelapse and grows nothing (no growth watched, no replay, no walls opened);
//   * shows no "Refreshing Lattice" card (Skip all animations on or off), no bar, and no ring on the Lattice button;
//   * keeps the lattice on screen exactly as it was (never cleared, never dimmed) until the new one is whole, then the new one
//     replaces it in ONE step, with its own map (never the struts first and the part cut open after; never a partial lattice);
//   * a newer change while a lay runs stops it: the last lattice stays and only the newest lands (the settle: 0.5 s).
// RED CONTROL `LatticeLayoutPreview.controlLiveAnimates`: release 21 — the site cleared, the card, the ring, the growth.
// With Live preview off (`live` false) nothing changes: Notes29AnimationTests, LatticeGrowthReplayTests, LatticeGrowthTests and
// Notes24IntoThePartTests hold release 21's timelapse and growth.
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
final class Notes30LivePreviewTests: XCTestCase {

    private var accurateBefore = false
    override func setUp() { super.setUp(); accurateBefore = AppSettings.shared.latticePrintAccurate }
    override func tearDown() {
        AppSettings.shared.latticePrintAccurate = accurateBefore
        LatticeLayoutPreview.controlLiveAnimates = false
        AppSettings.skipAllAnimations = false
        super.tearDown()
    }

    /// The settle (his pick 11-16): Live preview lays half a second after the last change. Unchanged by notes30.
    func testTheSettleIsHalfASecond() {
        XCTAssertEqual(LatticePreviewMode.liveDelay, .milliseconds(500))
        XCTAssertFalse(LatticeLayoutPreview.quietLay(live: false), "Click to refresh: release 21's lay")
        XCTAssertTrue(LatticeLayoutPreview.quietLay(live: true), "★ Live preview: a quiet lay")
        LatticeLayoutPreview.controlLiveAnimates = true
        XCTAssertFalse(LatticeLayoutPreview.quietLay(live: true), "RED CONTROL: Live preview animates (release 21)")
    }

    /// The ring and the dimming read the lay's `quiet`: none for a Live preview lay.
    func testALivePreviewLayWearsNoRingAndDimsNothing() {
        let t0 = Date()
        let quiet = LatticeLayoutPreview.LayProgress(quality: .draft, started: t0, expectedS: 4, draftShown: false, quiet: true)
        let loud = LatticeLayoutPreview.LayProgress(quality: .draft, started: t0, expectedS: 4, draftShown: false)
        XCTAssertFalse(LatticeLayoutPreview.dims(quiet), "★ the last lattice not dimmed")
        XCTAssertTrue(LatticeLayoutPreview.dims(loud), "RED CONTROL: Click to refresh dims it, as before")
    }

    // MARK: the strut lattice, through the engine

    /// ★ A strut lay with Live preview: no timelapse (the last lattice never cleared), no card (Skip all animations on or off),
    /// no ring; the last lattice drawn as it was until the new one lands, whole, with its own map, in one step. A newer change
    /// while a lay runs: only the newest lands. RED CONTROL: the site cleared, the card (Skip on), the ring.
    func testAStrutLayWithLivePreviewShowsNothingUntilItLandsWhole() async throws {
        for red in [false, true] { for skip in [false, true] {
            LatticeLayoutPreview.controlLiveAnimates = red
            AppSettings.skipAllAnimations = skip
            let what = "\(red ? "RED CONTROL" : "live")\(skip ? ", Skip all animations" : "")"
            let p = try strutProject()
            let preview = LatticeLayoutPreview()
            defer { preview.clear() }
            preview.update(project: p, on: true, solid: true, live: true)
            try await settle(preview, what)
            preview.build.stop()   // (RED CONTROL: the first lattice shown whole, its timelapse skipped)
            let first = try XCTUnwrap(preview.bars, "\(what): premise: laid")
            XCTAssertEqual(first.solid?.token, first.token, "\(what): premise: with its map")
            var published: [LatticeLayoutBarsInputs?] = []
            let sub = preview.$bars.dropFirst().sink { published.append($0) }
            defer { sub.cancel() }
            let asks = preview.build.asks
            p.lattice.cellMM = 14
            preview.update(project: p, on: true, solid: true, delay: LatticePreviewMode.liveWait, live: true)
            XCTAssertTrue(preview.laying, "\(what): premise: laying")
            // while it waits and lays: what is on screen
            var cleared = false, dimmed = false, card = false, ring = false
            let end = Date().addingTimeInterval(300)
            while preview.laying, Date() < end {
                let shownNow = preview.bars?.token == first.token
                if shownNow, preview.build.reveal(barsToken: first.token, floors: 4, at: LatticeBuildShow.now) != .all { cleared = true }
                if preview.drawn(stressField: nil, stressKey: 0)?.dimmed == true { dimmed = true }
                if preview.refresh.on { card = true }
                if preview.ringProgress != nil { ring = true }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertFalse(preview.laying, "\(what): laid")
            let second = try XCTUnwrap(preview.bars)
            XCTAssertNotEqual(second.token, first.token, "\(what): premise: a new lay")
            if red {
                XCTAssertTrue(cleared, "RED CONTROL (\(what)): the last lattice cleared while the next one lays")
                XCTAssertTrue(ring, "RED CONTROL (\(what)): the ring on the Lattice button")
                XCTAssertEqual(card, true, "RED CONTROL (\(what)): the refresh under way (the card's, with Skip all animations on)")
                XCTAssertEqual(preview.build.asks, asks + 1, "RED CONTROL: a timelapse asked")
                continue
            }
            XCTAssertFalse(cleared, "★ \(what): the last lattice never cleared while the next one lays")
            XCTAssertFalse(dimmed, "★ \(what): nor dimmed")
            XCTAssertFalse(card, "★ \(what): no \"Refreshing Lattice\" card, no bar")
            XCTAssertFalse(ring, "★ \(what): no ring on the Lattice button")
            XCTAssertEqual(preview.build.asks, asks, "★ \(what): no timelapse asked")
            XCTAssertNil(preview.build.timelapse, "★ \(what): none running")
            XCTAssertEqual(preview.build.reveal(barsToken: second.token, floors: 4, at: LatticeBuildShow.now), .all,
                           "★ \(what): the new lattice drawn whole at once")
            XCTAssertEqual(published.map { $0?.token }, [second.token], "★ \(what): ONE step, old to new (nothing between)")
            XCTAssertEqual(published.first??.solid?.token, second.token, "★ \(what): it lands with its own map")

            // a newer change settles while a lay RUNS (a heavy one, in the engine): that lay is stopped, the last lattice stays,
            // and only the newest lands, half a second after its change
            published = []
            p.lattice.cellMM = 3
            let started = LatticeLayoutPreview.laysStarted
            preview.update(project: p, on: true, solid: true, live: true)
            let begun = Date().addingTimeInterval(30)
            while LatticeLayoutPreview.laysStarted == started, Date() < begun { try await Task.sleep(nanoseconds: 5_000_000) }
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertTrue(preview.laying, "\(what): premise: the 3 mm lay is running")
            p.lattice.cellMM = 12
            preview.update(project: p, on: true, solid: true, delay: LatticePreviewMode.liveWait, live: true)
            XCTAssertEqual(preview.bars?.token, second.token, "★ \(what): the last lattice stays meanwhile")
            try await settle(preview, what)
            let third = try XCTUnwrap(preview.bars)
            XCTAssertEqual(published.map { $0?.token }, [third.token], "★ \(what): only the newest change lands, in one step")
            XCTAssertTrue(preview.isCurrent(project: p), "★ \(what): it is the newest settings' lattice")
        }}
    }

    // MARK: Organic, through the engine

    /// ★ An Organic lay with Live preview: no growth watched or drawn, no replay, no walls opened, no card, no ring, the last
    /// lattice neither cleared nor dimmed; each lattice that lands is whole, with its map (Print-accurate preview off: the Draft
    /// alone, one step; on: its Draft, then the exact lattice — each whole). RED CONTROL: the growth, the card, the ring.
    func testAnOrganicLayWithLivePreviewGrowsNothingAndLandsWhole() async throws {
        for red in [false, true] { for accurate in [false, true] {
            LatticeLayoutPreview.controlLiveAnimates = red
            AppSettings.shared.latticePrintAccurate = accurate
            let what = "\(red ? "RED CONTROL" : "live"), Print-accurate \(accurate ? "on" : "off")"
            let p = try organicProject()
            let st = try stress(p, key: accurate ? 301 : 302)
            let preview = LatticeLayoutPreview()
            defer { preview.clear() }
            preview.update(project: p, on: true, solid: true, stress: st, live: true)
            try await settle(preview, what)
            let first = try XCTUnwrap(preview.bars, "\(what): premise: laid")
            preview.growth.stop()   // (RED CONTROL: the first lay's growth let go)
            let grown = preview.growth.appendedTotal
            var published: [LatticeLayoutBarsInputs?] = []
            let sub = preview.$bars.dropFirst().sink { published.append($0) }
            defer { sub.cancel() }
            var look = try XCTUnwrap(p.lattice.organicLook); look.lookPercent = 8; p.lattice.organicLook = look
            preview.update(project: p, on: true, solid: true, stress: st, delay: LatticePreviewMode.liveWait, live: true)
            XCTAssertTrue(preview.laying, "\(what): premise: laying")
            var watched = false, onScreen = false, dimmed = false, card = false, ring = false, cleared = false
            let end = Date().addingTimeInterval(600)
            while preview.laying, Date() < end {
                if preview.growthWatching { watched = true }
                if preview.growth.layOnScreen { onScreen = true }
                if preview.drawn(stressField: nil, stressKey: 0)?.dimmed == true { dimmed = true }
                if preview.refresh.on { card = true }
                if preview.ringProgress != nil { ring = true }
                if preview.bars == nil { cleared = true }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertFalse(preview.laying, "\(what): laid")
            let last = try XCTUnwrap(preview.bars)
            XCTAssertNotEqual(last.token, first.token, "\(what): premise: a new lay")
            if red {
                XCTAssertTrue(watched || onScreen, "RED CONTROL (\(what)): the growth played")
                XCTAssertTrue(ring, "RED CONTROL (\(what)): the ring on the Lattice button")
                XCTAssertTrue(card, "RED CONTROL (\(what)): the refresh under way")
                continue
            }
            XCTAssertFalse(watched, "★ \(what): no growth watched")
            XCTAssertFalse(onScreen, "★ \(what): no replay, no walls opened")
            XCTAssertEqual(preview.growth.appendedTotal, grown, "★ \(what): nothing grown on screen")
            XCTAssertFalse(dimmed, "★ \(what): the last lattice not dimmed")
            XCTAssertFalse(cleared, "★ \(what): nor cleared")
            XCTAssertFalse(card, "★ \(what): no card, no bar")
            XCTAssertFalse(ring, "★ \(what): no ring")
            let tokens = published.map { $0?.token }
            XCTAssertFalse(tokens.contains(nil), "★ \(what): never nothing on screen")
            XCTAssertEqual(Set(tokens.compactMap { $0 }).count, accurate ? 2 : 1,
                           "★ \(what): \(accurate ? "its Draft, then the exact lattice" : "one step") (\(tokens))")
            var seen = Set<Int>()
            for b in published.compactMap({ $0 }) where seen.insert(b.token).inserted {
                XCTAssertEqual(b.solid?.token, b.token, "★ \(what): each lattice lands whole WITH its own map, in one step")
            }
            XCTAssertEqual(preview.organicQuality, accurate ? .exact : .draft)
        }}
    }

    // MARK: fixtures

    private func strutProject() throws -> ProjectModel {
        let p = try FlexiblePressFixtures.cube60Project()
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.wholePart = true
        p.lattice.enabled = true
        p.lattice.cellSizeMode = .fixed
        p.lattice.cellMM = 8
        XCTAssertFalse(LatticeLayoutPreview.organic(p.lattice), "premise: a strut type")
        return p
    }

    /// DraftOpensFacesTests' part: Traced (Live preview's own: Grown stays Click to refresh), open (a quick lay).
    private func organicProject() throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        var look = LatticeOrganicLook(); look.mode = .traced; look.lookPercent = 5
        p.lattice.organicLook = look
        XCTAssertNotNil(p.importedFile, "premise: the part has its model file")
        return p
    }

    private func stress(_ p: ProjectModel, key: Int) throws -> LatticeLayoutPreview.Stress {
        let b = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let h = 2.0
        let lo = SIMD3<Double>(b.lo) - 2, size = SIMD3<Double>(b.hi - b.lo) + 4
        let n = SIMD3<Int>(Int((size.x / h).rounded(.up)) + 1, Int((size.y / h).rounded(.up)) + 1, Int((size.z / h).rounded(.up)) + 1)
        let count = n.x * n.y * n.z
        var t = [Double](repeating: 0, count: 6 * count)
        for i in 0..<count { t[6 * i] = 10 }
        let f = LatticeDemandField(vonMises: [Float](repeating: 10, count: count), stressTensor: t, nx: n.x, ny: n.y, nz: n.z,
                                   origin: lo, spacingMM: h, provenance: .solidSim(date: Date(), resolution: 64))
        return .init(key: key, field: f, referenceMPa: 20)
    }

    private func settle(_ preview: LatticeLayoutPreview, _ what: String) async throws {
        let end = Date().addingTimeInterval(600)
        while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(preview.laying, "\(what): laid within 10 min")
    }
}

/// ★ The same, hosted as the Lattice page wires it (the 3D view with the new engine's bars, its timelapse and growth, the
/// centred "Refreshing Lattice" card, the Lattice button wearing `ringProgress`), with Skip all animations ON (so the card
/// would show): while a Live preview lay waits and runs, every frame the 3D view draws is the LAST lattice exactly (never a
/// cleared site, never part of one); then the new lattice, whole, from one frame to the next; the card never drawn, the ring
/// never drawn. RED CONTROL: the site cleared (blank), the card and the ring drawn.
@MainActor
final class Notes30LivePreviewHostedTests: XCTestCase {

    final class SaidBox { var said: Set<String> = [] }

    struct Stage: View {
        @ObservedObject var preview: LatticeLayoutPreview
        let mesh: ViewerMesh?
        let settings: AppSettings
        let box: SaidBox
        var body: some View {
            ZStack(alignment: .bottomTrailing) {
                MetalMeshView(mesh: mesh, bodyAlpha: LatticeLayoutPreview.ghostAlpha,
                              layoutBars: preview.drawn(stressField: nil, stressKey: 0))
                    .latticeGrowth(preview.growth)
                    .latticeBuild(preview.build)
                    .overlay { LatticeRefreshingCard(progress: preview.refresh, settings: settings) }
                DSRunButton("Lattice", subtitle: "Ready", key: "latticeButton",
                            progress: preview.ringProgress.map(LatticePreviewMode.buttonProgress)) {}   // ★ the page's own
                    .padding(24)
            }
            .onPreferenceChange(FlexibleSaidKey.self) { box.said.formUnion($0) }
        }
    }

    override func tearDown() {
        LatticeLayoutPreview.controlLiveAnimates = false
        AppSettings.skipAllAnimations = false
        FlexibleSaid.recording = false
        LatticeRefreshingCard.recorded = []
        super.tearDown()
    }

    /// The page's own wiring: the Lattice button's ring is `ringProgress`, every lay the page asks carries its Live preview.
    func testThePageWearsTheQuietRingAndPassesLivePreview() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("let laying = refresh || runs ? nil : newEngine.ringProgress.map(LatticePreviewMode.buttonProgress)"),
                      "★ the Lattice button's ring: none for a Live preview lay")
        let calls = ws.components(separatedBy: "newEngine.update(").dropFirst().map { String($0.prefix(260)) }
        XCTAssertEqual(calls.count, 5)
        for c in calls where c.hasPrefix("project: project, on: true") || c.hasPrefix("project: project, on: on") {
            XCTAssertTrue(c.contains("live: latticeLiveHere") || c.contains("live: true"), "★ Live preview passed: \(c.prefix(140))")
        }
        let live = try XCTUnwrap(ws.range(of: "private func newEngineSettingsChanged()"))
        XCTAssertTrue(String(ws[live.upperBound...].prefix(400)).contains("delay: LatticePreviewMode.liveWait,\n                             live: true)"),
                      "★ the settled change: Live preview's own lay")
    }

    func testALivePreviewLayKeepsTheLastLatticeUntilTheNewOneIsWholeAndShowsNoProgress() throws {
        for red in [false, true] {
            LatticeLayoutPreview.controlLiveAnimates = red
            AppSettings.skipAllAnimations = true
            FlexibleSaid.recording = true
            LatticeRefreshingCard.recorded = []
            let what = red ? "RED CONTROL" : "live"
            let suite = "notes30-\(UUID().uuidString)"
            let d = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { d.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: d)
            settings.skipAnimations = true
            let p = try FlexiblePressFixtures.cube60Project()
            p.lattice.flexible = nil
            p.lattice.chooseLatticeType(.structural)
            p.lattice.wholePart = true
            p.lattice.enabled = true
            p.lattice.cellSizeMode = .fixed
            p.lattice.cellMM = 8
            let m = try XCTUnwrap(p.importedMesh)
            let mesh = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs)
            let preview = LatticeLayoutPreview()
            defer { preview.clear() }
            let box = SaidBox()
            let h = AppBuildHost(Stage(preview: preview, mesh: mesh, settings: settings, box: box),
                                 size: CGSize(width: 900, height: 700), test: self)
            h.pump(1)
            let r = try renderer(h)
            let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            func purple() -> Int {
                r.renderOffscreen(width: 360, height: 270, clear: clear, stage: false).map(Notes29AnimationTests.purple) ?? -1
            }
            preview.update(project: p, on: true, live: true)
            let end0 = Date().addingTimeInterval(300)
            while preview.laying, Date() < end0 { h.pump(0.05) }
            preview.build.stop()   // (RED CONTROL: the first lattice whole at once)
            h.pump(0.5)
            let first = try XCTUnwrap(preview.bars)
            let old = purple()
            XCTAssertGreaterThan(old, 500, "\(what): premise: the first lattice on screen")
            box.said = []
            LatticeRefreshingCard.recorded = []
            p.lattice.cellMM = 14
            preview.update(project: p, on: true, delay: LatticePreviewMode.liveWait, live: true)
            var frames: [(token: Int?, px: Int)] = []
            var ring = false
            let end = Date().addingTimeInterval(300)
            while preview.laying, Date() < end {
                h.pump(0.03)
                frames.append((r.layoutBars?.token, purple()))
                if h.frames.all["latticeButton-ring"] != nil || h.frames.all["latticeButton-spinner"] != nil { ring = true }
            }
            h.pump(0.3)
            let second = try XCTUnwrap(preview.bars)
            XCTAssertNotEqual(second.token, first.token, "\(what): premise: a new lay")
            let new = purple()
            let card = box.said.contains(LatticeRefreshingCard.title) || !LatticeRefreshingCard.recorded.isEmpty
            if h.frames.all["latticeButton-ring"] != nil || h.frames.all["latticeButton-spinner"] != nil { ring = true }
            print("NOTES30 \(what): the last lattice \(old) px, the new \(new) px; while laying \(frames.map(\.px)); card \(card), ring \(ring)")
            if red {
                XCTAssertTrue(frames.contains { $0.px == 0 }, "RED CONTROL: the site cleared while the next one lays")
                XCTAssertTrue(card, "RED CONTROL: the \"Refreshing Lattice\" card drawn (Skip all animations on)")
                continue
            }
            XCTAssertGreaterThan(abs(new - old), old / 10, "premise: the two lattices look different")
            XCTAssertFalse(frames.isEmpty, "premise: frames drawn while it waited and laid")
            var landed = false
            for f in frames {
                let isOld = abs(f.px - old) <= old / 50, isNew = abs(f.px - new) <= new / 50
                XCTAssertTrue(isOld || isNew, "★ every frame the last lattice or the new one, whole — never a part (\(f.px) px)")
                if isNew, !isOld { landed = true }
                if landed { XCTAssertFalse(isOld && !isNew, "★ once the new one shows, never the old again") }
                XCTAssertTrue(f.token == first.token || f.token == second.token, "★ only the two lattices' bars drawn")
            }
            XCTAssertFalse(card, "★ no \"Refreshing Lattice\" card, no bar (Skip all animations on)")
            XCTAssertFalse(ring, "★ no ring on the Lattice button")
            XCTAssertNil(r.lastBuildSnaps, "★ no timelapse snaps")
        }
    }

    /// The 3D view's renderer (the largest MTKView's).
    private func renderer(_ h: AppBuildHost) throws -> MeshRenderer {
        var found: [MTKView] = []
        func walk(_ v: NSView) { if let m = v as? MTKView { found.append(m) }; v.subviews.forEach(walk) }
        walk(h.view)
        let mtk = try XCTUnwrap(found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }, "the 3D view")
        return try XCTUnwrap(mtk.delegate as? MeshRenderer, "the 3D view's renderer")
    }
}
#endif
