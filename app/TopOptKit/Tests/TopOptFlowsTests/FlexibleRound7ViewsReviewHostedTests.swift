// FlexibleRound7ViewsReviewHostedTests — round 7 batch R7-V's REVIEW (2026-10-14), the hosted half (offscreen, never the
// app): the verify's confirmed findings, each written BEFORE its fix with its RED control run inside. Part of
// FlexibleRound7ViewsHostedTests (its hosting, clicks and pixel helpers), on HIS pad (A1_0003 as he saved it).
//   RH1 (major) his None pad: the default view drew no wall (X-ray off for every finish); X-ray off hides the walls under
//       ANY finish (step 1's limit — H6 proved it for Covered only), so a None pad opens in X-ray. The shipping renderer.
//       RED `controlXrayOffOnOpen`.
//   RH2 (major) Settings, Bend alone: the bent part was a near-black smudge (the page's X-ray ghost, no heat on it) — his
//       img4: "showing the entire 3d model at its full squish depth". The shipping renderer. RED `controlBendGhost`.
//   RH3 (major) Settings: Heat hidden while the legend read left the page stuck in its reading (every tap read, none
//       selected); with the heat hidden its TAP TO READ strip still drilled in. RED `controlKeepReadingWithoutHeat` (the page
//       hosted, its drill driven through `testDrill` — the harness's clicks land on the MTKView); the strip's rule pinned.
//   RH4 (minor) Settings [Heat]: "this group" and "every group" looked the same. RED `controlNoHeatAllBadge`.
//   RH5 (minor) the main page's Play icon: the working ring was a faint grey speck, a failure showed nothing. RED
//       `FlexibleMainViewToggles.controlMiniSpinner` (the first build's mini spinner).
//   RH6 (minor) the Settings player's note cut at 11" portrait ("Column preview · no lattic…"): drawn whole. RED: no short
//       forms handed to the player.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import Combine
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleRound7ViewsHostedTests {

    static func bgDiff(_ px: [UInt8], at i: Int) -> Int {
        let bg = DS.Color.background
        let b = Int((bg.b * 255).rounded()), g = Int((bg.g * 255).rounded()), r = Int((bg.r * 255).rounded())
        return max(abs(Int(px[i]) - b), abs(Int(px[i + 1]) - g), abs(Int(px[i + 2]) - r))   // (BGRA8)
    }
    /// Pixels (BGRA8) that READ on the page's dark ground: luma above `minLuma` (of 255) — the X-ray ghost's dark smudge
    /// (≈ 30–45) does not, the shaded part (≈ 100–170) does.
    static func bright(_ px: [UInt8], minLuma: Double = 72) -> Int {
        stride(from: 0, to: px.count, by: 4).filter { i in
            0.0722 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.2126 * Double(px[i + 2]) > minLuma
        }.count
    }
    static func frameDiffering(_ a: [UInt8], _ b: [UInt8], threshold t: Int = 12) -> Int {
        guard a.count == b.count else { return -1 }
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) where max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2]))) > t { n += 1 }
        return n
    }

    // MARK: - RH1: a None pad opens in X-ray; X-ray off hides the walls under ANY finish

    func testANonePadOpensInXrayAndXrayOffHidesTheWallsUnderAnyFinish() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let s = FlexibleMainStage()
        let (r, m) = try hisPad(s)
        XCTAssertEqual(m.settings.finishMode, .none, "premise: his pad as saved — Finish None")
        build(m)
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(pumpUntil(30) { s.channels != nil && s.layer(r.project, stage: .lattice, pageUp: false) != nil })
        let probe = FlexibleRound6EvidenceProbe()
        let img1 = FlexibleRound6Tests.Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        func frame(lattice: Bool) throws -> [UInt8] {
            s.latticeOn = lattice
            s.refresh()
            let mesh = try XCTUnwrap(s.mesh(r.project, on: .lattice))
            let mr = try probe.renderer(mesh: mesh, tints: s.tints(r.project, on: .lattice, roles: [:], stress: nil),
                                        dents: s.dents(r.project, on: .lattice), scale: s.dentScale(r.project, on: .lattice),
                                        bodyAlpha: s.bodyAlpha(r.project, on: .lattice) ?? 1, settle: settle, cam: img1, device: device,
                                        items: s.volumes(r.project, on: .lattice, drilledIn: false),
                                        layer: s.layer(r.project, stage: .lattice, pageUp: false))
            let bg = DS.Color.background
            return try XCTUnwrap(mr.renderOffscreen(size: FlexibleRound6EvidenceProbe.size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        }
        // as the page opens on his None pad: X-ray on — the walls are seen
        XCTAssertTrue(s.xrayOn, "★ None: X-ray on as the page opens")
        let seen = Self.frameDiffering(try frame(lattice: true), try frame(lattice: false))
        XCTAssertGreaterThan(seen, 2_000, "★ his lattice is SEEN as the page opens (\(seen) px: the walls inside the ghost)")
        // X-ray off (his tap): out of X-ray the walls are hidden under ANY finish — None too (step 1's limit; R7-X's printed
        // view draws them through the finish's openings) — the reason a None pad opens in X-ray
        s.xrayOn = false
        let hiddenNone = Self.frameDiffering(try frame(lattice: true), try frame(lattice: false))
        XCTAssertEqual(hiddenNone, 0, "★ X-ray off, Finish None: no wall drawn either (\(hiddenNone) px)")
        // ★ RED CONTROL: R7-V's first build — X-ray off on open whatever the finish: the opaque block, no lattice
        s.xrayChoice = [:]
        s.controlXrayOffOnOpen = true
        let control = Self.frameDiffering(try frame(lattice: true), try frame(lattice: false))
        s.controlXrayOffOnOpen = false
        XCTAssertEqual(control, 0, "★ RED CONTROL: the first build opened his None pad with no wall seen")
        print("FLEX-R7V-RH1 None pad: walls seen on open \(seen) px · X-ray off (any finish) \(hiddenNone) px · control (first build) \(control) px")
    }

    // MARK: - RH2: Bend alone draws the bent part readable

    func testBendAloneDrawsTheBentPartReadableAtItsFullDepth() async throws {
        addTeardownBlock { @MainActor in FlexibleStagePage.controlBendGhost = false }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.regions == [4, 2] }, "his two-face Group 2 (the pinch)")
        m.rail = .group(g2.id)
        m.select(4)
        try await FlexibleSquishFixture.solve(m, first: FlexibleSim.groupID(g2.number), "his pad")
        let views: FlexibleStageViews = [.bend, .heatOff]
        m.views = views
        XCTAssertTrue(FlexibleStagePage.overlaysHidden(views: views, edgePick: false), "premise: Bend alone")
        let edge = try XCTUnwrap(FlexibleSettingsSquish.overlayEdge(model: m), "premise: Group 2's field is current")
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m, maxEdgeMM: edge))
        var cache: (key: String, dents: [Float])?
        var c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: views)
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
        c.dents = sq.dents
        XCTAssertNotNil(sq.dents, "premise: the group's dent")
        let k = FlexibleStagePage.dentScale(views: views, exaggeration: sq.exaggeration, amount: 0)
        XCTAssertEqual(k, Float(sq.exaggeration), "premise: Bend — k × 1")
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let cam = FlexibleRound6Tests.Cam(name: "iso", azimuth: .pi / 4, elevation: .pi / 6, zoom: 1.25)
        func frame(alpha: Float, scale: Float) throws -> [UInt8] {
            let mr = try FlexibleRound6EvidenceProbe().renderer(mesh: overlay.mesh, tints: c.tints, dents: sq.dents, scale: scale, bodyAlpha: alpha,
                                                                 settle: settle, cam: cam, device: device,
                                                                 items: FlexibleStageVolumes.items(model: m, k: 1, part: p.viewerMesh))
            let bg = DS.Color.background
            return try XCTUnwrap(mr.renderOffscreen(size: FlexibleRound6EvidenceProbe.size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        }
        let alpha = FlexibleStagePage.bodyAlpha(views: views, edgePick: false, hasDent: true)
        FlexibleStagePage.controlBendGhost = true
        let ghost = FlexibleStagePage.bodyAlpha(views: views, edgePick: false, hasDent: true)
        FlexibleStagePage.controlBendGhost = false
        XCTAssertEqual(ghost, FlexibleStagePage.xrayBodyAlpha, "the RED CONTROL is the first build's X-ray ghost")
        XCTAssertEqual(alpha, 1, "★ Bend alone: the opaque, shaded part")
        let bent = try frame(alpha: alpha, scale: k), rest = try frame(alpha: alpha, scale: 0)
        let gBent = try frame(alpha: ghost, scale: k), gRest = try frame(alpha: ghost, scale: 0)
        let seen = Self.bright(bent), gSeen = Self.bright(gBent)
        // the bend as he can read it: what moves between the rest pose and the full depth by more than a faint shade (48/255)
        let reads = Self.frameDiffering(bent, rest, threshold: 48), gReads = Self.frameDiffering(gBent, gRest, threshold: 48)
        XCTAssertGreaterThan(seen, 20_000, "★ Bend alone: the bent part READS on the page's dark ground (\(seen) px)")
        XCTAssertGreaterThan(seen, 5 * max(gSeen, 1), "★ …where the ghost was a smudge (\(seen) px vs the ghost's \(gSeen))")
        XCTAssertGreaterThan(reads, 2 * max(gReads, 1), "★ …and its bend reads against the rest pose (\(reads) px vs the ghost's \(gReads))")
        XCTAssertGreaterThan(reads, 1_000, "★ the full-depth pinch is plain to see (\(reads) px)")
        // with the heat shown (or Prisms / Groups / Play) the page keeps its X-ray reading: the heat on the bent faces,
        // what sits inside the part seen through it
        XCTAssertEqual(FlexibleStagePage.bodyAlpha(views: [.bend], edgePick: false, hasDent: true), FlexibleStagePage.xrayBodyAlpha,
                       "Bend with Heat: the X-ray ghost under the opaque heat")
        XCTAssertEqual(FlexibleStagePage.bodyAlpha(views: [], edgePick: false, hasDent: true), FlexibleStagePage.xrayBodyAlpha, "editing: X-ray")
        XCTAssertGreaterThanOrEqual(FlexibleStagePage.bodyAlpha(views: [.bend, .heatOff, .prisms], edgePick: false, hasDent: true),
                                    FlexibleStagePage.dentBodyAlpha, "Bend with the heat hidden and Prisms: the body still reads, the prisms through it")
        if let dir = Self.dir {
            for (name, px) in [("RH2_bend_alone_fixed", bent), ("RH2_bend_alone_control_ghost", gBent)] {
                let n = FlexibleRound6EvidenceProbe.size
                var rgba = px
                for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
                let ctx = try XCTUnwrap(CGContext(data: &rgba, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                let img = try XCTUnwrap(ctx.makeImage())
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("R7V_\(name).png")
                let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, img, nil)
                XCTAssertTrue(CGImageDestinationFinalize(dest))
            }
        }
        m.views = []
        print("FLEX-R7V-RH2 Bend alone (Group 2, k \(sq.exaggeration)): body alpha \(alpha) · seen \(seen) px, bend reads \(reads) px · control (ghost \(ghost)) seen \(gSeen) px, reads \(gReads) px")
    }

    // MARK: - RH3: Heat hidden ends the reading; no reading without the heat

    func testHidingTheHeatEndsTheReadingAndItsStripNeedsTheHeat() throws {
        addTeardownBlock { @MainActor in
            FlexibleStagePage.controlKeepReadingWithoutHeat = false
            FlexibleStagePage.controlTabIgnoresHeat = false
        }
        let (r, m) = try hisPad()
        m.rail = .group(m.squeezeGroups[0].id)
        m.select(1)
        let loop = FlexibleSquishLoop()
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.his13p.1)
        pump(2.5)
        _ = h
        XCTAssertNotNil(local(h, "legend"), "premise: the legend card is up (his drawing's dent, the heat shown)")
        // (the harness's clicks land on the MTKView under the chrome — AppKit's hit test — so the drill is driven through the
        // page's test seam; the page's own state and onChange rules run as they do on his pad)
        func run(control: Bool) -> (drilled: Bool, afterHeatOff: Bool) {
            m.views = []
            pump(0.6)
            FlexibleStagePage.testDrill.send(false)
            pump(0.3)
            FlexibleStagePage.controlKeepReadingWithoutHeat = control
            FlexibleStagePage.testDrill.send(true)   // ★ his tap on TAP TO READ
            pump(0.4)
            let drilled = loop.reading   // (the page's reading drives its loop's hold: holdWhileReading)
            m.views = [.heatOff, .prisms]   // ★ his tap on [Heat] — hidden; [Prisms] keeps the card up (its row)
            pump(0.8)
            let after = loop.reading
            FlexibleStagePage.controlKeepReadingWithoutHeat = false
            return (drilled, after)
        }
        let fixed = run(control: false)
        XCTAssertTrue(fixed.drilled, "premise: the legend drilled in (reading)")
        XCTAssertFalse(fixed.afterHeatOff, "★ hiding the heat ends the reading — a tap on the part selects again (onPickPoint)")
        let red = run(control: true)
        XCTAssertTrue(red.drilled)
        XCTAssertTrue(red.afterHeatOff, "★ RED CONTROL: the first build kept reading with the heat hidden (taps on the part did nothing)")
        FlexibleStagePage.testDrill.send(false)
        m.views = []
        pump(0.5)
        // with the heat hidden the card shows only its view rows: its TAP TO READ strip takes no tap
        XCTAssertTrue(FlexibleStagePage.reads(hasDent: true, views: []), "the heat shown: the strip reads")
        XCTAssertFalse(FlexibleStagePage.reads(hasDent: true, views: [.heatOff, .prisms]), "★ the heat hidden: nothing to read")
        XCTAssertFalse(FlexibleStagePage.reads(hasDent: false, views: []), "no dent: nothing to read")
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains(".allowsHitTesting(Self.controlTabIgnoresHeat ? dents != nil : Self.reads(hasDent: dents != nil, views: model.views))"),
                      "★ the strip's hit test is the reading rule (its control: the first build's dent alone)")
        XCTAssertTrue(page.contains(".onChange(of: Self.reads(hasDent: dents != nil, views: model.views)) { can in"), "★ the reset follows the same rule")
        // ★ RED CONTROL: the first build's rule (a dent was enough) — the strip drilled in with the heat hidden
        let firstBuild: (Bool, FlexibleStageViews) -> Bool = { hasDent, _ in hasDent }
        XCTAssertTrue(firstBuild(true, [.heatOff, .prisms]), "★ RED CONTROL: the first build's strip took the tap with the heat hidden")
        print("FLEX-R7V-RH3 reading: drilled \(fixed.drilled) → heat hidden \(fixed.afterHeatOff) (control \(red.afterHeatOff)) · strip without heat: reads \(FlexibleStagePage.reads(hasDent: true, views: [.heatOff, .prisms])) (first build: true)")
    }

    // MARK: - RH4: [Heat]'s "every group" at a glance

    func testTheHeatIconSaysEveryGroupAtAGlance() throws {
        addTeardownBlock { @MainActor in FlexibleStageViewButtons.controlNoHeatAllBadge = false }
        let (_, m) = try hisPad()
        let size = Self.his13p.1
        let i = try XCTUnwrap(FlexibleStageViews.buttons.firstIndex { $0.view == .heatOff })
        let row = FlexibleStageViews.frame(viewport: size)
        let rect = CGRect(x: row.minX + CGFloat(i) * (FlexibleStageViews.buttonSize + DS.Space.s) - 6, y: row.minY - 6,
                          width: FlexibleStageViews.buttonSize + 12, height: FlexibleStageViews.buttonSize + 12)
        let h = host(FlexibleStageViewButtons(model: m), size: size)
        func crop(_ views: FlexibleStageViews) throws -> Shot {
            m.views = views
            pump(0.5)
            return try shot(h)
        }
        func diff(_ a: Shot, _ b: Shot) -> Int {
            let x0 = Int(rect.minX * a.scale), x1 = Int(rect.maxX * a.scale), y0 = Int(rect.minY * a.scale), y1 = Int(rect.maxY * a.scale)
            var n = 0
            for y in max(0, y0)..<min(a.h, y1) { for x in max(0, x0)..<min(a.w, x1) {
                let k = (y * a.w + x) * 4
                if max(abs(Int(a.px[k]) - Int(b.px[k])), abs(Int(a.px[k + 1]) - Int(b.px[k + 1])), abs(Int(a.px[k + 2]) - Int(b.px[k + 2]))) > 24 { n += 1 }
            } }
            return n
        }
        let group = try crop([]), all = try crop([.heatAll])
        let fixed = diff(group, all)
        snapshot(h, "R7V_review_13p_settings_heat_all_badge.png")
        FlexibleStageViewButtons.controlNoHeatAllBadge = true
        let cGroup = try crop([]), cAll = try crop([.heatAll])
        FlexibleStageViewButtons.controlNoHeatAllBadge = false
        let control = diff(cGroup, cAll)
        XCTAssertGreaterThan(fixed, 3 * control, "★ every group's heat looks different from this group's (\(fixed) px vs the glyph alone \(control))")
        XCTAssertGreaterThan(fixed, 60, "★ …plainly (\(fixed) px)")
        m.views = []
        print("FLEX-R7V-RH4 heat icon, this group vs every group: \(fixed) px · control (glyph only) \(control) px")
    }

    // MARK: - RH5: the main page's Play icon — the working ring and the failure dot are seen

    func testThePlayIconsRingAndDotAreSeenWithPlayOff() throws {
        addTeardownBlock { @MainActor in FlexibleMainViewToggles.controlMiniSpinner = false }
        let size = Self.his13p.1
        let s = FlexibleMainStage()
        let row = FlexibleMainViewToggles.rowFrame(viewport: size)
        let cols = FlexibleMainViewToggles.columns(viewport: size)
        // the Play icon: the sixth (the last of one line, or of the second line of three)
        let col = (FlexibleMainViewToggles.buttons - 1) % cols, line = (FlexibleMainViewToggles.buttons - 1) / cols
        let play = CGRect(x: row.minX + CGFloat(col) * (40 + DS.Space.s) - 4, y: row.minY + CGFloat(line) * (40 + DS.Space.s) - 4, width: 48, height: 48)
        func count(_ fe: FlexibleFEView, like c: RGBA, shot name: String? = nil) throws -> Int {
            s.fe = fe
            let h = host(FlexibleMainViewToggles(main: s), size: size)
            pump(0.4)
            let a = try shot(h)
            if let name { snapshot(h, name) }
            let tr = Int((c.r * 255).rounded()), tg = Int((c.g * 255).rounded()), tb = Int((c.b * 255).rounded())
            var n = 0
            for y in max(0, Int(play.minY * a.scale))..<min(a.h, Int(play.maxY * a.scale)) {
                for x in max(0, Int(play.minX * a.scale))..<min(a.w, Int(play.maxX * a.scale)) {
                    let k = (y * a.w + x) * 4   // (RGBA, premultiplied — the colours are opaque)
                    if abs(Int(a.px[k]) - tr) < 40, abs(Int(a.px[k + 1]) - tg) < 40, abs(Int(a.px[k + 2]) - tb) < 40 { n += 1 }
                }
            }
            return n
        }
        var working = FlexibleFEView(); working.pending = true
        var failed = FlexibleFEView(); failed.failure = "core's words"
        let ring = try count(working, like: DS.Color.accent, shot: "R7V_review_13p_main_play_working.png")
        let idleRing = try count(FlexibleFEView(), like: DS.Color.accent)
        let dot = try count(failed, like: DS.Color.warning, shot: "R7V_review_13p_main_play_failed.png")
        let idleDot = try count(FlexibleFEView(), like: DS.Color.warning)
        FlexibleMainViewToggles.controlMiniSpinner = true
        let cRing = try count(working, like: DS.Color.accent), cDot = try count(failed, like: DS.Color.warning)
        FlexibleMainViewToggles.controlMiniSpinner = false
        s.fe = FlexibleFEView()
        XCTAssertGreaterThan(ring - idleRing, 120, "★ the sims running: an accent ring on the Play icon (\(ring) px, idle \(idleRing))")
        XCTAssertGreaterThan(dot - idleDot, 40, "★ a sim failed: an orange dot on the Play icon (\(dot) px, idle \(idleDot))")
        XCTAssertLessThan(cRing - idleRing, 40, "★ RED CONTROL: the first build's mini spinner is not seen as a ring (\(cRing) px)")
        XCTAssertLessThan(cDot - idleDot, 10, "★ RED CONTROL: the first build said nothing of a failure (\(cDot) px)")
        print("FLEX-R7V-RH5 Play icon: working ring \(ring) px (idle \(idleRing)) · failed dot \(dot) px (idle \(idleDot)) · control ring \(cRing) dot \(cDot)")
    }

    // MARK: - RH6: the Settings player's note is whole at 11" portrait

    func testTheSettingsPlayerNoteIsWholeAtElevenInchPortrait() throws {
        let (r, m) = try hisPad()
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.regions == [4, 2] })
        m.rail = .group(g2.id)
        m.select(4)
        m.views = [.play]
        let size = try XCTUnwrap(Self.sizes.first { $0.0 == "11p" }).1
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
        pump(2.5)
        let note = try XCTUnwrap(FlexibleSettingsSquish.note(model: m, fe: false), "premise: the player's line (no lattice yet)")
        let drawn = try XCTUnwrap(h.frames.all["playerNote"], "premise: the note is drawn").width
        let shown = h.frames.all.keys.first { $0.hasPrefix("playerNoteText:") }.map { String($0.dropFirst("playerNoteText:".count)) } ?? note
        func natural(_ t: String) -> CGFloat {
            NSHostingView(rootView: Text(t).dsStyle(DS.TypeScale.footnote).fixedSize()).fittingSize.width + 2 * DS.Space.m
        }
        let need = natural(shown), full = natural(note)
        snapshot(h, "R7V_review_11p_settings_player_note.png")
        XCTAssertLessThan(drawn + 0.5, full, "premise (the RED CONTROL): '\(note)' does not fit beside the picker at 11\" portrait (\(drawn) of \(full) pt)")
        XCTAssertGreaterThanOrEqual(drawn + 0.5, need, "★ the line drawn ('\(shown)') is WHOLE (\(drawn) of \(need) pt)")
        XCTAssertNotEqual(shown, note, "★ a shorter form is drawn")
        m.views = []
        print("FLEX-R7V-RH6 11p note: '\(note)' needs \(full) pt, drawn \(drawn) pt · shown '\(shown)' needs \(need) pt")
    }
}
#endif
