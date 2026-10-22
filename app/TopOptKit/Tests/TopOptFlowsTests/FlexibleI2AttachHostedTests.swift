// FlexibleI2AttachHostedTests — round 7 · U21 batch I, part I2, the hosted half: the WHOLE app page (WorkspacePlaceholder)
// offscreen at 13" portrait on HIS l-bracket (round7/batch_u21/his_live_1021_lbracket, as saved: Group B · Face 6, box 33.5,
// expand −3). His answer of 2026-10-21 ~15:35: "Make it so when you select the lattice in the selections, it is an option/tool
// in the dragable modal, once clicked, it shows the lattice on its own, you select a wall, then it shows the model with the
// lattice as a ghost and you select the face it is meant to connect to. And you should be able to do this multiple times per
// lattice object." Every RED control is asserted red inside its test. Pictures (13" portrait) only with FLEX_I2_DIR=<dir>.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class I2Win: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleI2AttachHostedTests: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_I2_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376)
    static let p11 = CGSize(width: 834, height: 1194)
    nonisolated static let groupA = UUID(uuidString: "ECD45F72-7207-46A3-9F42-D4CF428F306A")!
    nonisolated static let groupB = UUID(uuidString: "B91ED058-A180-4125-8E82-420B89D45B79")!
    nonisolated static var face6: LatticeSelectableRef { .face(group: groupB, face: 6) }
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    override func tearDown() {
        FlexibleAttach.controlAttachEverywhere = false
        FlexibleAttach.controlAttachKeepsTheView = false
        FlexibleAttach.controlNoGhostInStepTwo = false
        FlexibleAttach.controlStrayTapCancels = false
        FlexibleAttach.controlTagsPlacedOnce = false
        FlexibleAttach.controlAttachUsesMemberSize = false
        FlexibleFaceCommits.controlUnsealedLinkWrite = false
        FlexibleConfirmInPlace.controlOldPlacement = false
        super.tearDown()
    }

    /// His l-bracket on the Flexible Lattice page, Group B · Face 6 picked from the model.
    func hisLBracket(size: CGSize = p13) throws -> (FlexibleHisProject.Restored, Host, FlexibleMainStage) {
        Bundle.r7m1vSwap
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let p = r.project
        XCTAssertEqual(p.latticeSelectableRole(Self.face6, in: Self.groupB), .include, "premise: Face 6 is Group B's lattice")
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        if h.frames.all["capsule"] == nil {
            click(h, CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2))
            pump(3)
        }
        let s = try XCTUnwrap(FlexibleMainStage.lastMade, "the page's stage")
        addTeardownBlock { @MainActor in s.endAttach(); await s.model?.waitForIdle() }
        XCTAssertNotNil(h.frames.all["capsule"], "premise: the Flexible stage")
        s.tapFace(p, face: 6, point: nil, mesh: try XCTUnwrap(p.viewerMesh))
        pump(1.5)
        return (r, h, s)
    }

    func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    func tap(_ h: Host, _ key: String, _ what: String) throws {
        let f = try XCTUnwrap(h.frames.all[key], what)
        click(h, centre(f))
    }
    func startAttach(_ h: Host, _ s: FlexibleMainStage) throws {
        try tap(h, "chipAttach", "the card's [Attach]")
        pump(1.2)
        XCTAssertEqual(s.attach.step, .pickWall, "step 1")
    }

    // MARK: a — only on a lattice face

    func testAttachOnlyOnALatticeFace() throws {
        let (r, h, s) = try hisLBracket()
        let p = r.project
        XCTAssertNotNil(h.frames.all["chipAttach"], "★ Group B · Face 6 has [Attach]")
        XCTAssertNotNil(h.frames.all["chipAttachSuggest"], "★ and the one-tap suggestion (inset −3)")
        XCTAssertNil(p.lattice.flexible?.links, "nothing set until he taps")
        try shot("I2_01_13p_lbracket_face6_card_attach_and_suggestion.png", h)
        // Face 6 Solid: none
        FlexibleFaceCommits.setState(.exclude, ref: Self.face6, group: Self.groupB, project: p)
        pump(1.2)
        XCTAssertNil(h.frames.all["chipAttach"], "★ Face 6 Solid: no Attach")
        // ★ RED CONTROL: the row on every face card
        FlexibleAttach.controlAttachEverywhere = true
        s.objectWillChange.send(); pump(1.0)
        XCTAssertNotNil(h.frames.all["chipAttach"], "★ RED: Attach on a Solid face")
        FlexibleAttach.controlAttachEverywhere = false
        FlexibleFaceCommits.setState(.include, ref: Self.face6, group: Self.groupB, project: p); pump(1.2)
        XCTAssertNotNil(h.frames.all["chipAttach"], "Lattice again: Attach back")
        // a drilled-in legend: none
        s.noteDrill(true); pump(1.0)
        XCTAssertNil(h.frames.all["chipAttach"], "★ a drilled-in legend: no Attach")
        s.noteDrill(false); pump(1.0)
        // Group A (five faces, picked whole): none
        s.pickGroup(Self.groupA, project: p); pump(1.2)
        XCTAssertNil(h.frames.all["chipAttach"], "★ Group A: no Attach")
        flush("I2_hosted_a.txt")
    }

    // MARK: b — step 1, the lattice alone

    func testStepOneShowsTheLatticeAlone() throws {
        let (r, h, s) = try hisLBracket()
        let p = r.project
        let handle = "handleDisc-handle-depth-\(Self.face6.key)"
        XCTAssertNotNil(h.frames.all[handle], "premise: the depth handle before Attach")
        try startAttach(h, s)
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 0, "★ no body: the lattice on its own")
        XCTAssertNotEqual(s.layer(p, stage: .lattice, pageUp: false)?.printed, true, "★ not the printed view")
        XCTAssertTrue(s.volumes(p, on: .lattice, drilledIn: false).isEmpty, "★ no prism glass")
        XCTAssertNil(h.frames.all[handle], "★ the handles hide")
        // nothing of the part flagged opaque (the closed body, the pressed face's heat lid): at alpha 0 it all goes
        try FlexibleHisProject.waitForSync(30, "the overlay") { s.overlay != nil }
        func opaque() throws -> Int { let t = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil)); return (0..<t.count / 8).filter { t[$0 * 8 + 5] > 0.5 }.count }
        XCTAssertEqual(try opaque(), 0, "★ no surface of the part drawn in step 1")
        for n in 1...4 { XCTAssertNotNil(h.frames.all["attachTag-side\(n)"], "★ the Side \(n) tag on the model") }
        XCTAssertNil(h.frames.all["attachTag-floor"], "no floor tag (the lattice runs through)")
        XCTAssertNotNil(h.frames.all["attachChip-side1"], "the chips on the card")
        // the views row is inert: [Prisms] does nothing
        let prismsBefore = s.prismsOn
        try tap(h, "mainView-prisms", "the Prisms icon")
        XCTAssertEqual(s.prismsOn, prismsBefore, "★ the views row is inert")
        XCTAssertTrue(s.attach.active)
        // one lattice on his bracket: drawn as it is (the others would be ghosted — FlexibleMainStage.attachGhosts)
        XCTAssertNotEqual(s.layer(p, stage: .lattice, pageUp: false)?.ghostWalls, true, "one lattice: not ghosted")
        log.append("b: tags \((1...4).map { h.frames.all["attachTag-side\($0)"].map { "\(Int($0.midX)),\(Int($0.midY))" } ?? "-" })")
        try shot("I2_02_13p_lbracket_step1_lattice_alone.png", h)
        // ★ RED CONTROL: the step changes nothing in the view (his finish None: the printed view, its prisms and handles)
        FlexibleAttach.controlAttachKeepsTheView = true
        s.objectWillChange.send(); pump(1.0)
        XCTAssertNotNil(h.frames.all[handle], "★ RED: the handles still there")
        XCTAssertNil(h.frames.all["attachTag-side1"], "★ RED: no walls drawn")
        XCTAssertGreaterThan(try opaque(), 0, "★ RED: the closed body still flagged opaque")
        flush("I2_hosted_b.txt")
    }

    // MARK: c — step 2, the model and the ghost

    func testStepTwoShowsTheModelAndTheGhost() throws {
        let (r, h, s) = try hisLBracket()
        let p = r.project
        try startAttach(h, s)
        try tap(h, "attachTag-side2", "the Side 2 tag")
        pump(1.2)
        XCTAssertEqual(s.attach.step, .pickTarget(wall: "side:f7"), "step 2 for Side 2")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), 1, "★ the model opaque (X-ray off)")
        // (a built lattice: the pass ghosts it; none built yet: the overlay draws its walls at the ghost alpha)
        if let l = s.layer(p, stage: .lattice, pageUp: false) { XCTAssertTrue(l.ghostWalls, "★ the lattice as a ghost") } else { log.append("c: no lattice built yet — the overlay's ghost") }
        let tags = h.frames.all.keys.filter { $0.hasPrefix("attachTag-") }
        XCTAssertEqual(tags, ["attachTag-target-wall"], "★ exactly one lit target: [wall]")
        // every model face that is not a target: dimmed
        try FlexibleHisProject.waitForSync(30, "the overlay") { s.overlay != nil }
        let t = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil), "the tints")
        let n = t.count / 8
        let dim = FlexibleMainStage.attachDim
        let dimmed = (0..<n).filter { SIMD4(t[$0 * 8], t[$0 * 8 + 1], t[$0 * 8 + 2], t[$0 * 8 + 3]) == dim }.count
        log.append("c: \(dimmed) of \(n) vertices dimmed")
        XCTAssertEqual(dimmed, n, "★ every non-target face dimmed (no skin target on his None finish)")
        // X-ray stays his and live
        try tap(h, "mainView-xray", "the X-ray icon")
        XCTAssertTrue(s.xrayOn, "★ X-ray live in step 2")
        XCTAssertEqual(s.bodyAlpha(p, on: .lattice), FlexibleStagePage.xrayBodyAlpha, "his X-ray alpha")
        try tap(h, "mainView-xray", "X-ray off again")
        try shot("I2_03_13p_lbracket_step2_side2_wall_lit.png", h)
        // ★ RED CONTROL: no ghost and no dim
        FlexibleAttach.controlNoGhostInStepTwo = true
        s.objectWillChange.send(); pump(0.8)
        XCTAssertNotEqual(s.layer(p, stage: .lattice, pageUp: false)?.ghostWalls, true, "★ RED: no ghost")
        let rt = try XCTUnwrap(s.tints(p, on: .lattice, roles: [:], stress: nil))
        XCTAssertLessThan((0..<n).filter { SIMD4(rt[$0 * 8], rt[$0 * 8 + 1], rt[$0 * 8 + 2], rt[$0 * 8 + 3]) == dim }.count, n, "★ RED: not dimmed")
        flush("I2_hosted_c.txt")
    }

    // MARK: d — two steps make one link

    func testTwoStepsMakeOneLink() throws {
        let (r, h, s) = try hisLBracket()
        let p = r.project
        func makeLink() throws {
            try startAttach(h, s)
            try tap(h, "attachTag-side2", "Side 2")
            pump(0.8)
            p.writeLatticeDepthMM(Self.face6, mm: 33.0)   // an edit made just before it (a drag: unsealed, still settling)
            try tap(h, "attachTag-target-wall", "[wall]")
            pump(1.2)
        }
        try makeLink()
        XCTAssertEqual(p.lattice.flexible?.links?.map { "\($0.wall)|\($0.target)" }, ["side:f7|wall"], "★ one link")
        XCTAssertEqual(s.attach.step, .pickWall, "back to step 1 for the next wall")
        XCTAssertEqual(s.attach.say, "Linked Side 2 → wall")
        let id = try XCTUnwrap(p.lattice.flexible?.links?.first?.id).uuidString
        XCTAssertNotNil(h.frames.all["selLink-\(id)"], "★ listed under Face 6 in Selections")
        try tap(h, "attachEnd", "[Done]")
        pump(1.0)
        XCTAssertFalse(s.attach.active)
        if case let .button(right, _) = s.attachRow(p, group: Self.groupB, ref: Self.face6) { XCTAssertEqual(right, "1 linked") } else { XCTFail("the row") }
        XCTAssertTrue(p.canUndoNow)
        p.performUndo(); pump(0.6)
        XCTAssertNil(p.lattice.flexible?.links, "★ one Undo: the link")
        XCTAssertEqual(p.latticeSlabDepthMM(Self.face6, in: Self.groupB), 33.0, accuracy: 1e-9, "★ …only the link (its own step)")
        p.performUndo(); pump(0.6)
        // ★ RED CONTROL: an unsealed link write folds into the depth edit before it
        FlexibleFaceCommits.controlUnsealedLinkWrite = true
        let before = p.latticeSlabDepthMM(Self.face6, in: Self.groupB)
        try makeLink()
        s.endAttach()
        p.performUndo(); pump(0.6)
        XCTAssertNil(p.lattice.flexible?.links)
        XCTAssertEqual(p.latticeSlabDepthMM(Self.face6, in: Self.groupB), before, accuracy: 1e-9, "★ RED: one Undo reverted the depth edit too")
        flush("I2_hosted_d.txt")
    }

    // MARK: e — a stray tap keeps the step

    func testAStrayTapKeepsTheStep() throws {
        let (r, h, s) = try hisLBracket()
        let p = r.project
        let mesh = try XCTUnwrap(p.viewerMesh)
        try startAttach(h, s)
        s.missTap(); pump(0.6)
        XCTAssertEqual(s.attach.step, .pickWall, "★ a miss keeps step 1")
        XCTAssertEqual(s.attach.say, "1 of 2 · Tap a wall of the lattice", "the say line only")
        // a tap on the plate's underside (Face 5) — off every wall
        let under = SIMD3<Float>(-50, 0, 0)
        s.tapFace(p, face: 5, point: under, mesh: mesh); pump(0.8)
        XCTAssertEqual(s.attach.step, .pickWall, "★ a canvas tap off every wall keeps step 1")
        XCTAssertNotNil(h.frames.all["attachCard"], "the step card stays")
        // ★ RED CONTROL: today's routing — the tap runs the face pick
        FlexibleAttach.controlStrayTapCancels = true
        s.tapFace(p, face: 5, point: under, mesh: mesh); pump(1.0)
        XCTAssertFalse(s.attach.active, "★ RED: Attach is gone")
        XCTAssertNil(h.frames.all["attachCard"], "★ RED: the card is the face card again")
        flush("I2_hosted_e.txt")
    }

    // MARK: f — the link's trash asks in place

    func testLinkTrashAsksInPlace() throws {
        let (r, h, s) = try hisLBracket()
        let p = r.project
        s.applySuggestion(p, group: Self.groupB, ref: Self.face6)
        pump(1.5)
        let links = try XCTUnwrap(p.lattice.flexible?.links)
        XCTAssertEqual(links.count, 4)
        let id = links[1].id.uuidString
        let trash = try XCTUnwrap(h.frames.all["selLinkTrash-\(id)"], "the link's trash")
        click(h, centre(trash))
        XCTAssertEqual(s.faceUI.linkRemoveAsk, links[1].id, "the ask")
        let keep = try XCTUnwrap(h.frames.all["linkKeep-\(id)"], "[Keep]"), red = try XCTUnwrap(h.frames.all["linkRemove-\(id)"], "[Remove]")
        log.append("f: trash \(trash) keep \(keep) remove \(red)")
        XCTAssertEqual(keep.midX, trash.midX, accuracy: 1, "★ Keep on the tapped spot")
        XCTAssertEqual(keep.midY, trash.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(red.maxX, keep.minX - 24 + 0.5, "★ Remove ≥ 24 pt to its left")
        XCTAssertEqual(p.lattice.flexible?.links?.count, 4, "★ nothing removed before the confirm")
        try shot("I2_04_13p_lbracket_selections_4_links_trash_asks.png", h)
        click(h, centre(red)); pump(0.8)
        XCTAssertEqual(p.lattice.flexible?.links?.count, 3, "[Remove] removes it")
        // ★ RED CONTROL: D's old placement — Keep is not on the tapped spot
        FlexibleConfirmInPlace.controlOldPlacement = true
        let id2 = links[2].id.uuidString
        let t2 = try XCTUnwrap(h.frames.all["selLinkTrash-\(id2)"])
        click(h, centre(t2))
        let k2 = try XCTUnwrap(h.frames.all["linkKeep-\(id2)"])
        XCTAssertGreaterThan(abs(k2.midX - t2.midX), 1, "★ RED: Keep off the tapped spot")
        flush("I2_hosted_f.txt")
    }

    // MARK: g — the tags follow the camera

    func testTagsFollowTheCamera() throws {
        let (r, h, s) = try hisLBracket()
        let p = r.project
        try startAttach(h, s)
        let card0 = try XCTUnwrap(h.frames.all["attachCard"])
        func check(_ label: String) throws -> Int {
            let w = try XCTUnwrap(s.attachWalls(p, key: Self.face6.key))
            let f = try XCTUnwrap(s.viewFrame, "the view's projector")
            var outside = 0
            var pts: [CGPoint] = []
            for x in w.sides {
                let tag = try XCTUnwrap(h.frames.all["attachTag-side\(x.number)"], "\(label): Side \(x.number)'s tag")
                let c = centre(tag)
                pts.append(c)
                let inside = x.quads.contains { q in
                    let poly = q.compactMap { f.project(SIMD3<Float>($0)) }
                    return poly.count == 4 && (FlexibleAttach.inside(c, poly) || poly.indices.contains { i in
                        let a = poly[i], b = poly[(i + 1) % 4]
                        let d = CGPoint(x: b.x - a.x, y: b.y - a.y), l2 = d.x * d.x + d.y * d.y
                        let t = l2 > 0 ? max(0, min(1, ((c.x - a.x) * d.x + (c.y - a.y) * d.y) / l2)) : 0
                        return hypot(a.x + d.x * t - c.x, a.y + d.y * t - c.y) <= 2
                    })
                }
                if !inside { outside += 1 }
            }
            for i in pts.indices { for j in pts.indices where j > i { XCTAssertGreaterThanOrEqual(hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y), 24, "\(label): tags apart") } }
            log.append("g \(label): tags \(pts.map { "\(Int($0.x)),\(Int($0.y))" }) · outside their wall \(outside)")
            return outside
        }
        XCTAssertEqual(try check("front"), 0, "each tag on its wall")
        let cm = try XCTUnwrap(cameraModel(h), "the page's camera")
        var c = cm.camera
        c.setOrientation(azimuth: c.azimuth + 1.047, elevation: c.elevation)
        c.zoom(1.25)
        cm.adopt(c)
        pump(2)
        XCTAssertEqual(try check("orbit 60° + pinch"), 0, "★ after an orbit and a pinch each tag still on its wall")
        XCTAssertEqual(try XCTUnwrap(h.frames.all["attachCard"]).origin, card0.origin, "★ the card did not move")
        // ★ RED CONTROL: tags placed once at the step's start
        FlexibleAttach.controlTagsPlacedOnce = true
        s.endAttach(); pump(0.6)
        cm.adopt({ var k = cm.camera; k.setOrientation(azimuth: k.azimuth - 1.047, elevation: k.elevation); return k }()); pump(1.5)
        try startAttach(h, s)
        cm.adopt({ var k = cm.camera; k.setOrientation(azimuth: k.azimuth + 1.047, elevation: k.elevation); return k }()); pump(2)
        XCTAssertGreaterThan(try check("RED placed once"), 0, "★ RED: after the orbit the tags sit off their walls")
        flush("I2_hosted_g.txt")
    }

    // MARK: h — the card fits

    func testTheCardFits() throws {
        // the sweep (FlexibleFaceChipTests' 13" / 11"): the step card's automatic spot inside and clear of the chrome
        for v in [Self.p13, Self.p11, CGSize(width: Self.p13.height, height: Self.p13.width), CGSize(width: Self.p11.height, height: Self.p11.width)] {
            for k in [FlexibleFaceChipLayout.Kind.attach(chipLines: 1, say: false), .attach(chipLines: 2, say: true), .memberAttach(rows: 2)] {
                let size = FlexibleFaceChipLayout.size(k)
                let keep = FlexibleFaceChipLayout.keepOuts(viewport: v, selections: nil, legend: nil, panel: nil, player: nil)
                let r = FlexibleFaceChipLayout.auto(size: size, anchor: CGPoint(x: v.width * 0.6, y: v.height * 0.55), viewport: v, keepOut: keep)
                XCTAssertTrue(FlexibleFaceChipLayout.inside(r, v), "\(k) at \(v): inside")
                XCTAssertFalse(FlexibleFaceChipLayout.hits(r, keep), "\(k) at \(v): clear of the chrome")
            }
        }
        // drawn: the step card no taller than its kind's height (placement never runs it onto a keep-out)
        let (r, h, s) = try hisLBracket()
        let p = r.project
        try startAttach(h, s)
        try tap(h, "attachTag-side2", "Side 2"); pump(0.6)
        s.missTap(); pump(0.8)   // the say line too
        let chip = try XCTUnwrap(h.frames.all["faceChip"], "the card")
        let est = FlexibleFaceChipLayout.size(FlexibleFaceChip.kind(s.facePick.scope, project: p, lastGroup: s.facePick.lastGroup, main: s)).height
        log.append("h: drawn \(chip.height) · estimated \(est)")
        XCTAssertLessThanOrEqual(chip.height, est + 1, "★ the step card's drawn height within its kind's")
        XCTAssertTrue(CGRect(origin: .zero, size: Self.p13).insetBy(dx: 15, dy: 15).contains(chip), "★ inside the screen")
        // ★ RED CONTROL: Kind .attach measured as .member — the estimate is short of the drawn card
        FlexibleAttach.controlAttachUsesMemberSize = true
        let red = FlexibleFaceChipLayout.size(FlexibleFaceChip.kind(s.facePick.scope, project: p, lastGroup: s.facePick.lastGroup, main: s)).height
        XCTAssertGreaterThan(chip.height, red + 1, "★ RED: placed as .member, the card's buttons would run past its spot")
        flush("I2_hosted_h.txt")
    }

    // MARK: - harness (FlexibleR7U21CHandlesHostedTests')

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = I2Win(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, frames: frames)
    }
    func event(_ h: Host, _ t: NSEvent.EventType, _ p: CGPoint) {
        let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.window.sendEvent(e)
    }
    func click(_ h: Host, _ p: CGPoint) {
        event(h, .leftMouseDown, p); pump(0.06)
        event(h, .leftMouseUp, p); pump(0.8)
    }
    func mtkViews(_ v: NSView) -> [MTKView] {
        var out: [MTKView] = []
        if let m = v as? MTKView { out.append(m) }
        for s in v.subviews { out += mtkViews(s) }
        return out
    }
    func stageMTK(_ h: Host) -> MTKView? {
        mtkViews(h.view).filter { $0.delegate is MeshRenderer }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
    func cameraModel(_ h: Host) -> OrbitCameraModel? {
        guard let mtk = stageMTK(h) else { return nil }
        for g in mtk.gestureRecognizers {
            guard let t = g.target else { continue }
            for c in Mirror(reflecting: t).children where c.label == "cameraModel" {
                if let cm = c.value as? OrbitCameraModel { return cm }
            }
        }
        return nil
    }
    func flush(_ file: String) {
        print("FLEX-I2 " + log.joined(separator: "\n  "))
        if let d = Self.dir { try? (log.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }
    func writePNG(_ img: CGImage, _ name: String) throws {
        guard let dir = Self.dir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// The page as he sees it: its renderer offscreen under the hosted chrome (FlexibleR7U21CHandlesHostedTests.shot).
    func shot(_ name: String, _ h: Host, settle: Double = 0.8) throws {
        pump(settle)
        guard Self.dir != nil else { return }
        let hv = h.view
        hv.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hv.bitmapImageRepForCachingDisplay(in: hv.bounds))
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let PW = cg.width, PH = cg.height
        let scale = CGFloat(PW) / h.size.width
        var chrome = [UInt8](repeating: 0, count: PW * PH * 4)
        let cctx0 = try XCTUnwrap(CGContext(data: &chrome, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cctx0.draw(cg, in: CGRect(x: 0, y: 0, width: PW, height: PH))
        let bg = DS.Color.background
        let gr = Int((bg.r * 255).rounded()), gg = Int((bg.g * 255).rounded()), gb = Int((bg.b * 255).rounded())
        var probe = (0, 0, 0, 0)
        var modelImg: CGImage?
        var placed = CGRect.zero
        if let mtk = stageMTK(h), let r = mtk.delegate as? MeshRenderer {
            var vf = mtk.convert(mtk.bounds, to: hv)
            if !hv.isFlipped { vf.origin.y = hv.bounds.height - vf.maxY }
            let cx = Int(vf.midX * scale), cy = Int(vf.midY * scale)
            let i = (cy * PW + cx) * 4
            probe = (Int(chrome[i]), Int(chrome[i + 1]), Int(chrome[i + 2]), Int(chrome[i + 3]))
            if probe.0 + probe.1 + probe.2 > 60 { probe = (0, 0, 0, 0) }
            let saved = r.camera
            var cam = saved
            let W = vf.width, H = vf.height
            let side: CGFloat
            if W > H { cam.fovY = 2 * atan(tan(saved.fovY / 2) * Float(W / H)); side = W } else { side = H }
            r.camera = cam
            let n = Int((side * scale).rounded())
            let px = r.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
            r.camera = saved
            if var m = px {
                for k in stride(from: 0, to: m.count, by: 4) { m.swapAt(k, k + 2); m[k + 3] = 255 }
                let mctx = try XCTUnwrap(CGContext(data: &m, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                modelImg = mctx.makeImage()
                placed = CGRect(x: (vf.midX - side / 2) * scale, y: (h.size.height - vf.midY - side / 2) * scale, width: side * scale, height: side * scale)
            }
        }
        for k in stride(from: 0, to: chrome.count, by: 4) {
            let a = chrome[k + 3]
            let isBG = abs(Int(chrome[k]) - gr) <= 3 && abs(Int(chrome[k + 1]) - gg) <= 3 && abs(Int(chrome[k + 2]) - gb) <= 3 && a == 255
            let isProbe = probe.3 > 0 && abs(Int(chrome[k]) - probe.0) <= 2 && abs(Int(chrome[k + 1]) - probe.1) <= 2 && abs(Int(chrome[k + 2]) - probe.2) <= 2 && Int(a) == probe.3
            if isBG || isProbe { chrome[k] = 0; chrome[k + 1] = 0; chrome[k + 2] = 0; chrome[k + 3] = 0 }
        }
        let cctx = try XCTUnwrap(CGContext(data: &chrome, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cimg = try XCTUnwrap(cctx.makeImage())
        let out = try XCTUnwrap(CGContext(data: nil, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        out.setFillColor(CGColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: PW, height: PH))
        if let mi = modelImg { out.draw(mi, in: placed) }
        out.draw(cimg, in: CGRect(x: 0, y: 0, width: PW, height: PH))
        try writePNG(try XCTUnwrap(out.makeImage()), name)
    }
}

extension FlexibleHisProject {
    /// Pumps the run loop until `cond` (a hosted test's wait).
    static func waitForSync(_ timeout: Double, _ what: String, _ cond: () -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); return }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
#endif
