// Notes25SmallTests — builder D ("small") for his iPad notes 2026-11-23 evening (img 1 … 9) and 362's D8, D9:
//   D1 Continue and the part page's button pick the version or draft he last opened or changed;
//   D2 a tap anywhere on a version card opens it;
//   D3 the "100 % … is solid" notice on the screen's centre line at the foot;
//   D4 "Cannot Lattice" when nothing of the lattice he asked for can be laid;
//   D5 nothing drawn cut off at the screen's edge while the thin-wall pop-up is up (it was the new engine's stack, 0 pt wide);
//   D6 "Will likely lose strength" once;
//   D7 each group's sample kept: an unchanged group shows at once, a change builds;
//   D8 the thin-wall pop-up's three reasons, each with its (i), what Aesthetic does, and Learn more;
//   D9 the Runs on ⚠ follows the Mac's live /health, with plain words.
// His two iPad sizes: 13″ landscape and 11″ portrait.
import XCTest
import SwiftUI
import Network
@testable import TopOptFlows
@testable import TopOptKit
#if canImport(AppKit)
import AppKit
#endif

private let hisSizes: [(String, CGSize)] = [("13L", AppBuildHost.landscape13), ("11P", AppBuildHost.portrait11)]

// MARK: - D1 (the rule)

final class Notes25ContinueTests: XCTestCase {
    private func v(_ n: String, parent: String? = nil) -> LibraryVersion {
        LibraryVersion(folderID: UUID(), number: VersionNumber(n)!, parentNumber: parent.flatMap { VersionNumber($0) })
    }

    /// His Library at 5:36 PM: 2040 Extrusion Stand's v5 draft (Nov 21), v6, v7, v8 with results (Nov 23, today); another
    /// part's newer-numbered draft from long ago. Continue offers v8 — the one he last worked on — not the newest DRAFT (v5),
    /// and the part page's button opens v8, not the highest-numbered draft.
    func testTheLastOpenedOrChangedWinsAcrossPartsAndKinds() {
        func day(_ d: Double, _ h: Double = 12) -> Date { Date(timeIntervalSince1970: 1_793_000_000 + d * 86_400 + h * 3_600) }
        let v4 = v("4"), v5 = v("5", parent: "4"), v6 = v("6"), v7 = v("7"), v8 = v("8"), v17 = v("1.7", parent: "1")
        let stand = LibraryPart(name: "2040 Extrusion Stand", modelHash: "a", versions: [v4, v5, v6, v7, v8, v17])
        let other = v("9")
        let arms = LibraryPart(name: "CarriageArms", modelHash: "b", versions: [other])
        var when: [UUID: Date] = [v4.folderID: day(18), v5.folderID: day(21), v6.folderID: day(23, 9), v7.folderID: day(23, 10),
                                  v8.folderID: day(23, 11), v17.folderID: day(21, 8), other.folderID: day(2)]
        let drafts: Set<UUID> = [v4.folderID, v5.folderID, v17.folderID, other.folderID]
        func changed(_ x: LibraryVersion) -> Date { when[x.folderID] ?? .distantPast }

        let home = LibraryContinue.pick([arms, stand], changed: changed)
        XCTAssertEqual(home?.v.folderID, v8.folderID, "★ Continue: the version he last worked on (v8), a version with results")
        XCTAssertEqual(home?.part.name, "2040 Extrusion Stand")
        XCTAssertEqual(LibraryContinue.pick(in: stand, changed: changed)?.folderID, v8.folderID, "★ the part page's button: v8")
        // RED CONTROL: the old rules — the newest DRAFT (home), the highest-numbered draft (the part page) — chose v5
        let oldHome = [arms, stand].flatMap(\.versions).filter { drafts.contains($0.folderID) }.max { changed($0) < changed($1) }
        XCTAssertEqual(oldHome?.folderID, v5.folderID, "control: the old Continue offered v5 draft")
        let oldPart = stand.versions.filter { drafts.contains($0.folderID) }.max { $0.number < $1.number }
        XCTAssertEqual(oldPart?.folderID, v5.folderID, "control: the old button opened v5 draft")

        // he opens the v5 draft and leaves it: it is the last one now, on both
        when[v5.folderID] = day(23, 18)
        XCTAssertEqual(LibraryContinue.pick([arms, stand], changed: changed)?.v.folderID, v5.folderID, "★ the draft he just left")
        XCTAssertEqual(LibraryContinue.pick(in: stand, changed: changed)?.folderID, v5.folderID)
        // the other part, changed later still: Continue goes there; this part's page still offers its own
        when[other.folderID] = day(23, 19)
        XCTAssertEqual(LibraryContinue.pick([arms, stand], changed: changed)?.part.name, "CarriageArms", "★ across parts")
        XCTAssertEqual(LibraryContinue.pick(in: stand, changed: changed)?.folderID, v5.folderID, "★ the part page: within its part")
        // the same moment: the higher number
        when[v6.folderID] = day(23, 18)
        XCTAssertEqual(LibraryContinue.pick(in: stand, changed: changed)?.folderID, v6.folderID, "same moment: the higher number")

        XCTAssertEqual(LibraryContinue.title(part: "2040 Extrusion Stand", number: VersionNumber("8")!, draft: false),
                       "Continue \u{00B7} 2040 Extrusion Stand v8")
        XCTAssertEqual(LibraryContinue.title(part: "2040 Extrusion Stand", number: VersionNumber("5")!, draft: true),
                       "Continue \u{00B7} 2040 Extrusion Stand v5 draft", "a draft as before")
        XCTAssertEqual(LibraryContinue.openTitle(number: VersionNumber("8")!, draft: false), "Open v8", "★ the page's own words")
        XCTAssertEqual(LibraryContinue.openTitle(number: VersionNumber("5")!, draft: true), "Open v5 draft")
        XCTAssertNil(LibraryContinue.pick([], changed: changed))
    }

    /// D6 (his img 9): "Will likely lose strength" said once — the setting's grey caption; the second line it had when on is gone.
    /// Depth variation's two lines were not his note then (★ notes26: his yes since — one line, Notes26DepthLineTests).
    func testExtraSpacingSaysLoseStrengthOnce() throws {
        let src = try FlexibleSource.code("LatticeOrganicControls.swift")
        XCTAssertFalse(src.contains("say(\"Will likely lose strength\")"), "★ the second line is gone")
        XCTAssertEqual(OrganicSettingsHelp.entry("Extra spacing between vines")?.grey, "Will likely lose strength.",
                       "★ the caption still says it, once")
        // ★ RE-PINNED (notes26, his yes to one line for Depth variation too): its second line is gone, as this one's
        XCTAssertFalse(src.contains("say(look.depthVariationValue ? \"Up to 1 mm out at open faces\" : \"Cut flush at every face\")"),
                       "Depth variation: one line now (Notes26DepthLineTests)")
    }
}

#if canImport(AppKit) && canImport(MetalKit)

// MARK: - D1, D2 (hosted, the Library)

@MainActor
final class Notes25LibraryHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notes25-lib-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    /// The lookalike part (LibraryPartRowsHostedTests.arms): v1 (results, t 100), v2 (results, 200), v3 (a draft, 300), v1.1
    /// (results, 400) — its results read.
    private func arms(_ tag: String, _ size: CGSize) throws -> (AppModel, [String: UUID]) {
        let (app, f) = try LibraryPartRowsHostedTests.arms(root: root.appendingPathComponent("\(tag)-\(Int(size.width))", isDirectory: true))
        let exp = expectation(description: "summaries")
        app.library.loadSummaries { exp.fulfill() }
        wait(for: [exp], timeout: 30)
        return (app, f)
    }

    private func wait(_ h: AppBuildHost, for key: String, seconds: Double = 6) -> CGRect? {
        var t = 0.0
        while h.frames.all[key] == nil, t < seconds { h.pump(0.25); t += 0.25 }
        return h.frames.all[key]
    }

    /// ★ D1: Home's Continue and the part page's button offer the one last saved — v1.1, a version with results ("Open v1.1"),
    /// not the newest draft v3 (the control: the old rule's pick); once he has worked on v3 later, both offer "v3 draft".
    func testContinueAndOpenOfferTheLastOneHeWorkedOn() throws {
        for (name, size) in hisSizes {
            let (app, f) = try arms("continue", size)
            app.library.route = .home
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(2.5)
            XCTAssertNotNil(wait(h, for: "libraryContinue-v1.1"), "★ \(name): Continue · Carriage Arms v1.1 (the last saved, with results)")
            XCTAssertNil(h.frames.all["libraryContinue-v3-draft"], "\(name): RED CONTROL's pick (the newest draft) is not offered")
            let part = try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"])))
            app.library.route = .part(part.id)
            h.pump(2)
            try h.probe("library-open", "\(name): the part page's Open")
            XCTAssertNotNil(h.frames.all["library-open-v1.1"], "★ \(name): \"Open v1.1\"")
            // he works on the v3 draft: its folder is saved later than the rest
            let store = app.library.store
            var v3 = try XCTUnwrap(store.snapshot(id: try XCTUnwrap(f["3"])))
            v3.savedAt = Date(timeIntervalSince1970: 900)
            try store.save(v3)
            app.library.refresh()
            h.pump(1.5)
            XCTAssertNotNil(wait(h, for: "library-open-v3"), "★ \(name): \"Open v3 draft\" now")
            app.library.route = .home
            h.pump(1.5)
            XCTAssertNotNil(wait(h, for: "libraryContinue-v3-draft"), "★ \(name): Continue · v3 draft now")
            try h.tap("libraryContinue", "\(name): Continue", settle: 2)
            XCTAssertEqual(app.project?.id, f["3"], "★ \(name): Continue opens it")
        }
    }

    private func onPart(_ app: AppModel, _ f: [String: UUID], _ size: CGSize) throws -> AppBuildHost {
        app.library.route = .part(try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"]))).id)
        let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
        h.pump(3)
        return h
    }

    /// ★ D2: one tap at a card's picture opens it — a draft's and a version's, at the picture's centre, the first tap.
    func testOneTapAtThePicturesCentreOpensIt() throws {
        for (name, size) in hisSizes {
            var (app, f) = try arms("tap-picture", size)
            var h = try onPart(app, f, size)
            let pic = try h.onScreen("library-version-v3-picture", "\(name): v3's picture")
            h.click(CGPoint(x: pic.midX, y: pic.midY), settle: 2)
            XCTAssertEqual(app.screen, .workspace, "★ \(name): one tap at the picture's centre opens the draft")
            XCTAssertEqual(app.project?.id, f["3"])
            (app, f) = try arms("tap-mini", size)
            h = try onPart(app, f, size)
            let mini = try h.onScreen("library-mini-v2a", "\(name): v2a's picture")
            h.click(CGPoint(x: mini.midX, y: mini.midY), settle: 2)
            XCTAssertEqual(app.project?.id, f["2"], "★ \(name): one tap at a version's picture opens it")
        }
    }

    /// ★ D2: the rest of the card — beside and under the picture, its name row, its line — opens it too: the card's own tap,
    /// behind its controls (stars, ⋯, flags, links keep their own taps), before its long-press menu. (A synthesised click
    /// never reaches a SwiftUI tap gesture in this offscreen window — CutToolHostedTests, FacePrismDragHostedTests — so the
    /// card-wide tap is pinned here; the picture's own tap is driven above.) RED CONTROL: release 16's card had no tap of its
    /// own (only the pictures, the names and "Open v5 draft" were targets).
    func testTheWholeCardIsTheTarget() throws {
        let src = try FlexibleSource.code("LibraryViews.swift")
        let card = try XCTUnwrap(src.range(of: "struct LibraryVersionCard: View {"))
        let body = String(src[card.upperBound...])
        let shape = try XCTUnwrap(body.range(of: ".contentShape(shape)"))
        let tap = try XCTUnwrap(body.range(of: ".onTapGesture { openOn(nil) }"), "★ the card opens on a tap anywhere")
        let menu = try XCTUnwrap(body.range(of: ".contextMenu { versionMenu(pending: pending) }"))
        XCTAssertLessThan(shape.lowerBound, tap.lowerBound, "★ over the card's whole shape")
        XCTAssertLessThan(tap.lowerBound, menu.lowerBound, "the long press stays the menu")
        XCTAssertEqual(body.components(separatedBy: ".onTapGesture").count - 1, 1, "one card-wide tap, no other")
    }
}

// MARK: - D7 (hosted, the sample)

@MainActor
final class Notes25SampleKeptHostedTests: XCTestCase {
    final class Switch: ObservableObject {
        @Published var inputs: LatticeSampleView.Inputs
        @Published var key: LatticeSampleKeep.Key?
        init(_ i: LatticeSampleView.Inputs, _ k: LatticeSampleKeep.Key?) { inputs = i; key = k }
    }
    struct Page: View {
        @ObservedObject var s: Switch
        var body: some View { LatticeSampleView(inputs: s.inputs).kept(s.key) }
    }

    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    private func cells(_ mm: Double) -> LatticeSampleView.Inputs {
        LatticeSampleView.Inputs(shape: .cells, topology: "octet", typeName: "Octet truss", cellMM: mm, beadMM: 0.45,
                                 rhoLo: 0.3, rhoHi: 0.3)
    }

    /// Pump until the builder has run `n` builds since `b0` and the caption says the sample is built (≤ 90 s).
    private func built(_ h: AppBuildHost, _ b0: Int, _ n: Int, _ what: String) {
        let end = Date().addingTimeInterval(90)
        while Date() < end, LatticeSampleBuilder.shared.builds - b0 < n
                || !(LatticeSampleView.recordedCaptions.last ?? "").hasSuffix("built by the engine") { h.pump(0.25) }
        h.pump(0.5)
        XCTAssertEqual(LatticeSampleBuilder.shared.builds - b0, n, "\(what): builds")
    }

    /// ★ D7 (his img 3, img 9): "an instant switch when I tap on the other group, before any changes are made". Part, then
    /// Back Wall (another cell), then Part again unchanged: Part's sample at once, no build. A change on Part builds. RED
    /// CONTROL: with nothing kept (the old page), the same switch back builds again. The part closing drops them all.
    func testAnUnchangedGroupShowsItsKeptSampleAndAChangeBuilds() throws {
        for (name, size) in hisSizes {
            LatticeSampleKeep.shared.forget()
            LatticeSampleView.recordedCaptions = []; LatticeSampleView.recordedKept = 0
            let project = UUID()
            let part = LatticeSampleKeep.Key(project: project, group: "part"), wall = LatticeSampleKeep.Key(project: project, group: "area-1")
            let s = Switch(cells(6), part)
            let b0 = LatticeSampleBuilder.shared.builds
            let h = AppBuildHost(Page(s: s), size: size, test: self)
            built(h, b0, 1, "\(name): Part's sample")
            let partCaption = try XCTUnwrap(LatticeSampleView.recordedCaptions.last)
            XCTAssertTrue(partCaption.contains("of 6 mm"), "\(name): premise: Part's own sample (\(partCaption))")
            s.inputs = cells(8); s.key = wall
            built(h, b0, 2, "\(name): Back Wall's sample")
            XCTAssertTrue((LatticeSampleView.recordedCaptions.last ?? "").contains("of 8 mm"), "\(name): premise: Back Wall's")
            // ★ back to Part, nothing changed: its sample at once, no build
            s.inputs = cells(6); s.key = part
            h.pump(1.5)
            XCTAssertEqual(LatticeSampleBuilder.shared.builds - b0, 2, "★ \(name): no build for an unchanged group")
            XCTAssertEqual(LatticeSampleView.recordedKept, 1, "★ \(name): its kept sample was shown")
            XCTAssertEqual(LatticeSampleView.recordedCaptions.last, partCaption, "★ \(name): Part's sample, as it was built")
            // ★ a change on Part builds as today
            s.inputs = cells(7)
            built(h, b0, 3, "★ \(name): a change builds")
            XCTAssertTrue((LatticeSampleView.recordedCaptions.last ?? "").contains("of 7 mm"))
            // RED CONTROL: nothing kept (the old page) — the switch back to Back Wall's unchanged sample builds again
            s.key = nil; s.inputs = cells(8)
            built(h, b0, 4, "RED CONTROL \(name): with nothing kept the switch builds")
            XCTAssertEqual(LatticeSampleView.recordedKept, 1, "control: nothing kept was shown")
            // memory: one per group of the open part; another part's ask, or the part closing, drops them
            XCTAssertLessThanOrEqual(LatticeSampleKeep.shared.count, LatticeSampleKeep.maxKept)
            XCTAssertNil(LatticeSampleKeep.shared.sample(.init(project: UUID(), group: "part"), for: cells(6)), "another part: none")
            XCTAssertEqual(LatticeSampleKeep.shared.count, 0, "★ \(name): another part's page dropped this part's samples")
            LatticeSampleKeep.shared.forget()
        }
    }

    /// The part closing (Back to the Library) drops every kept sample.
    func testThePartClosingDropsThem() throws {
        let src = try FlexibleSource.code("AppModel.swift")
        let back = try XCTUnwrap(src.range(of: "public func backHome() {"))
        XCTAssertTrue(String(src[back.upperBound...].prefix(400)).contains("LatticeSampleKeep.shared.forget()"),
                      "★ backHome drops the kept samples")
    }
}

// MARK: - D3, D4, D5, D8 (hosted, Lattice Setup)

/// The A1 pad, Structural, on Lattice Setup with the preview on (AppAsks1114HostedTests' set-up): `thinWalls` its first pad
/// whole (the thin-wall pop-up comes by itself); `cellMM` a Manual cell (nothing fits: all of it solid).
@MainActor
private func latticeSetup(_ size: CGSize, _ name: String, _ test: XCTestCase, thinWalls: Bool, cellMM: Double? = nil) throws
    -> (AppBuildHost, ProjectModel) {
    let r = try FlexiblePressFixtures.a1Project(thinWalls ? 1 : 3, test, facePrism: false)
    let p = r.project
    p.lattice.flexible = nil
    p.lattice.clearLatticeType()
    p.lattice.chooseLatticeType(.structural)
    if thinWalls {
        p.lattice.wholePart = true
        p.lattice.thinWallsNoticeSeen = false
    }
    if let c = cellMM { p.lattice.cellSizeMode = .fixed; p.lattice.cellMM = c }
    p.lattice.enabled = true
    let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: test)
    h.pump(3)
    // ★ notes28: the stage now opens with its lattice view on; this set-up ARMS it by his tap (settings first, then their
    // Save), the flow these tests were written for — so the stage is entered as before
    WorkspacePlaceholder.controlLatticeViewStartsOff = true
    defer { WorkspacePlaceholder.controlLatticeViewStartsOff = false }
    try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): the stage menu")
    h.pump(1.5)
    if h.frames.all["view-Lattice preview-on"] == nil { try h.tap("view-Lattice preview", "\(name): the lattice preview", settle: 1.5) }
    if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleSetup", "\(name): the page's Save", settle: 1.5) }
    XCTAssertNil(h.frames.all["latticeSettingsPanel"], "\(name): premise: on Lattice Setup")
    return (h, p)
}

@MainActor
final class Notes25LatticeSetupHostedTests: XCTestCase {
    private func waitFor(_ h: AppBuildHost, _ key: String, seconds: Double) -> CGRect? {
        let end = Date().addingTimeInterval(seconds)
        while h.frames.all[key] == nil, Date() < end { h.pump(1) }
        return h.frames.all[key]
    }

    /// ★ D8 (his 11-23 on the pop-up) and D5 (img 4, "What is going on in the bottom left corner???") and D3 (img 5, "Place
    /// this more in the bottom's centre"), on his first pad whole under Structural, at his two sizes:
    /// - the pop-up keeps its title and two buttons; under the title three reasons, each with its own (i) (a 44 pt target that
    ///   opens its words), what Aesthetic does, and Learn more (opens the page); nothing of it outside the pop-up or the screen;
    /// - with the pop-up up, the new engine's stack and the notice are drawn whole on the screen (the stack was 0 pt wide at its
    ///   left edge: the pop-up's whole-screen holder counted as a control);
    /// - the notice sits on the screen's centre line at the foot, clear of Settings and Lattice, above the status lines.
    func testThePopUpsReasonsAndTheNoticeInTheBottomCentre() throws {
        for (name, size) in hisSizes {
            LatticeLayoutPreview.lastGlowLit = 0
            let (h, _) = try latticeSetup(size, name, self, thinWalls: true)
            guard let panel = waitFor(h, "lattice-thin-walls-panel", seconds: 240) else {
                return XCTFail("★ \(name): the thin-wall pop-up did not come")
            }
            h.pump(2)
            let screen = CGRect(origin: .zero, size: size)
            // D8: three reasons with their (i)s, inside the pop-up
            for i in 1...3 {
                let row = try h.onScreen("lattice-thin-walls-reason-\(i)", "★ \(name): reason \(i)")
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(row), "★ \(name): reason \(i) \(row) inside the pop-up \(panel)")
                let info = try h.probe("info-thin-walls-why-\(i)", "★ \(name): reason \(i)'s (i), its own 44 pt target")
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(info), "★ \(name): its (i) inside the pop-up")
            }
            let aesthetic = try h.onScreen("lattice-thin-walls-aesthetic", "★ \(name): what Aesthetic does")
            XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(aesthetic), "\(name): inside the pop-up")
            let learn = try h.probe("lattice-thin-walls-learn", "★ \(name): Learn more")
            XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(learn))
            for k in ["lattice-thin-walls-switch", "lattice-thin-walls-continue"] {
                let b = try h.probe(k, "\(name): the pop-up's buttons stay")
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(b))
                XCTAssertGreaterThan(b.minY, learn.maxY - 0.5, "\(name): the buttons under the words")
            }
            XCTAssertTrue(screen.contains(panel), "★ \(name): the pop-up wholly on the screen")
            for i in 1...3 {
                try h.tap("info-thin-walls-why-\(i)", "\(name): reason \(i)'s (i)", settle: 0.6)
                XCTAssertNotNil(NSApp.windows.first { $0 !== h.window && $0.isVisible && $0.className.contains("Popover") },
                                "★ \(name): reason \(i)'s (i) opens its words")
                NSApp.windows.filter { $0 !== h.window && $0.className.contains("Popover") }.forEach { $0.orderOut(nil) }
                h.pump(0.4)
            }
            AppPopups.shared.current = nil
            try h.tap("lattice-thin-walls-learn", "\(name): Learn more", settle: 0.6)
            XCTAssertEqual(AppPopups.shared.current?.title, LatticeThinWallPrompt.pageTitle, "★ \(name): Learn more opens the page")
            for head in ["WHAT EACH IS FOR", "AT THIN WALLS", "HOW STRENGTH IS JUDGED", "WHICH TO PICK"] {
                XCTAssertTrue(AppPopups.shared.current?.text.contains(head) == true, "\(name): the page says \(head)")
            }
            AppPopups.shared.current = nil

            // ★ D10: the walls glow while the pop-up is up (the lay's own solid places), and stop when he picks
            XCTAssertNotNil(waitFor(h, "lattice-thin-walls-glow", seconds: 60), "★ \(name): the walls glow while the pop-up shows")
            XCTAssertGreaterThan(LatticeLayoutPreview.lastGlowLit, 0, "★ \(name): some of the part's walls are lit")

            // D5: nothing cut off at the screen's edges, the pop-up up
            let stack = try h.onScreen("lane-new-engine", "★ \(name): the new engine's stack, whole on the screen")
            XCTAssertGreaterThanOrEqual(stack.width, NotificationLane.minWidth, "★ \(name): never squeezed to nothing (\(stack))")
            for (k, f) in h.frames.all where k.hasPrefix("lane-") || k.hasPrefix("new-engine") {
                guard f.width > 0.5, f.height > 0.5 else { continue }
                XCTAssertTrue(screen.insetBy(dx: -0.5, dy: -0.5).contains(f), "★ \(name): \(k) \(f) is cut off at the screen's edge")
            }

            // D3 → ★ RE-PINNED notes28 (his 11-21 rule restated on release 18, img 76: "never a note at the bottom-centre … Remove
            // it from the UI entirely!!"): the notice that sat on the screen's centre line at the foot is gone; this pop-up says why
            for k in ["lane-new-engine-reason", "new-engine-reason", "new-engine-nozzle-check"] {
                XCTAssertNil(h.frames.all[k], "★ \(name): nothing at the bottom-centre (\(k))")
            }
            print("NOTES25 D3 \(name): no bottom notice; stack \(stack), panel \(panel), glow lit \(LatticeLayoutPreview.lastGlowLit)")
            // ★ D10: he picks (Continue): the pop-up and its glow go
            try h.tap("lattice-thin-walls-continue", "\(name): Continue with Structural", settle: 1)
            XCTAssertNil(h.frames.all["lattice-thin-walls-glow"], "★ \(name): the glow ends when he picks")
        }
    }

    /// ★ D4 (his img 4, img 5): when nothing of the lattice he asked for can be laid (the notice says 100 %), the Lattice
    /// button says "Cannot Lattice", greyed and not pressable; a setting that lets the lattice lay brings "Lattice" back.
    func testCannotLatticeWhenNothingCanBeLaid() throws {
        let bold = NSFont.systemFont(ofSize: 16, weight: .bold)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: bold]).width }
        for (name, size) in hisSizes {
            let (h, p) = try latticeSetup(size, name, self, thinWalls: false, cellMM: 60)
            guard waitFor(h, "latticeCannot", seconds: 240) != nil else {
                return XCTFail("★ \(name): a 60 mm cell lays nothing — the button never said Cannot Lattice")
            }
            h.pump(1)
            let title = try h.onScreen("latticeButton-title", "\(name): the button's title")
            XCTAssertEqual(title.width, width(LatticeCannotLattice.title), accuracy: 1.5, "★ \(name): it says \"Cannot Lattice\"")
            XCTAssertNotEqual(width("Cannot Lattice"), width("Lattice"), accuracy: 1.5, "control: the two read apart")
            // ★ RE-PINNED notes28: no bottom notice; a centred pop-up says why (the solid pop-up, or Structural's thin-wall one)
            XCTAssertNil(h.frames.all["new-engine-reason"], "\(name): nothing at the bottom-centre")
            XCTAssertTrue(AppPopups.shared.current != nil || h.frames.all["lattice-thin-walls-panel"] != nil,
                          "\(name): the same moment a centred pop-up says why")
            AppPopups.shared.current = nil
            // pressed: nothing starts
            try h.tap("latticeButton", "\(name): a press on Cannot Lattice", settle: 1)
            XCTAssertNotNil(h.frames.all["latticeCannot"], "★ \(name): not pressable: still Cannot Lattice")
            // he switches to a lattice that can (the notice's own fix, Aesthetic with walls cutting cells) at Auto cells: Lattice
            p.lattice.cellSizeMode = .auto
            SolidReason.apply(.aestheticCutCells, to: &p.lattice)
            let end = Date().addingTimeInterval(240)
            while h.frames.all["latticeCannot"] != nil, Date() < end { h.pump(1) }
            XCTAssertNil(h.frames.all["latticeCannot"], "★ \(name): a setting that lays brings Lattice back")
            h.pump(1)
            if let t = h.frames.all["latticeButton-title"] {
                XCTAssertNotEqual(t.width, width(LatticeCannotLattice.title), accuracy: 1.5, "★ \(name): no longer Cannot Lattice")
            }
        }
    }
}
#endif

// MARK: - D4 (the rule)

@MainActor
final class Notes25CannotLatticeTests: XCTestCase {
    func testTheConditionIsTheNoticesOwnHundredPercent() {
        func reason(_ share: Double) -> SolidReason { SolidReason(cause: .tooFewAcross, share: share, line: "", fixes: []) }
        XCTAssertTrue(LatticeCannotLattice.applies(reason(1)), "★ all of it solid")
        XCTAssertTrue(LatticeCannotLattice.applies(reason(0.996)), "★ said as 100 %: Cannot Lattice")
        XCTAssertFalse(LatticeCannotLattice.applies(reason(0.93)), "some of it lays: Lattice (the notice says 93 %)")
        XCTAssertFalse(LatticeCannotLattice.applies(nil), "no notice: Lattice")
        let made = SolidReason.of(share: 1, nocell: [0, 0, 9, 0, 0], lattice: LatticeSettings())
        XCTAssertEqual(made?.line.hasPrefix("100% of the lattice you asked for is solid"), true, "the notice's own words")
        XCTAssertTrue(LatticeCannotLattice.applies(made))
        let normal = LatticePrintFlow.Look(title: "Lattice", subtitle: LatticeStructuralSteppedGate.line,
                                           state: .disabled(LatticeStructuralSteppedGate.line), progress: nil)
        let look = LatticeCannotLattice.look(normal, cannot: true)
        XCTAssertEqual(look.title, "Cannot Lattice")
        XCTAssertEqual(look.state, .disabled(LatticeCannotLattice.line), "★ greyed and not pressable")
        XCTAssertLessThanOrEqual(LatticeCannotLattice.line.split(separator: " ").count, 5, "his 5-word rule")
        XCTAssertEqual(LatticeCannotLattice.look(normal, cannot: false).title, "Lattice", "otherwise the button as it was")
    }
}

// MARK: - D8 (the words)

final class Notes25ThinWallWordsTests: XCTestCase {
    /// Three reasons of a short sentence each, an (i) of a few plain sentences each, the numbers from the engine's one rule.
    func testThreeReasonsWithTheEnginesNumbers() {
        let f = LatticeStructuralThinWalls.Finding(minWallMM: 6, share: 1, cellsAcross: 5)
        let r = LatticeThinWallPrompt.reasons(f, cellsAcross: 5)
        XCTAssertEqual(r.map(\.line), ["A lattice needs 5 cells across a wall.", "A thin wall cuts its cells into pieces.",
                                       "Structural leaves solid what it can't check."])
        for x in r {
            XCTAssertLessThanOrEqual(x.line.split(separator: " ").count, 9, "a short sentence")
            let n = x.why.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            XCTAssertTrue((2...6).contains(n), "\(x.whyTitle): a few plain sentences (\(n))")
            for bad in ["homogen", "tensor", "certif", "N*", "percolat"] { XCTAssertFalse(x.why.contains(bad), "no jargon: \(bad)") }
        }
        XCTAssertTrue(r[0].why.contains("at least 6.0 mm thick"), "the wall, from the finding (one place)")
        var st = LatticeSettings(); st.stageMode = .structural
        var ae = LatticeSettings(); ae.stageMode = .aesthetic
        XCTAssertEqual(LatticeLayoutPreview.minCellsAcross(st), 5, "the engine's Structural number")
        XCTAssertEqual(LatticeLayoutPreview.minCellsAcross(ae), 2, "the engine's Aesthetic number")
        XCTAssertTrue(LatticeThinWallPrompt.page().contains("Structural needs 5 cells across a wall"))
        XCTAssertTrue(LatticeThinWallPrompt.page().contains("Aesthetic needs only 2 cells across (1 with"))
        XCTAssertEqual(LatticeThinWallPrompt.aestheticLine(cellsAcross: 1).hasPrefix("Aesthetic needs only 1 cell across"), true)
        XCTAssertLessThanOrEqual(LatticeThinWallPrompt.learnMore.split(separator: " ").count, 5, "his 5-word link rule")
    }
}

// MARK: - D10 (the wall's number)

@MainActor
final class Notes25ThinWallNumberTests: XCTestCase {
    /// ★ D10 ("thinner than 0.0 mm"): the wall Structural needs is the lay's own floor cell × the engine's cells across —
    /// 12.7 mm for a floor of 2.55 mm under Fit (where the settings alone say 0) — never 0.0; a Manual cell larger than the
    /// floor is the cell core uses. RED CONTROL: from the settings alone (no floor) Fit says 0.0 mm.
    func testTheWallIsTheFloorCellTimesTheCellsAcross() throws {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        p.lattice.enabled = true
        p.lattice.cellSizeMode = .fit
        let r = SolidReason(cause: .tooFewAcross, share: 1, line: "", fixes: [])
        // a floor of 2.549 mm (core's floor is a computed number; "2.55" as said): 5 × 2.549 = 12.745 → "12.7 mm"
        let f = try XCTUnwrap(WorkspacePlaceholder.thinWalls(r, project: p, floorCellMM: 2.549))
        XCTAssertEqual(f.cellsAcross, 5, "the engine's number")
        XCTAssertEqual(f.minWallMM, 5 * 2.549, accuracy: 1e-9)
        XCTAssertEqual(f.minWallText, "12.7 mm", "★ 12.7 mm")
        XCTAssertEqual(f.caption, "Structural: walls under 12.7 mm stay solid", "★ the note says the same number")
        XCTAssertTrue(LatticeThinWallPrompt.reasons(f, cellsAcross: f.cellsAcross ?? 0)[0].why.contains("at least 12.7 mm thick"),
                      "★ the reasons read the same value")
        // exactly 2.55: 12.75 mm, said to one decimal as rounded ("12.8 mm": every wall under 12.75 is under it)
        XCTAssertEqual(try XCTUnwrap(WorkspacePlaceholder.thinWalls(r, project: p, floorCellMM: 2.55)).minWallText, "12.8 mm")
        let old = try XCTUnwrap(WorkspacePlaceholder.thinWalls(r, project: p))
        XCTAssertEqual(old.minWallText, "0.0 mm", "RED CONTROL: the settings alone (his screenshot's 0.0 mm)")
        p.lattice.cellSizeMode = .fixed; p.lattice.cellMM = 4
        XCTAssertEqual(try XCTUnwrap(WorkspacePlaceholder.thinWalls(r, project: p, floorCellMM: 2.55)).minWallText, "20 mm",
                       "a Manual 4 mm cell: 5 × 4 mm")
    }
}

// MARK: - D9 (the Runs on ⚠)

@MainActor
final class Notes25RunsOnHealthTests: XCTestCase {
    private let mac = "Nadim's Mac mini"
    private let cfg = RemoteRunnerConfig(host: "10.0.0.7", port: 8757, expectedFingerprint: CoreFingerprint.value)

    override func tearDown() async throws {
        await MainActor.run { ComputeLocationModel.hostedTestDiscovery = nil; WorkerHealth.standIn = nil }
        try await super.tearDown()
    }

    private func model() -> ComputeLocationModel {
        ComputeLocationModel(defaults: UserDefaults(suiteName: "topopt.tests.\(UUID().uuidString)")!)
    }
    private var stale: DiscoveredWorker {
        DiscoveredWorker(id: mac, fingerprint: "0000stale0000", endpoint: .hostPort(host: "10.0.0.7", port: 8757))
    }
    private func spin(_ s: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(s)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// ★ A stale Bonjour fingerprint and a matching /health: no ⚠. A mismatching /health (asked again when the app comes to the
    /// front): the ⚠, in plain, true words. A run's own /health says it too.
    func testTheLiveHealthDecides() {
        let m = model()
        m.select(.worker(name: mac))
        m.listForTests([stale])
        XCTAssertTrue(m.isSkewed(stale), "RED CONTROL: the stale advertisement alone warns (what his iPad showed)")
        var answer = CoreFingerprint.value
        WorkerHealth.standIn = { _ in answer }
        ComputeLocationModel.hostedTestDiscovery = (mac, cfg, 0.05)
        m.startBrowsing()
        spin(5) { m.liveFingerprints[self.mac] != nil }
        XCTAssertEqual(m.liveFingerprints[mac], CoreFingerprint.value, "★ /health asked once the Mac is resolved")
        XCTAssertFalse(m.isSkewed(stale), "★ a matching /health: no ⚠, whatever Bonjour says")
        // the Mac's engine changes; the app comes back to the front
        answer = "1111other1111"
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        spin(5) { m.liveFingerprints[self.mac] == "1111other1111" }
        XCTAssertTrue(m.isSkewed(stale), "★ a mismatching /health: the ⚠")
        let words = m.skewMessage(stale)
        XCTAssertFalse(words.contains("Update core"), "★ never a menu the worker app does not have")
        XCTAssertEqual(words, "\(mac) runs a different version of the engine than this app. Install the matching TopOpt release "
                       + "on the Mac, then try again.")
        // a run's own pre-job /health answers: heard
        WorkerHealth.heard(host: cfg.host, port: cfg.port, fingerprint: CoreFingerprint.value)
        spin(1) { !m.isSkewed(self.stale) }
        XCTAssertFalse(m.isSkewed(stale), "★ a run's /health clears it")
        // another Mac's answer is not this one's
        WorkerHealth.heard(host: "10.0.0.99", port: 8757, fingerprint: "2222")
        spin(0.3)
        XCTAssertFalse(m.isSkewed(stale), "another address's /health is not this Mac's")
    }

    #if canImport(AppKit) && canImport(MetalKit)
    /// ★ The pill (Settings › Runs on) at his two sizes: the ⚠ while only the stale advertisement is known, gone once /health
    /// matches, back when /health does not.
    func testThePillsWarning() throws {
        for (name, size) in hisSizes {
            let m = model()
            m.select(.worker(name: mac))
            m.listForTests([stale])
            var answer = CoreFingerprint.value
            WorkerHealth.standIn = { _ in try? await Task.sleep(nanoseconds: 1_200_000_000); return answer }
            ComputeLocationModel.hostedTestDiscovery = (mac, cfg, 0.05)
            let h = AppBuildHost(ComputeLocationControl(compute: m, asValueBox: true).padding(40), size: size, test: self)
            h.pump(0.4)
            XCTAssertNotNil(h.frames.all["computeSkewMark"], "RED CONTROL \(name): before /health answers, the old hint warns")
            let end = Date().addingTimeInterval(6)
            while h.frames.all["computeSkewMark"] != nil, Date() < end { h.pump(0.2) }
            XCTAssertNil(h.frames.all["computeSkewMark"], "★ \(name): /health matches: no ⚠")
            answer = "3333other3333"
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            let end2 = Date().addingTimeInterval(6)
            while h.frames.all["computeSkewMark"] == nil, Date() < end2 { h.pump(0.2) }
            XCTAssertNotNil(h.frames.all["computeSkewMark"], "★ \(name): /health does not match: the ⚠")
            ComputeLocationModel.hostedTestDiscovery = nil
        }
    }
    #endif
}
