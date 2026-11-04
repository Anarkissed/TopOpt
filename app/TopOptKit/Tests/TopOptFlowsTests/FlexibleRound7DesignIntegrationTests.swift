// FlexibleRound7DesignIntegrationTests — round 7, batch R7-D3 (the redesign's INTEGRATION: his pick 1 — A2's capsule + A1's
// corner pair, built by R7-D1 — and his pick 2 — B1 with his three changes, built by R7-D2 — on ONE Flexible stage). Written
// BEFORE the code (red run: round7/batch_d3/d3_red_run.txt). The plan's batch R7-D3 tests, and the reviewer's requirements of
// 2026-10-17 20:25 (ruling 3: "REQUIRED before D3 is done: the card's step 2 shows what goes to core ('Group 1 · 22 lb · 1
// face · bead 0.45 mm'); 'Lattice ready' dropping under the icons at 11" portrait and the card covering the legend").
//   I1  ONE CARD AT A TIME across the two batches (FlexibleChromeState): the tray or the card folds the chip and keeps the pick
//       and its prisms; a face tap folds the tray, the card and the callout; the callout folds the chip; a keypad folds the
//       tray; the capsule's Squish segment and its menu fold everything; GRAVITY SETUP folds everything AND clears the pick
//       (its taps are #354's gravity picker — H22 is gated on the edit phase — so a chip left over would float over it).
//       RED CONTROL `FlexibleChromeState.controlChipOutsideTheRule`: the chip outside the rule — the tray and the chip both up.
//   I2  KEEP-OUTS across the batches at the six viewports he uses (13", 11", the mini; both orientations): the chip's automatic
//       spot never on the open tray / card (kept out though one card at a time hides the chip under a panel), the capsule, the
//       pair or the list, and always found with no panel open; a chip let go on the pair slides off it; the
//       minimised Selections pill ≥ 12 pt from the Setup chip. FOUND BY THIS TEST (RED at 0e66bf47): on the mini in portrait
//       the 404 pt chip never fits beside the open list's 372 pt column — nothing was clear, the chip fell back onto the views
//       row and a let-go stayed on the pair; now where nothing is clear of the column, the list AS DRAWN is the keep-out.
//       RED CONTROLS: the keep-outs without the open panel land the chip on it; a let-go that only clamps stays on the pair;
//       the column alone leaves the mini's chip no spot.
//   I3  EQUALITY UNDER LOAD: a typed depth with the Lattice card open — the handle's text = the list's box = the plane's depth
//       = the drawn prism, and the card's ① line says the same depth.
//   I4  STEP ② SAYS WHAT GOES TO CORE whenever the card offers [Send to core] (Ready, and a Preview that can send — batch E's
//       advisory: a pressed face with no lattice under it still SENDS), and what it says is the job: on his pad "Group 1 · 22
//       lb · 1 face · bead 0.45 mm" = the job's one group, its weight_n in his unit, its faces, its min_extrudable_width_mm.
//       RED (at 0e66bf47): a Preview that sends shows no summary. RED CONTROL: Topology's weight formatter ("10 kg") is not the
//       job in his unit.
//   I5  "LATTICE READY" BESIDE THE ICONS at 11" portrait — on the row's line, left of the six icons, whole, below the capsule,
//       never on the Selections list (whose top never rises above PageLeftModal's 2 × noteTop) — and at every viewport never
//       under the row. RED (at 0e66bf47): under the row at 11" portrait (the left strip reserved its whole height).
//   I6  NO PANEL EVER COVERS THE LEGEND (the review of R7-D1's fix, re-checked at six viewports with the note moved): the tray,
//       the card and the callout, any height. RED CONTROL: a panel capped by the views row alone covers the 11" landscape legend.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRound7DesignIntegrationTests: XCTestCase {

    override func tearDown() {
        FlexibleChromeState.controlChipOutsideTheRule = false
        super.tearDown()
    }

    static let viewports: [(String, CGSize)] = [
        ("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032)),
        ("11p", CGSize(width: 834, height: 1194)), ("11l", CGSize(width: 1194, height: 834)),
        ("minip", CGSize(width: 744, height: 1133)), ("minil", CGSize(width: 1133, height: 744)),
    ]

    /// His pad (A1_0003 + his live lattice: Group C = Face 3 + Face 5 at 25 mm), the stage's model made (no hosting).
    func stage() throws -> (FlexibleHisProject.Restored, ProjectModel, FlexibleMainStage, UUID) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        s.apply(r.project, owned: true, pageUp: false)
        return (r, r.project, s, c)
    }

    /// The chip shows where the layer would draw it: a pick, and the one-card rule lets it.
    func chipShown(_ s: FlexibleMainStage) -> Bool { s.chrome.allowsFaceChip && !s.facePick.scope.isNone }

    // MARK: I1 — one card at a time

    func testOneCardAtATimeAcrossTheBatches() throws {
        let (_, p, s, c) = try stage()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        let hooks = s.cornerHooks(openSquish: {})

        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        XCTAssertEqual(s.chrome.open, .faceChip, "premise: chip M at Face 3")
        XCTAssertTrue(chipShown(s))
        let pick = s.facePick
        let prisms = s.volumes(p, on: .lattice, drilledIn: false).count
        XCTAssertGreaterThan(prisms, 0, "premise: Face 3's prism drawn")

        // the Setup chip (D1) over a chip (D2)
        s.chrome.toggle(.setup)
        XCTAssertEqual(s.chrome.open, .setup)
        XCTAssertFalse(chipShown(s), "★ I1: the tray folds the chip")
        XCTAssertEqual(s.facePick, pick, "★ I1: … the pick stays")
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false).count, prisms, "★ I1: … and its prisms")

        // a face tap folds the tray
        s.tapFace(p, face: 5, point: nil, mesh: mesh)
        XCTAssertEqual(s.chrome.open, .faceChip, "★ I1: a face tap folds the tray; the chip shows")

        // the card's ⌃ (D1) over a chip
        FlexibleLatticeButton.caret(chrome: s.chrome, hooks: hooks)
        XCTAssertEqual(s.chrome.open, .latticeCard)
        XCTAssertFalse(chipShown(s), "★ I1: the card folds the chip")
        XCTAssertFalse(s.facePick.scope.isNone, "★ I1: … the pick stays")
        XCTAssertGreaterThan(s.volumes(p, on: .lattice, drilledIn: false).count, 0, "★ I1: … and its prisms")
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        XCTAssertEqual(s.chrome.open, .faceChip, "★ I1: a face tap folds the card")

        // the callout (D1: Fix → the callout) over a chip
        FlexibleLatticeButton.perform(.callout, chrome: s.chrome, hooks: hooks)
        XCTAssertEqual(s.chrome.open, .callout)
        XCTAssertFalse(chipShown(s), "★ I1: the callout folds the chip")
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        XCTAssertEqual(s.chrome.open, .faceChip, "★ I1: a face tap folds the callout")

        // a keypad (D2's boxes) folds the tray (the layer shows .keypad when a box's keypad opens)
        s.chrome.toggle(.setup)
        s.chrome.show(.keypad)
        XCTAssertEqual(s.chrome.open, .keypad, "★ I1: a keypad folds the tray")
        XCTAssertTrue(chipShown(s), "the keypad belongs to the chip")
        s.chrome.close(.keypad); s.chrome.show(.faceChip)

        // the capsule's Squish segment folds everything (and the page coming up freezes the layer)
        var squished = false
        s.chrome.toggle(.setup)
        FlexibleStageCapsule.tapSegment(.squish, on: .lattice, chrome: s.chrome, lattice: {}, squish: { squished = true })
        XCTAssertTrue(squished)
        XCTAssertNil(s.chrome.open, "★ I1: Squish folds every card")
        s.apply(p, owned: true, pageUp: true)
        XCTAssertNil(s.chrome.open)
        s.apply(p, owned: true, pageUp: false)

        // the capsule's menu: About folds every card; a hop to Topology folds them and drops the pick
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        FlexibleLatticeButton.caret(chrome: s.chrome, hooks: hooks)
        var about = false
        FlexibleStageCapsule.perform(.about, chrome: s.chrome, go: { _ in }, about: { about = true })
        XCTAssertTrue(about)
        XCTAssertNil(s.chrome.open, "★ I1: About Flexible… folds every card")
        var went: WorkspaceStage?
        s.chrome.toggle(.setup)
        FlexibleStageCapsule.perform(.topology, chrome: s.chrome, go: { went = $0 }, about: {})
        XCTAssertEqual(went, .topology)
        XCTAssertNil(s.chrome.open, "★ I1: a hop folds every card")
        s.apply(p, owned: false, pageUp: false)
        XCTAssertTrue(s.facePick.scope.isNone, "★ I1: … and leaving the stage drops the pick")
        s.apply(p, owned: true, pageUp: false)

        // GRAVITY SETUP (the tray's Gravity [Change] — the closure the pair hands the tray): every card folds AND the pick goes
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        XCTAssertEqual(s.facePick.scope, .face(group: c, ref: r3), "premise: Face 3 picked again")
        s.chrome.toggle(.setup)
        var entered = false
        FlexibleSetupActions.changeGravity(chrome: s.chrome, tray: FlexibleSetupTrayState(),
                                           changeGravity: FlexibleCornerPair.gravityAction(main: s, then: { entered = true }))
        XCTAssertTrue(entered, "#354's gravity setup runs")
        XCTAssertNil(s.chrome.open, "★ I1: gravity setup folds every card")
        XCTAssertTrue(s.facePick.scope.isNone, "★ I1: … and clears the pick — no chip over the gravity picker (RED at 0e66bf47: Face 3's chip came back)")
        XCTAssertFalse(chipShown(s))

        // RED CONTROL: the chip outside the one-card rule — the tray and the chip both up
        FlexibleChromeState.controlChipOutsideTheRule = true
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        s.chrome.toggle(.setup)
        XCTAssertTrue(s.chrome.open == .setup && chipShown(s), "★ RED CONTROL: without the chip case the tray and the chip are both open")
    }

    // MARK: I2 — keep-outs across the batches

    func testTheKeepOutsAcrossTheBatchesAtSixViewports() throws {
        let chip = FlexibleFaceChipLayout.size(.member)
        var lines: [String] = []
        var controlHits = 0
        for (tag, v) in Self.viewports {
            let setupW: CGFloat = 220
            let pair = FlexibleChromeLayout.pair(viewport: v, setupWidth: setupW)
            let capsule = FlexibleChromeLayout.capsuleFrame(width: 262)
            let legend = Self.legend(v)
            // the open list: his three quiet lines (189 tall) where PageLeftModal centres it, and its whole REACH (it grows about its
            // centre to 465 pt, never above 2 × noteTop) — the second tier's keep-out
            let mid = (PageChrome.noteTop + v.height - PageChrome.edge) / 2 - 4
            let measured = CGRect(x: PageChrome.edge, y: mid - 94.5, width: PageChrome.panelWidth, height: 189)
            let list = FlexibleFaceChipLayout.listReach(measured: measured, viewport: v)
            XCTAssertTrue(list.contains(CGRect(x: PageChrome.edge, y: mid - 170.5, width: PageChrome.panelWidth, height: 341)) || mid - 170.5 < list.minY,
                          "\(tag): the reach holds the list grown with Group C open (341 tall about the same centre)")
            let column = FlexibleFaceChipLayout.selectionsColumn(viewport: v)
            // no panel open (the chip's own case: one card at a time hides it under a panel), then the tray (4 rows, 276) and the
            // card on Preview (412) as drawn, each capped under the legend — the keep-outs still hold the open panel
            for (name, h) in [("no panel", CGFloat(0)), ("tray", CGFloat(276)), ("card", CGFloat(412))] {
                let open = h > 0
                let panel = open ? FlexibleChromeLayout.panelFrame(viewport: v, contentHeight: h, legend: legend) : .zero
                func keep(_ sel: CGRect, panel: CGRect?) -> [CGRect] {
                    FlexibleFaceChipLayout.keepOuts(viewport: v, selections: sel, legend: legend, panel: panel, player: nil, setupWidth: setupW)
                }
                let keepColumn = keep(column, panel: open ? panel : nil), keepList = keep(list, panel: open ? panel : nil)
                var placed = 0, fellBack = 0
                for ax in stride(from: 0.30, through: 0.95, by: 0.13) {
                    for ay in stride(from: 0.25, through: 0.92, by: 0.13) {
                        let a = CGPoint(x: v.width * ax, y: v.height * ay)
                        let r = FlexibleFaceChipLayout.auto(size: chip, anchor: a, viewport: v, keepOut: keepColumn, fallback: keepList)
                        guard !FlexibleFaceChipLayout.hits(r, keepList) else { continue }   // no clear spot anywhere: the chrome's own dock
                        placed += 1
                        if FlexibleFaceChipLayout.hits(r, keepColumn) { fellBack += 1 }
                        for (k, f) in [("the open \(name)", open ? panel : .null), ("the capsule", capsule), ("the Setup chip", pair.setup),
                                       ("the Lattice button", pair.lattice), ("the Selections list", list),
                                       ("the views row and its note", FlexibleMainViewToggles.frame(viewport: v))] {
                            XCTAssertFalse(r.intersects(f), "★ I2 \(tag): the chip at \(a) is not on \(k) (\(r) vs \(f))")
                        }
                        if open {
                            let c = FlexibleFaceChipLayout.auto(size: chip, anchor: a, viewport: v, keepOut: keep(column, panel: nil), fallback: keep(list, panel: nil))
                            if c.intersects(panel) { controlHits += 1 }
                        }
                    }
                }
                // with no panel open (the only time the chip shows) it always finds a clear spot, the mini in portrait too
                if !open { XCTAssertGreaterThan(placed, 0, "★ I2 \(tag): the chip finds a clear spot") }
                // a chip let go on the pair slides off it (and off the open panel) wherever a clear spot exists
                let onPair = CGRect(x: pair.lattice.midX - chip.width / 2, y: pair.lattice.midY - chip.height / 2, width: chip.width, height: chip.height)
                let letGo = FlexibleFaceChipLayout.released(onPair, viewport: v, keepOut: keepColumn, fallback: keepList)
                if !open || !FlexibleFaceChipLayout.hits(letGo, keepList) {
                    for f in [pair.setup, pair.lattice, open ? panel : .null, list] { XCTAssertFalse(letGo.intersects(f), "★ I2 \(tag) \(name): let go on the pair, it slides off (\(letGo) vs \(f))") }
                }
                XCTAssertTrue(FlexibleFaceChipLayout.clamped(onPair, viewport: v).intersects(pair.lattice), "★ RED CONTROL \(tag): a let-go that only clamps stays on the pair")
                if tag == "minip", !open {
                    // RED CONTROL (found by this test at 0e66bf47): the 404 pt chip never fits beside the mini's 372 pt column —
                    // with the column alone nothing is clear: the chip fell back onto the views row, a let-go stayed on the pair
                    let alone = FlexibleFaceChipLayout.auto(size: chip, anchor: CGPoint(x: v.width * 0.6, y: v.height * 0.5), viewport: v, keepOut: keepColumn)
                    XCTAssertTrue(FlexibleFaceChipLayout.hits(alone, keepColumn), "★ RED CONTROL minip: the column alone leaves the chip no spot")
                    XCTAssertTrue(FlexibleFaceChipLayout.released(onPair, viewport: v, keepOut: keepColumn).intersects(pair.lattice),
                                  "★ RED CONTROL minip: with the column alone a let-go stays on the pair")
                    XCTAssertGreaterThan(fellBack, 0, "minip: the chip is placed by the fallback (the list as drawn)")
                }
                lines.append("\(tag) \(name) panel \(panel) placed \(placed) (by the list fallback \(fellBack)) · let go \(letGo)")
            }
            // the minimised Selections pill (≈ 158 wide: "› Selections 4") ≥ 12 from the Setup chip
            let pill = FlexibleChromeLayout.selectionsPill(viewport: v, width: 158)
            XCTAssertGreaterThanOrEqual(pair.setup.minX - pill.maxX, PageChrome.gap, "★ I2 \(tag): the minimised pill ≥ 12 pt from the Setup chip (\(pill) vs \(pair.setup))")
        }
        XCTAssertGreaterThan(controlHits, 0, "★ RED CONTROL: without the open panel among the keep-outs the chip lands on it")
        print("FLEX-R7D3-I2\n" + lines.joined(separator: "\n") + "\ncontrol hits \(controlHits)")
    }

    /// The main page's ONE legend (heat on, the Squish key: one row) where the page places it.
    static func legend(_ v: CGSize) -> CGRect? {
        let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)
        return FlexibleMainLegendLayout.placeMainCard(rows: 1, minimized: false, viewport: v, keepOut: keep)?.frame
    }

    // MARK: I3 — equality under load

    func testATypedDepthWithTheCardOpenIsOneNumberEverywhere() throws {
        let (_, p, s, c) = try stage()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let r3 = LatticeSelectableRef.face(group: c, face: 3), r5 = LatticeSelectableRef.face(group: c, face: 5)
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        s.pickGroup(c, project: p)
        FlexibleLatticeButton.caret(chrome: s.chrome, hooks: s.cornerHooks(openSquish: {}))
        XCTAssertEqual(s.chrome.open, .latticeCard, "premise: the card is open")
        // the group's "All 2" box, typed (one undo step) — while the card is open
        var sess = s.facePick
        FlexibleFaceCommits.setDepth(19.96, ref: nil, group: c, project: p, session: &sess)
        s.facePick = sess
        XCTAssertEqual(s.chrome.open, .latticeCard, "the card stays open under a typed value")
        for (r, f) in [(r3, 3), (r5, 5)] {
            let plane = p.latticeSlabDepthMM(r, in: c)
            let list = FlexibleLatticeHandles.boxNumber(plane, signed: false) + " mm"
            let handle = FlexibleLatticeHandles.depthText(plane)
            XCTAssertEqual(handle, "20.0 mm", "★ I3: the handle's text (\(r.key))")
            XCTAssertEqual(list, handle, "★ I3: the list's box = the handle's text")
            let drawn = try XCTUnwrap(s.volumes(p, on: .lattice, drilledIn: false).first { $0.volume.faceID == f })
            guard case .shell(let sh) = drawn.volume.shape else { return XCTFail("a face-prism is a shell") }
            XCTAssertEqual(FlexibleLatticeHandles.depthText(sh.reachedDepthMM), handle, "★ I3: the drawn prism (\(r.key))")
        }
        let one = FlexibleLatticeCard.previewLine(includes: p.latticeJobRegions().regions.filter { $0.role == .include })
        XCTAssertTrue(one.hasSuffix("\u{00B7} 20.0 mm"), "★ I3: the card's ① line says the same depth: '\(one)'")
        XCTAssertTrue(one.contains("Face 3 + Face 5"), "… naming the faces: '\(one)'")
    }

    // MARK: I4 — step ② says what goes to core

    final class Box { var said: [String] = [] }
    func texts<V: View>(_ v: V, size: CGSize = CGSize(width: 420, height: 900)) -> [String] {
        FlexibleSaid.recording = true
        defer { FlexibleSaid.recording = false }
        let box = Box()
        let hv = NSHostingView(rootView: v.onPreferenceChange(FlexibleSaidKey.self) { box.said = $0 }.environment(\.colorScheme, .dark))
        hv.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: hv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = hv
        hv.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(0.3)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        w.contentView = nil
        return box.said
    }

    /// Every state × no hold: wherever the card offers [Send to core], the line above it says what goes.
    func testStepTwoSaysWhatGoesToCoreWheneverTheCardOffersASend() throws {
        let run = FlexibleCoreRun()
        let summary = "Group 1 \u{00B7} 22 lb \u{00B7} 1 face \u{00B7} bead 0.45 mm"
        var offered: [String] = []
        for st in FlexibleLatticeButton.State.allCases {
            let status: FlexibleMainStatus = st == .preview
                ? FlexibleMainStatus(line: "Face 4 has no lattice under it", tone: .preview, fix: nil)   // batch E's advisory: it still sends
                : FlexibleMainStatus(line: "Ready", tone: .ready, fix: nil)
            guard FlexibleLatticeCard.offersSend(state: st, run: run) else { continue }
            offered.append(st.rawValue)
            let shown = FlexibleLatticeCard.shownSummary(state: st, run: run, summary: { summary })
            XCTAssertEqual(shown, summary, "★ I4: the card offers [Send to core] on \(st) — it says what goes (RED at 0e66bf47 on Preview)")
            let said = texts(FlexibleLatticeCardView(run: run, status: status, state: st, preview: "built", width: 420, maxHeight: 900, summary: shown))
            XCTAssertTrue(said.contains("Send to core"), "premise: \(st) offers the send")
            XCTAssertTrue(said.contains(summary), "★ I4: \(st)'s card shows '\(summary)' above [Send to core] (said: \(said))")
        }
        XCTAssertEqual(Set(offered), ["ready", "preview"], "the card sends on Ready, and on a Preview with no hold")
        // nothing is offered while sending, so nothing is said
        XCTAssertNil(FlexibleLatticeCard.shownSummary(state: .sending, run: run, summary: { summary }))
    }

    /// On his pad (one squeeze group, his live weights, his bead): the summary IS the job core gets.
    func testTheSummaryIsTheJobOnHisPad() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        let end = Date().addingTimeInterval(180)
        while !(m.sceneState == .ready && !m.readiness.designing && !m.designsInFlight), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(m.sceneState, .ready, "premise: his pad's scene")
        // core takes ONE squeeze group (his three: keep the first, as the Ready evidence does)
        while m.squeezeGroups.count > 1, let last = m.squeezeGroups.last { m.removeGroup(last.id) }
        let summary = try XCTUnwrap(FlexibleLatticeCard.jobSummary(model: m), "★ I4: one group — the job is named")
        let job = try JSONSerialization.jsonObject(with: Data(try m.runJobJSON().utf8)) as? [String: Any]
        let flex = try XCTUnwrap(job?["flexible"] as? [String: Any])
        let faces = (flex["faces"] as? [[String: Any]] ?? []).filter { ($0["role"] as? String) == "loaded" }
        let newtons = faces.compactMap { $0["weight_n"] as? Double }.reduce(0, +)
        let bead = try XCTUnwrap(flex["min_extrudable_width_mm"] as? Double)
        let g = try XCTUnwrap(m.sentSqueezeGroups.first)
        let unit = m.weightUnit
        let weight = FlexibleRowCopy.squeezeValue((newtons / 9.80665)...(newtons / 9.80665), unit: unit)
        let hands = m.groupHands(g).count
        let expected = [FlexibleRowCopy.groupName(g.number), weight, hands == 1 ? "1 face" : "\(hands) faces",
                        String(format: "bead %.2f mm", bead)].joined(separator: " \u{00B7} ")
        XCTAssertEqual(summary, expected, "★ I4: the summary is the job — its group, its weight_n in his unit, its faces, its bead")
        XCTAssertEqual(unit, .lb, "premise: his Flexible unit")
        XCTAssertEqual(summary, "Group 1 \u{00B7} 22 lb \u{00B7} 1 face \u{00B7} bead 0.45 mm", "★ I4: the mockup's line, on his pad")
        // RED CONTROL: Topology's formatter (kg) is not what goes to core in his unit
        let topology = [FlexibleRowCopy.groupName(g.number), r.project.force.formattedWeight(kg: newtons / 9.80665), "1 face",
                        String(format: "bead %.2f mm", bead)].joined(separator: " \u{00B7} ")
        XCTAssertNotEqual(topology, summary, "★ RED CONTROL: '\(topology)' — Topology's unit — is caught")
        print("FLEX-R7D3-I4 summary '\(summary)' · job weight_n \(newtons) · bead \(bead) · loaded faces \(faces.count) · hands \(hands)")
    }

    // MARK: I5 — "Lattice ready" beside the icons

    func testLatticeReadySitsBesideTheIconsNeverUnderThem() throws {
        let listTop = 2 * PageChrome.noteTop   // PageLeftModal: padded noteTop, then a spacer of at least noteTop
        for (tag, v) in Self.viewports {
            let row = FlexibleMainViewToggles.rowFrame(viewport: v), note = FlexibleMainViewToggles.noteFrame(viewport: v)
            XCTAssertLessThan(note.minY, row.maxY, "★ I5 \(tag): the note is on the row's line, never under the icons (note \(note) · row \(row))")
            XCTAssertLessThanOrEqual(note.maxX, row.minX - DS.Space.s + 0.5, "★ I5 \(tag): left of the icons, \(DS.Space.s) pt clear")
            XCTAssertGreaterThanOrEqual(note.width, FlexibleMainNote.minWidth, "★ I5 \(tag): whole ('Lattice ready · Show')")
            XCTAssertGreaterThanOrEqual(note.minX, PageChrome.edge - 0.5, "\(tag): on screen")
            let capsule = FlexibleChromeLayout.capsuleFrame(width: FlexibleChromeLayout.capsuleMaxWidth)
            XCTAssertFalse(note.intersects(capsule), "\(tag): off the capsule")
            XCTAssertFalse(note.intersects(FlexibleLegendPlacement.gizmoFrame(viewport: v)), "\(tag): off the cube")
            if note.minX < FlexibleMainLegendLayout.leftStrip(viewport: v).maxX {
                XCTAssertLessThan(note.maxY, listTop, "★ I5 \(tag): over the Selections column only above the list's highest top (\(listTop))")
            }
            if let l = Self.legend(v) { XCTAssertFalse(l.intersects(note), "★ I5 \(tag): off the legend (\(l))") }
        }
        // 11" portrait: the legend comes up to the views row (the note no longer reserves a band under it) — the mockup's 292
        let v11 = CGSize(width: 834, height: 1194)
        let l11 = try XCTUnwrap(Self.legend(v11))
        XCTAssertEqual(l11.minY, FlexibleMainViewToggles.rowFrame(viewport: v11).maxY + FlexibleLegendPlacement.gap, accuracy: 4,
                       "★ I5 11p: the legend right under the views row")
    }

    // MARK: I6 — no panel covers the legend

    func testNoPanelEverCoversTheLegend() throws {
        var lines: [String] = []
        for (tag, v) in Self.viewports {
            guard let legend = Self.legend(v) else { XCTFail("\(tag): a legend"); continue }
            for (name, h) in [("tray", CGFloat(276)), ("card", CGFloat(412)), ("callout", CGFloat(200)), ("a tall card", CGFloat(1200))] {
                let f = FlexibleChromeLayout.panelFrame(viewport: v, contentHeight: h, legend: legend)
                XCTAssertFalse(f.intersects(legend), "★ I6 \(tag): the \(name) \(f) never covers the legend \(legend)")
                XCTAssertFalse(f.intersects(FlexibleMainViewToggles.frame(viewport: v)), "\(tag): nor the views row and its note")
                lines.append("\(tag) \(name) \(f.minY)…\(f.maxY) legend \(legend.minY)…\(legend.maxY)")
            }
        }
        // RED CONTROL: capped by the views row alone (D1's first build) the 11" landscape card covers the legend
        let v = CGSize(width: 1194, height: 834)
        let legend = try XCTUnwrap(Self.legend(v))
        let first = FlexibleChromeLayout.panelFrame(viewport: v, contentHeight: 412, legend: nil)
        XCTAssertTrue(first.intersects(legend), "★ RED CONTROL: the card capped by the views row alone covers the 11\" landscape legend")
        print("FLEX-R7D3-I6\n" + lines.joined(separator: "\n"))
    }
}
#endif
