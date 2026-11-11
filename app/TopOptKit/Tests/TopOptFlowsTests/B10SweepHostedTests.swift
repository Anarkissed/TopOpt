// B10SweepHostedTests — B10, the uniformity sweep (plan.md B10: "Run every U-test on every page in 3 sizes and both orientations,
// and fix what's left"; the reviewer's scope ruling 2026-11-11 03:50Z, (A) corrected: FIX the kept pages — Library, Import /
// New part, Topology Setup and Run, Results (topology), Cut, Settings and App settings; the lattice pages are listed, never
// fixed). Each kept page at the sweep's six windows (AppBuildHost.sweep: 13″, 11″ and More Space, landscape and portrait),
// against the U-rules that hold on every page (design-system §1, §6):
//   * the role picker at the face lies wholly in the window and under no panel. Its keep-out was told 300 × 44 for a
//     434 × 100 chip, so it ran off 11″ portrait, and it never kept clear of the corner's Settings panel;
//   * the corner's Settings panel never climbs over the view controls (the gizmo, its Orthographic │ Perspective column and
//     the view buttons under it): at 11″ landscape its top sat on them. Past its room it scrolls with its "N more" cue (U10);
//   * Touch: every target is at least 44 × 44 pt (the face rows' eye and trash were 36, the Cut rail's tools 40 — their LOOK
//     stays the mockup's 40 pt round, only the target grows — and the pill buttons, App settings' Done among them, 42 tall);
//   * U5, one meaning per colour: at most ONE accent-filled control on a screen, the one primary action. A role's own colour
//     is not it (Load's colour IS the accent, §2): the role picker's role row, and the accent swatches in App settings, are
//     where the accent is a colour's name, not the primary; nor is a selected state (the selected row's 2 pt rail, Cut's
//     armed tool — the mockup's `.rail button.on`). Measured on the drawn picture (B10AccentCensus). The red run found no
//     kept page with two (the census's own positive control is red-capable: two buttons count two); it guards from here.
//   * U6 / U7: Rename project is the §4.11 name sheet (it was a system alert).
// The lattice pages are not here (list only, the 03:50Z ruling). The Library keeps its look (his 11-04 ruling; the
// reviewer's answer 11-11 08:04Z (1)(a)): its reach and fit are checked here at every window, its look is not.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

/// U5 measured on the picture: the accent-filled shapes on the screen (a button's fill, a selected tool's disc), found as
/// connected areas of the accent colour at 1 pt — a word or a glyph in the accent is too small and too thin to count, and a
/// ring (a selected outline) too hollow. `skip`: the frames where the accent is a role's or a swatch's own colour.
@MainActor
enum B10AccentCensus {
    /// The smallest filled control: a 20 × 20 pt disc.
    static let minArea = 300
    /// A fill covers at least half its box (a ring or an outline does not).
    static let minFill = 0.5
    /// A control is never thinner than this: the selected row's 2 pt accent rail and its outline (§2's `selected` state
    /// token) are not fills. (Found by the B10 red run: the selected row's rail and outline counted as four.)
    static let minSide: CGFloat = 12

    static func fills(_ h: AppBuildHost, skip: [CGRect] = []) -> [CGRect] {
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return [] }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let W = Int(h.size.width), H = Int(h.size.height)
        let sx = Double(rep.pixelsWide) / Double(W), sy = Double(rep.pixelsHigh) / Double(H)
        let a = DS.Color.accent
        let want = NSColor(srgbRed: a.r, green: a.g, blue: a.b, alpha: 1).usingColorSpace(rep.colorSpace)
            ?? NSColor(srgbRed: a.r, green: a.g, blue: a.b, alpha: 1)
        let wr = want.redComponent, wg = want.greenComponent, wb = want.blueComponent
        var on = [Bool](repeating: false, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                guard let c = rep.colorAt(x: Int((Double(x) + 0.5) * sx), y: Int((Double(y) + 0.5) * sy)) else { continue }
                let d = max(abs(c.redComponent - wr), abs(c.greenComponent - wg), abs(c.blueComponent - wb))
                if d <= 0.10 { on[y * W + x] = true }
            }
        }
        var seen = [Bool](repeating: false, count: W * H)
        var out: [CGRect] = []
        for start in 0..<(W * H) where on[start] && !seen[start] {
            var stack = [start]; seen[start] = true
            var n = 0, x0 = W, y0 = H, x1 = 0, y1 = 0
            while let i = stack.popLast() {
                n += 1
                let x = i % W, y = i / W
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for j in [x > 0 ? i - 1 : -1, x < W - 1 ? i + 1 : -1, y > 0 ? i - W : -1, y < H - 1 ? i + W : -1]
                    where j >= 0 && on[j] && !seen[j] { seen[j] = true; stack.append(j) }
            }
            let box = CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
            guard n >= minArea, box.width >= minSide, box.height >= minSide,
                  Double(n) / Double(box.width * box.height) >= minFill else { continue }
            if skip.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(box) }) { continue }
            out.append(box)
        }
        return out
    }

    /// The published keys whose frame holds `box` (what the fill is, for the failure message).
    static func named(_ box: CGRect, _ h: AppBuildHost) -> String {
        let keys = h.frames.all.filter { $0.value.insetBy(dx: -2, dy: -2).contains(box) }
            .sorted { $0.value.width * $0.value.height < $1.value.width * $1.value.height }.prefix(2).map(\.key)
        return "\(box.integral) in \(keys)"
    }
}

@MainActor
final class B10SweepHostedTests: XCTestCase {

    /// A Structural lookalike with results, on Topology Setup (UniformChromeHostedTests' route): Group C is pending, so the
    /// role picker is up at its face.
    func structural(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, AppModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.run.restoreOutcome(AppBuildFixtures.outcome())
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p, r.app)
    }

    /// `a` is drawn clear of the frame `key` (when it is drawn).
    func clear(_ h: AppBuildHost, _ a: CGRect, of key: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let f = h.frames.all[key] else { return }
        XCTAssertFalse(a.intersects(f.insetBy(dx: 0.5, dy: 0.5)), "★ \(what) is under '\(key)' \(f.integral): \(a.integral)",
                       file: file, line: line)
    }

    func testTheRolePickerAtTheFaceStaysOnTheWindowAndOffThePanels() throws {
        for size in AppBuildHost.sweep {
            let (h, p, _) = try structural(size)
            let pending = try XCTUnwrap(p.selection.groups.first(where: { $0.name == "Group C" }), "the lookalike's Group C")
            XCTAssertTrue(p.force.needsRole(pending.id, latticeRoleGroups: []), "premise: Group C still needs a role")
            let chip = try h.onScreen("topologyPendingChip", "\(size): ★ the role picker at the face, wholly in the window")
            let join = try h.onScreen("chipJoin", "\(size): its join button")
            XCTAssertTrue(chip.insetBy(dx: -0.5, dy: -0.5).contains(join), "\(size): the join button is the picker's first line")
            for k in ["selectionsList", "viewPair", "orientationGizmo", "setupChip", "optimizeSplit", "topologyFixLine"] {
                clear(h, chip, of: k, "\(size): the role picker")
            }
            // the corner's Settings panel open: the picker moves clear of it, or (no room) is withdrawn — never under it
            try h.tap("setupChip", "\(size): Settings", settle: 1.2)
            let panel = try h.onScreen("settingsPanel", "\(size): the Settings panel")
            if h.frames.all["topologyPendingChip-withdrawn"] == nil {
                let moved = try h.onScreen("topologyPendingChip", "\(size): ★ the role picker with Settings open, in the window")
                XCTAssertFalse(moved.intersects(panel.insetBy(dx: 0.5, dy: 0.5)),
                               "\(size): ★ the role picker is under the Settings panel \(panel.integral): \(moved.integral)")
                clear(h, moved, of: "selectionsList", "\(size): the role picker with Settings open")
            }
        }
    }

    func testTheSettingsPanelNeverCoversTheViewControls() throws {
        for size in AppBuildHost.sweep {
            let (h, _, _) = try structural(size)
            let views = h.frames.all.filter { $0.key == "viewPair" || $0.key == "orientationGizmo" || $0.key.hasPrefix("view-") }
            XCTAssertNotNil(views["orientationGizmo"], "\(size): premise: the gizmo is drawn")
            XCTAssertNotNil(views["viewPair"], "\(size): premise: Orthographic │ Perspective is drawn")
            try h.tap("setupChip", "\(size): Settings", settle: 1.2)
            let panel = try h.onScreen("settingsPanel", "\(size): the Settings panel")
            for (k, f) in views.sorted(by: { $0.key < $1.key }) {
                XCTAssertFalse(panel.intersects(f.insetBy(dx: 0.5, dy: 0.5)),
                               "\(size): ★ the Settings panel \(panel.integral) covers the view control '\(k)' \(f.integral)")
            }
            // past its room it scrolls: its last row, Material, is reachable (in the panel, or under the "N more" cue)
            XCTAssertNotNil(h.frames.all["settingsRow-material"], "\(size): the panel holds its last row")
        }
    }

    func testEveryTargetOnTheKeptPagesIsAFinger() throws {
        for size in AppBuildHost.sweep {
            let (h, _, _) = try structural(size)
            // Topology Setup: the face rows' eye and trash
            let pieces = h.frames.all.filter { $0.key.hasPrefix("pieceEye-") || $0.key.hasPrefix("pieceTrash-") }
            XCTAssertFalse(pieces.isEmpty, "\(size): premise: Group C's face row is open")
            for (k, _) in pieces.sorted(by: { $0.key < $1.key }) { try h.probe(k, "\(size): ★ the face row's \(k)") }
            // the view toggles under the gizmo (§4.2: "40 pt glass circles" — the look stays, the target is 44)
            let toggles = h.frames.all.filter { $0.key.hasPrefix("viewToggle-") }
            XCTAssertGreaterThanOrEqual(toggles.count, 3, "\(size): premise: Outlines · X-ray · Forces")
            for (k, _) in toggles.sorted(by: { $0.key < $1.key }) { try h.probe(k, "\(size): ★ the view toggle \(k)") }
            // Cut: the rail's tools (their look stays the mockup's 40 pt disc; the target is 44)
            try h.tap("capsuleScissors", "\(size): Cut", settle: 2)
            // (its look is "cutTool-<title>", 40 pt — CutLookHostedTests; its target is "cutToolTarget-<title>")
            let tools = h.frames.all.filter { $0.key.hasPrefix("cutToolTarget-") || $0.key.hasPrefix("cutTool-") }
            XCTAssertGreaterThanOrEqual(tools.count, 5, "\(size): premise: the Cut rail is drawn")
            let targets = tools.keys.contains { $0.hasPrefix("cutToolTarget-") } ? tools.filter { $0.key.hasPrefix("cutToolTarget-") } : tools
            for (k, _) in targets.sorted(by: { $0.key < $1.key }) { try h.probe(k, "\(size): ★ Cut's \(k)") }
            for (k, _) in h.frames.all.filter({ $0.key.hasPrefix("viewToggle-") }).sorted(by: { $0.key < $1.key }) {
                try h.probe(k, "\(size): ★ Cut's view toggle \(k)")
            }
        }
        // App settings: Done (a pill button: every pill's target is 44 tall)
        let suite = "B10SweepHostedTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        for size in AppBuildHost.sweep {
            let h = AppBuildHost(ZStack {
                DS.Color.background.color.ignoresSafeArea()
                AppSettingsView(settings: AppSettings(defaults: d), projection: ViewProjection(defaults: d),
                                compute: ComputeLocationModel(defaults: d), storage: {}, done: {})
                    .frame(width: min(600, size.width - 64))
            }, size: size, test: self)
            h.pump(1.5)
            try h.probe("appSettingsDone", "\(size): ★ App settings' Done")
        }
    }

    func testOneAccentFilledControlPerScreen() throws {
        for size in AppBuildHost.sweep {
            let (h, _, _) = try structural(size)
            // Topology Setup, the role picker up: its join button is the one; the role row's Load is Load's colour (§2)
            var roleRow: [CGRect] = []
            if let chip = h.frames.all["topologyPendingChip"], let join = h.frames.all["chipJoin"] {
                roleRow.append(CGRect(x: chip.minX, y: join.maxY, width: chip.width, height: chip.maxY - join.maxY))
            }
            var fills = B10AccentCensus.fills(h, skip: roleRow)
            XCTAssertLessThanOrEqual(fills.count, 1, "\(size): ★ U5 on Topology Setup: \(fills.map { B10AccentCensus.named($0, h) })")
            try h.tap("setupChip", "\(size): Settings", settle: 1.2)
            if let chip = h.frames.all["topologyPendingChip"], let join = h.frames.all["chipJoin"] {
                roleRow = [CGRect(x: chip.minX, y: join.maxY, width: chip.width, height: chip.maxY - join.maxY)]
            }
            fills = B10AccentCensus.fills(h, skip: roleRow)
            XCTAssertLessThanOrEqual(fills.count, 1, "\(size): ★ U5 with Settings open: \(fills.map { B10AccentCensus.named($0, h) })")
            try h.tap("setupChip", "\(size): Settings, shut", settle: 1)
            try h.tap("capsuleResults", "\(size): Results", settle: 2)
            fills = B10AccentCensus.fills(h)
            XCTAssertLessThanOrEqual(fills.count, 1, "\(size): ★ U5 on Results: \(fills.map { B10AccentCensus.named($0, h) })")
            try h.tap("capsuleSetup", "\(size): back to Setup", settle: 1.5)
            try h.tap("capsuleScissors", "\(size): Cut", settle: 2)
            // Cut: Done is the one (§3: "Editing faces · Discard · Done"); the rail's armed tool wears the accent as its
            // selected state (the mockup's `.rail button.on`, §4.2's "selected (accent fill)") — a state, not a second primary
            let rail = h.frames.all.filter { $0.key.hasPrefix("cutTool") }.map(\.value)
            fills = B10AccentCensus.fills(h, skip: rail)
            XCTAssertLessThanOrEqual(fills.count, 1, "\(size): ★ U5 on Cut: \(fills.map { B10AccentCensus.named($0, h) })")
        }
        // App settings: Done is the one; the accent swatches are colours' names
        let suite = "B10SweepHostedTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        for size in AppBuildHost.sweep {
            let h = AppBuildHost(ZStack {
                DS.Color.background.color.ignoresSafeArea()
                AppSettingsView(settings: AppSettings(defaults: d), projection: ViewProjection(defaults: d),
                                compute: ComputeLocationModel(defaults: d), storage: {}, done: {})
                    .frame(width: min(600, size.width - 64))
            }, size: size, test: self)
            h.pump(1.5)
            let swatches = h.frames.all.filter { $0.key.hasPrefix("appSettingsAccent") }.map(\.value)
            XCTAssertFalse(swatches.isEmpty, "\(size): premise: the accent swatches are drawn")
            let fills = B10AccentCensus.fills(h, skip: swatches)
            XCTAssertLessThanOrEqual(fills.count, 1, "\(size): ★ U5 in App settings: \(fills.map { B10AccentCensus.named($0, h) })")
        }
    }

    /// ★ The Library keeps its look (his 11-04 ruling; the reviewer's answer 11-11 08:04Z (1)(a)): only REACH and FIT, at every
    /// window — its home's buttons (Storage, ⋯, New project were 36 pt targets: the same capsules, 44 pt targets now), its
    /// project and part pages, and New part's sheet (Browse… was ~38, the material menu ~42). Its nine system dialogs and its
    /// two blue buttons stay, listed as kept by that ruling.
    func testTheLibraryAndNewPartReachAndFitEveryWindow() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("b10-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (i, size) in AppBuildHost.sweep.enumerated() {
            let (app, f) = try LibraryPartRowsHostedTests.arms(root: tmp.appendingPathComponent("\(i)", isDirectory: true))
            app.library.route = .home
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(2.5)
            for k in ["libraryStorage", "libraryMore", "libraryNewProject"] { try h.probe(k, "\(size): ★ the Library home's \(k)") }
            if h.frames.all["libraryContinue"] != nil { try h.probe("libraryContinue", "\(size): Continue") }

            let part = try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"])), "the lookalike's part")
            app.library.route = .part(part.id)
            h.pump(2)
            for k in ["library-open", "library-compare", "library-sort"] where h.frames.all[k] != nil {
                try h.probe(k, "\(size): ★ the part page's \(k)")
            }
            let proj = try XCTUnwrap(app.library.index.projects.first, "the lookalike's project")
            app.library.route = .project(proj.id)
            h.pump(2)
            for k in ["libraryAddPart", "libraryExport"] where h.frames.all[k] != nil { try h.probe(k, "\(size): ★ the project page's \(k)") }
            for (k, _) in h.frames.all.filter({ $0.key.hasPrefix("libraryPart-") && $0.key.hasSuffix("-menu") }) {
                try h.probe(k, "\(size): ★ a part card's ⋯")
            }

            // New part: the sheet over the page, wholly in the window, its controls 44 pt targets
            app.newTopOpt()
            let hi = AppBuildHost(ZStack { DS.Color.background.color.ignoresSafeArea(); GlassSheet { ImportSheet(model: app) } },
                                  size: size, test: self)
            hi.pump(1.5)
            for k in ["importBrowse", "importMaterial", "importCancel"] { try hi.probe(k, "\(size): ★ New part's \(k)") }
        }
    }

    /// U6 (the reviewer's ruling 11-11 08:04Z (2)(a); §4.12 Line): an export that failed says so in ONE danger line over
    /// Results' corner (at most 12 words; the corner sits at the page's foot, so its line is the one just above it — §4.18's
    /// fix-line place), with ONE "Try again" chip that tries again — never a system alert (OneWayToSayNoTests: they are gone).
    func testAFailedExportIsTheCornersDangerLine() throws {
        for f in [ResultsExportFailure.stl("x"), .stlAll("x"), .video("x")] {
            XCTAssertLessThanOrEqual(f.words.split(separator: " ").count, 12, "★ §4.12: a line is at most 12 words: \(f.words)")
        }
        var attempts: [String] = []
        ResultsScreen.exportWriteFailsForTests = true
        ResultsScreen.exportAttemptProbe = { attempts.append($0) }
        defer { ResultsScreen.exportWriteFailsForTests = false; ResultsScreen.exportAttemptProbe = nil }
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait11] {
            attempts = []
            let (h, _, _) = try structural(size)
            try h.tap("capsuleResults", "\(size): Results", settle: 2)
            XCTAssertNil(h.frames.all["resultsExportFailure"], "\(size): premise: no line before an export")
            try h.tap("resultsExport", "\(size): Export", settle: 1)
            XCTAssertEqual(attempts, ["stl"], "\(size): premise: Export ran")
            let line = try h.onScreen("resultsExportFailure", "\(size): ★ the failure is a line over the corner")
            let export = try h.onScreen("resultsExport", "\(size): Export")
            XCTAssertLessThanOrEqual(line.maxY, export.minY + 0.5, "\(size): ★ over the corner, never on Export")
            let retry = try h.probe("resultsExportRetry", "\(size): ★ its one Try again chip")
            XCTAssertTrue(line.insetBy(dx: -0.5, dy: -0.5).contains(retry), "\(size): the chip is the line's")
            try h.tap("resultsExportRetry", "\(size): Try again", settle: 1)
            XCTAssertEqual(attempts, ["stl", "stl"], "\(size): ★ Try again exports again")
        }
    }

    /// U6 / U7 (§4.11): Rename project is the name sheet over the whole page, never a system alert: centred, its name in a
    /// 48 pt field with the accent edge, Cancel on the left and Save bottom-right (44 pt targets). Cancel keeps the name;
    /// Save keeps the new one.
    func testRenameProjectIsTheNameSheet() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait11] {
            let (h, p, _) = try structural(size)
            let before = p.name
            func open() throws {
                let pill = try h.onScreen("topLeftName", "\(size): the name pill")
                h.click(CGPoint(x: pill.minX + 24, y: pill.midY), settle: 1)   // the name, at the pill's start
            }
            try open()
            let sheet = try h.onScreen("nameSheet", "\(size): ★ Rename project is the name sheet")
            XCTAssertEqual(sheet.midX, size.width / 2, accuracy: 1, "\(size): centred on the page")
            let field = try h.onScreen("nameSheetField", "\(size): its name field")
            XCTAssertEqual(field.height, 48, accuracy: 0.5, "\(size): the name is a 48 pt field")
            XCTAssertTrue(sheet.contains(field), "\(size): in the sheet")
            let cancel = try h.probe("nameSheetCancel", "\(size): ★ Cancel")
            let save = try h.probe("nameSheetPrimary", "\(size): ★ Save")
            XCTAssertLessThan(cancel.maxX, save.minX, "\(size): Cancel on the left, the primary to its right")
            XCTAssertGreaterThan(save.minX, sheet.midX, "\(size): the primary bottom-right")
            try h.tap("nameSheetCancel", "\(size): Cancel", settle: 0.8)
            XCTAssertNil(h.frames.all["nameSheet"], "\(size): ★ Cancel shuts it")
            XCTAssertEqual(p.name, before, "\(size): Cancel keeps the name")

            try open()
            try h.tap("nameSheetField", "\(size): the field", settle: 0.4)
            guard let editor = h.window.firstResponder as? NSTextView else {
                XCTFail("\(size): the name field takes the keyboard (first responder: \(String(describing: h.window.firstResponder)))"); continue
            }
            editor.selectAll(nil)
            editor.insertText("Bench rig", replacementRange: editor.selectedRange())
            h.pump(0.4)
            try h.tap("nameSheetPrimary", "\(size): Save", settle: 0.8)
            XCTAssertNil(h.frames.all["nameSheet"], "\(size): Save shuts it")
            XCTAssertEqual(p.name, "Bench rig", "\(size): ★ Save keeps the new name")
        }
    }

    /// The census can see a fill: two accent buttons are two (the positive control for U5).
    func testTheAccentCensusCountsTwoFills() throws {
        let h = AppBuildHost(ZStack {
            DS.Color.background.color.ignoresSafeArea()
            HStack(spacing: 40) {
                PillButton("One") {}
                PillButton("Two") {}
                PillButton("Cancel", style: .secondary) {}
                Text("Accent words").foregroundStyle(DS.Color.accent.color)
            }
        }, size: CGSize(width: 900, height: 300), test: self)
        h.pump(0.6)
        XCTAssertEqual(B10AccentCensus.fills(h).count, 2, "★ two accent-filled buttons; the outline and the words do not count")
    }
}
#endif
