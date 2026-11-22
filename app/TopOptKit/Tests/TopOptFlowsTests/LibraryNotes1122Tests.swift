// LibraryNotes1122Tests — ★ his iPad notes 2026-11-22, img 1 (a part's version cards: drafts v1.4–v1.7, v6, v3, v2, v2.1, v1,
// "Picked" and "Rejected ×"), his words:
//   * "picked" needs to have an "x" next to it.
//   * If a version was picked through the comparison and a new version is created/uploaded/modified, then it can no longer be
//     "picked" and needs to be compared to the versions that were not compared to yet.
//   * Tapping on an image/modal should open up the project. If I tap on "v1a" it should automatically open up. If I tap on an
//     image it should automatically open up. Tapping the 3 dots should allow you to open the "details" of it OR holding on the
//     modal, having a menu come up and pressing "details" should show the full details of the model.
//   * What is up with this sorting? It should default to the newest at the top - with a whole bottom section for those that
//     have been rejected.
// and his "yes" to each of 362's four decisions (the order; clearing a Compare pick and Compare new; Picked ×; the taps and
// Details). Model-level tests here, each with its RED control where one makes sense; hosted tests (the two iPad sizes he
// tests on) below.
import XCTest
import SwiftUI
import TopOptKit
import TopOptDesign
#if canImport(AppKit)
import AppKit
#endif
@testable import TopOptFlows

@MainActor
final class LibraryNotes1122Tests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("topopt-lib-1122-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: root.appendingPathComponent("store", isDirectory: true))
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    // MARK: fixtures

    /// Three lookalike results (never his job inputs), one triangle each.
    static func outcome(_ n: Int = 3) -> OptimizeOutcome {
        OptimizeOutcome(variants: (0..<n).map { k in
            OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10 + Double(k),
                            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true, v3Passes: true,
                            meshVertices: [0, 0, 0, 1 + Float(k), 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        }, stoppedOnMargin: false, cancelled: false, acceptedCount: n, voxelVolumeMM3: 1,
           gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
    }

    /// One version folder of the lookalike Carriage Arms (the same model bytes, so the same part), saved at `t`.
    private func save(_ t: Double, results: Bool) throws -> UUID {
        let src = root.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("part.step")
        try Data("solid carriage arms".utf8).write(to: model)
        let snap = ProjectSnapshot(id: UUID(), name: "Carriage Arms", material: "PA12", process: .fdm,
                                   modelFileName: "model.step", originalFileName: "Carriage Arms.step",
                                   savedAt: Date(timeIntervalSince1970: t), selection: SelectionModel(),
                                   force: ForceModel(), quality: .fast, optimized: results ? true : nil)
        try store.save(snap, modelSource: model)
        try fm.removeItem(at: src)
        if results { try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: Self.outcome())), id: snap.id) }
        return snap.id
    }

    private func loadSummaries(_ lib: LibraryModel) {
        let exp = expectation(description: "summaries")
        lib.loadSummaries { exp.fulfill() }
        wait(for: [exp], timeout: 30)
    }

    /// v1 and v2 with three results each, grouped, their numbers read.
    private func twoVersions() throws -> (LibraryModel, v1: UUID, v2: UUID) {
        let v1 = try save(100, results: true), v2 = try save(200, results: true)
        let lib = LibraryModel(store: store)
        lib.refresh()
        try lib.group(projectName: "Squish Mechanism", partIDs: nil)
        loadSummaries(lib)
        XCTAssertEqual(lib.index.parts.count, 1, "premise: one part")
        XCTAssertEqual(lib.index.parts[0].versions.compactMap { $0.summary?.count }, [3, 3], "premise: both read")
        return (lib, v1, v2)
    }

    private func part(_ lib: LibraryModel) throws -> LibraryPart { try XCTUnwrap(lib.index.parts.first) }
    private func item(_ f: UUID, _ r: Int) -> CompareItem { CompareItem(folder: f, result: r) }

    // MARK: 1 · the order (decision 1)

    /// His screenshot's part, by date: drafts v1.4 (Nov 8) · v1.5 (Nov 9) · v1.6 (Nov 11) · v1.7 (Nov 21, 9:00), v6 (Nov 21,
    /// 10:00), v3 · v2 · v2.1 (Nov 3), v1 (Nov 6, picked). v3a, v2a and both of v2.1's results are rejected.
    private func screenshot() -> (versions: [LibraryVersion], changed: [UUID: Date], drafts: Set<UUID>) {
        func day(_ d: Int, _ h: Int = 12) -> Date { Date(timeIntervalSince1970: 1_793_000_000 + Double(d * 86_400 + h * 3_600)) }
        func sum(_ n: Int) -> [ResultSummary] { (0..<n).map { _ in ResultSummary(massGrams: 90, worstCaseMargin: 9, accepted: true, achievedVolumeFraction: 0.8) } }
        var out: [LibraryVersion] = [], changed: [UUID: Date] = [:], drafts: Set<UUID> = []
        func add(_ n: String, _ when: Date, results: Int, rejected: [Int] = []) {
            var v = LibraryVersion(folderID: UUID(), number: VersionNumber(n)!, parentNumber: VersionNumber(n)!.parent,
                                   summary: results > 0 ? sum(results) : nil)
            for r in rejected { v.setMark(ResultMark(result: r, rejected: true)) }
            out.append(v); changed[v.folderID] = when
            if results == 0 { drafts.insert(v.folderID) }
        }
        add("1", day(6), results: 1)
        add("2", day(3, 10), results: 1, rejected: [0])
        add("2.1", day(3, 11), results: 2, rejected: [0, 1])
        add("3", day(3, 12), results: 1, rejected: [0])
        add("6", day(21, 10), results: 1)
        add("1.4", day(8), results: 0)
        add("1.5", day(9), results: 0)
        add("1.6", day(11), results: 0)
        add("1.7", day(21, 9), results: 0)
        return (out, changed, drafts)
    }

    func testNewestIsByLastChangeWithDraftsMixedInAndTheRejectedAtTheBottom() {
        let (vs, changed, drafts) = screenshot()
        let ordered = LibraryOrder.newestFirst(vs) { changed[$0.folderID]! }
        let split = LibraryOrder.sections(ordered)
        XCTAssertEqual(split.top.map(\.number.description), ["6", "1.7", "1.6", "1.5", "1.4", "1"],
                       "★ newest at the top by when each last changed: drafts mixed in by date, a branch not under its parent")
        XCTAssertEqual(split.rejected.map(\.number.description), ["3", "2.1", "2"],
                       "★ a whole bottom section for the ones rejected — in the same newest-first order")
        // RED control: today's order (drafts pinned first, then the main line newest first, a branch under its parent) is the
        // order in his screenshot — the one he asked "What is up with this sorting?" about
        let pending = vs.filter { drafts.contains($0.folderID) }.sorted { VersionNumber.newestFirst($0.number, $1.number) }
        let done = vs.filter { !drafts.contains($0.folderID) }.sorted { VersionNumber.newestFirst($0.number, $1.number) }
        let before = (pending + done).map(\.number.description)
        XCTAssertEqual(before, ["1.4", "1.5", "1.6", "1.7", "6", "3", "2", "2.1", "1"], "the control: his screenshot's order")
        XCTAssertNotEqual(before, ordered.map(\.number.description), "★ the control fails his rule")
    }

    func testOnlyAVersionWithEveryResultRejectedGoesToTheBottom() {
        func v(_ n: Int, results: Int?, rejected: [Int]) -> LibraryVersion {
            var x = LibraryVersion(folderID: UUID(), number: VersionNumber(n),
                                   summary: results.map { k in (0..<k).map { _ in ResultSummary(massGrams: 1, worstCaseMargin: 2, accepted: true, achievedVolumeFraction: 1) } })
            for r in rejected { x.setMark(ResultMark(result: r, rejected: true)) }
            return x
        }
        XCTAssertTrue(LibraryOrder.allRejected(v(1, results: 2, rejected: [0, 1])), "★ every result rejected")
        XCTAssertFalse(LibraryOrder.allRejected(v(2, results: 2, rejected: [1])), "★ some rejected, some not: it stays up top")
        XCTAssertFalse(LibraryOrder.allRejected(v(3, results: nil, rejected: [])), "a draft (or one still being read) is not")
        XCTAssertFalse(LibraryOrder.allRejected(v(4, results: 2, rejected: [])))
    }

    /// The card's date is its saved time: what "when it last changed" reads.
    func testLastChangedIsTheSavedTime() throws {
        let (lib, v1, v2) = try twoVersions()
        XCTAssertEqual(lib.lastChanged(try XCTUnwrap(lib.version(v1))), Date(timeIntervalSince1970: 100))
        XCTAssertEqual(lib.lastChanged(try XCTUnwrap(lib.version(v2))), Date(timeIntervalSince1970: 200))
    }

    // MARK: 2 · a Compare pick and Compare new (decision 2)

    func testACompareRecordsWhatWasComparedAndItsPick() throws {
        let (lib, v1, v2) = try twoVersions()
        let text = lib.finishCompare(.chosen(item(v2, 1)), rejected: 5)
        XCTAssertEqual(text, "v2b chosen · 5 rejected", "the toast as before")
        let p = try part(lib)
        XCTAssertEqual(lib.chosen(of: p), LibraryChosen(folder: v2, result: 1))
        XCTAssertEqual(p.chosenInCompare, true, "★ picked THROUGH Compare")
        XCTAssertEqual(p.versions.map { $0.compared ?? [] }, [[0, 1, 2], [0, 1, 2]], "★ every result has been through a Compare")
        lib.pick(folder: v1, result: 0)
        XCTAssertNil(try part(lib).chosenInCompare, "★ a pick by hand is not a Compare pick")
    }

    /// ★ The rule: a new version's results clear a Compare pick (a draft or a running one does not, until it has results);
    /// Compare new then offers ONLY the new results, against the old pick.
    func testANewVersionsResultsClearAComparePickAndCompareNewOffersOnlyThem() throws {
        let (lib, _, v2) = try twoVersions()
        _ = lib.finishCompare(.chosen(item(v2, 1)), rejected: 5)
        // a draft (no results) does not clear it
        _ = try save(300, results: false)
        lib.refresh()
        XCTAssertEqual(lib.chosen(of: try part(lib)), LibraryChosen(folder: v2, result: 1), "★ a Draft does not clear the pick")
        // a running version does not, until its run is done
        let v4 = try save(400, results: true)
        lib.runningFolders = [v4]
        lib.refresh()
        loadSummaries(lib)
        XCTAssertEqual(try part(lib).version(folderID: v4)?.summary?.count, 3, "premise: v4's results are read")
        XCTAssertEqual(lib.chosen(of: try part(lib)), LibraryChosen(folder: v2, result: 1), "★ a running version does not clear it")
        lib.runningFolders = []
        let p = try part(lib)
        XCTAssertNil(lib.chosen(of: p), "★ its run done: v2b can no longer be picked")
        XCTAssertNil(p.chosenInCompare)
        XCTAssertEqual(lib.formerPick(of: p), LibraryChosen(folder: v2, result: 1), "★ it needs a compare: the former pick")
        XCTAssertEqual(lib.newResults(of: p), [item(v4, 0), item(v4, 1), item(v4, 2)], "★ the results never compared: v4's")
        // Compare new: the old pick against ONLY them
        let s = CompareSession(part: p, newAgainst: item(v2, 1), skipRejected: true)
        XCTAssertEqual(s.queue, [item(v2, 1), item(v4, 0), item(v4, 1), item(v4, 2)], "★ not everything again")
        XCTAssertEqual(s.left, item(v2, 1), "the old pick on the left")
        XCTAssertEqual(s.right, item(v4, 0))
        // RED control: the full Compare would offer every result again
        XCTAssertEqual(CompareSession(part: p, skipRejected: true).queue.count, 9, "the control: all nine")
        // kept in the Library's file
        let again = LibraryModel(store: store)
        again.refresh()
        let q = try part(again)
        XCTAssertEqual(again.formerPick(of: q), LibraryChosen(folder: v2, result: 1), "★ kept in library.json")
        XCTAssertNil(again.chosen(of: q))
        XCTAssertEqual(q.version(folderID: v2)?.compared, [0, 1, 2])
    }

    /// Compare new to its end: the last one left is chosen (through Compare), every result now compared, the chip gone.
    func testCompareNewToItsEndPicksAgain() throws {
        let (lib, _, v2) = try twoVersions()
        _ = lib.finishCompare(.chosen(item(v2, 1)), rejected: 5)
        let v3 = try save(400, results: true)
        lib.refresh(); loadSummaries(lib)
        XCTAssertEqual(try part(lib).version(folderID: v3)?.number, 3, "premise: the new version is v3")
        var s = CompareSession(part: try part(lib), newAgainst: item(v2, 1), skipRejected: true)
        while s.end == nil { if let loser = s.better(.right) { lib.rejectInCompare(loser) } }   // v3a wins every pair
        XCTAssertEqual(s.end, .chosen(item(v3, 0)))
        XCTAssertEqual(lib.finishCompare(try XCTUnwrap(s.end), rejected: s.rejected.count), "v3a chosen · 3 rejected")
        let p = try part(lib)
        XCTAssertEqual(lib.chosen(of: p), LibraryChosen(folder: v3, result: 0), "★ the new pick")
        XCTAssertEqual(p.chosenInCompare, true, "made through Compare again")
        XCTAssertNil(lib.formerPick(of: p))
        XCTAssertTrue(lib.newResults(of: p).isEmpty, "★ nothing left to compare")
        XCTAssertTrue(try XCTUnwrap(p.version(folderID: v2)).mark(for: 1).rejected, "the old pick lost: rejected, as Better does")
    }

    /// RED control for the rule: a pick made BY HAND (Pick this) is not cleared ("picked through the comparison").
    func testAPickByHandIsNotClearedByANewVersion() throws {
        let (lib, _, v2) = try twoVersions()
        lib.pick(folder: v2, result: 1)
        _ = try save(400, results: true)
        lib.refresh(); loadSummaries(lib)
        let p = try part(lib)
        XCTAssertEqual(lib.chosen(of: p), LibraryChosen(folder: v2, result: 1), "★ a pick by hand stays")
        XCTAssertNil(lib.formerPick(of: p))
        XCTAssertEqual(lib.newResults(of: p).count, 9, "(nothing was ever compared)")
    }

    /// Nothing new left to compare (the new version deleted): the old pick is the chosen one again.
    func testDeletingTheNewVersionGivesTheOldPickBack() throws {
        let (lib, _, v2) = try twoVersions()
        _ = lib.finishCompare(.chosen(item(v2, 1)), rejected: 5)
        let v4 = try save(400, results: true)
        lib.refresh(); loadSummaries(lib)
        XCTAssertNil(lib.chosen(of: try part(lib)), "premise: cleared")
        store.delete(id: v4)
        lib.refresh()
        XCTAssertEqual(lib.chosen(of: try part(lib)), LibraryChosen(folder: v2, result: 1), "★ the old pick stands again")
        XCTAssertEqual(try part(lib).chosenInCompare, true)
    }

    // MARK: 3 · Picked × (decision 3)

    func testUnpickLeavesThePartWithNoChosenResult() throws {
        let (lib, _, v2) = try twoVersions()
        lib.pick(folder: v2, result: 1)
        lib.unpick(part: try part(lib).id)
        XCTAssertNil(lib.chosen(of: try part(lib)), "★ × un-picks")
        XCTAssertNil(lib.chosenTag(try part(lib)))
        let again = LibraryModel(store: store)
        again.refresh()
        XCTAssertNil(again.chosen(of: try part(again)), "kept")
        XCTAssertEqual(LibraryFlagChip.pickedTitle, "Picked")
    }

    // MARK: the Library's file stays as it was

    /// The new marks are optional: a library.json written before reads with none, and saves without new keys.
    func testAnOldLibraryFileReadsAndSavesAsBefore() throws {
        let f = UUID(), id = UUID()
        let old = #"{"id":"\#(id)","name":"Stand","modelHash":"x","versions":[{"folderID":"\#(f)","number":1,"changes":[],"marks":[]}],"chosen":{"folder":"\#(f)","result":0}}"#
        let part = try JSONDecoder().decode(LibraryPart.self, from: Data(old.utf8))
        XCTAssertNil(part.chosenInCompare, "★ an old pick reads as a pick by hand")
        XCTAssertNil(part.formerPick)
        XCTAssertNil(part.versions[0].compared)
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(part)) as? [String: Any])
        for k in ["chosenInCompare", "formerPick"] { XCTAssertNil(again[k], "★ no new key: \(k)") }
        let v = try XCTUnwrap((again["versions"] as? [[String: Any]])?.first)
        XCTAssertNil(v["compared"], "★ no new key: compared")
    }

    // MARK: 4 · Details (decision 4)

    func testDetailsSayWhereItCameFromAndEverySettingInFewWords() throws {
        var v2 = LibraryVersion(folderID: UUID(), number: 2, parentNumber: 1,
                                changes: [VersionChange(.changed, .resolution, "Resolution 64 → 128", phrase: "res 128")])
        XCTAssertEqual(LibraryVersionFacts.origin(v2, snapshot: nil, draft: false), ["From v1", "Resolution 64 → 128"])
        XCTAssertEqual(LibraryVersionFacts.origin(v2, snapshot: nil, draft: true).first, "Edited from v1")
        v2.changes = []
        XCTAssertEqual(LibraryVersionFacts.origin(v2, snapshot: nil, draft: false), ["From v1", "Same settings"])
        XCTAssertEqual(LibraryVersionFacts.origin(LibraryVersion(folderID: UUID(), number: 1), snapshot: nil, draft: false), ["First run"])
        let id = try save(100, results: true)
        let snap = try XCTUnwrap(store.snapshot(id: id))
        let rows = LibraryVersionFacts.settings(snap)
        let labels = rows.map(\.0)
        for k in ["Goal", "Type", "Material", "Resolution", "Layer height", "Walls", "Infill", "Saved"] {
            XCTAssertTrue(labels.contains(k), "★ every setting it ran with: \(k) in \(labels)")
        }
        XCTAssertEqual(rows.first { $0.0 == "Goal" }?.1, "Minimize plastic")
        XCTAssertEqual(rows.first { $0.0 == "Material" }?.1, "PA12 · FDM")
        for (l, _) in rows { XCTAssertLessThanOrEqual(l.split(separator: " ").count, 5, "★ his rule: at most 5 words: \(l)") }
        XCTAssertEqual(LibraryVersionFacts.num(0.2), "0.2"); XCTAssertEqual(LibraryVersionFacts.num(51), "51")
        XCTAssertEqual(LibraryVersionFacts.num(0.12), "0.12")
    }
}

#if canImport(AppKit) && canImport(MetalKit)
@MainActor
final class LibraryNotes1122HostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-lib-1122h-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// The two iPad windows he tests on: 13″ landscape and portrait (820 × 1180).
    static let sizes: [(String, CGSize)] = [("13″ landscape", AppBuildHost.landscape13), ("portrait", CGSize(width: 820, height: 1180))]

    /// LibraryPartRowsHostedTests' Carriage Arms (v1, v2 with a · b · c and v2b picked by hand, v3 a draft, v1.1 a branch from
    /// v1), its numbers read, on its part page.
    private func host(_ size: CGSize, _ tag: String, before: (AppModel, [String: UUID], URL) throws -> Void = { _, _, _ in })
        throws -> (AppBuildHost, AppModel, [String: UUID]) {
        let dir = root.appendingPathComponent("\(tag)-\(Int(size.width))", isDirectory: true)
        let (app, f) = try LibraryPartRowsHostedTests.arms(root: dir)
        let exp = expectation(description: "summaries")
        app.library.loadSummaries { exp.fulfill() }
        wait(for: [exp], timeout: 30)
        try before(app, f, dir)
        app.library.route = .part(try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"]))).id)
        let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
        h.pump(3)
        return (h, app, f)
    }

    private func frame(_ h: AppBuildHost, _ key: String, _ what: String) throws -> CGRect {
        try XCTUnwrap(h.frames.all[key], "★ \(what): no frame '\(key)'")
    }

    /// Wait (up to `seconds`) until `key` has a frame.
    @discardableResult
    private func waitFor(_ h: AppBuildHost, _ key: String, seconds: Double = 8) -> CGRect? {
        var waited = 0.0
        while h.frames.all[key] == nil, waited < seconds { h.pump(0.25); waited += 0.25 }
        return h.frames.all[key]
    }

    /// A long press on iPad is a right click on the Mac host: open the card's context menu and pick `title`. Returns what the
    /// menu offered.
    @discardableResult
    private func longPress(_ h: AppBuildHost, at p: CGPoint, pick title: String) -> [String] {
        var offered: [String] = []
        let obs = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard let m = n.object as? NSMenu else { return }
            RunLoop.main.perform(inModes: [.eventTracking, .default, .modalPanel]) {
                offered = m.items.filter { !$0.isSeparatorItem }.map(\.title)
                guard let i = m.items.firstIndex(where: { $0.title == title && $0.isEnabled }) else { m.cancelTracking(); return }
                m.cancelTracking()
                m.performActionForItem(at: i)
            }
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            h.pump(0.06)
        }
        h.pump(2)
        return offered
    }

    // MARK: 1 · the order

    func testNewestAtTheTopAndTheRejectedSectionAtTheBottom() throws {
        for (name, size) in Self.sizes {
            let (h, _, _) = try host(size, "order") { app, f, _ in
                for r in 0..<3 { app.library.toggleReject(folder: try XCTUnwrap(f["1"]), result: r) }   // all of v1's results
                app.library.toggleReject(folder: try XCTUnwrap(f["2"]), result: 2)                     // one of v2's
            }
            let b = try frame(h, "library-version-v1.1", "\(name): v1.1"), v3 = try frame(h, "library-version-v3", "\(name): v3")
            let v2 = try frame(h, "library-version-v2", "\(name): v2"), v1 = try frame(h, "library-version-v1", "\(name): v1")
            XCTAssertTrue(LibraryPartRowsHostedTests.before(b, v3), "\(name): ★ the newest (v1.1, saved last) first")
            XCTAssertTrue(LibraryPartRowsHostedTests.before(v3, v2), "\(name): ★ the draft by its date, not pinned first")
            let section = try frame(h, "library-rejected-section", "\(name): ★ the Rejected section")
            for c in [b, v3, v2] { XCTAssertGreaterThan(section.minY, c.maxY, "\(name): ★ under every card up top") }
            XCTAssertGreaterThan(v1.minY, section.maxY, "\(name): ★ v1 (every result rejected) in the bottom section")
            XCTAssertNotNil(h.frames.all["library-result-v2c-rejected"], "\(name): ★ v2 (one rejected) stays up top, its flag as before")
            XCTAssertLessThan(v2.maxY, section.minY, "\(name): v2 up top")
        }
    }

    // MARK: 3 · Picked ×

    func testPickedHasAnXAndATapUnpicks() throws {
        for (name, size) in Self.sizes {
            let (h, app, f) = try host(size, "unpick")
            let chip = try h.probe("library-result-v2b-picked", "\(name): ★ Picked ×, a 44 pt target")
            h.click(CGPoint(x: chip.midX, y: chip.midY), settle: 1)
            let part = try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"])))
            XCTAssertNil(app.library.chosen(of: part), "\(name): ★ the tap un-picks: the part has no chosen result")
            XCTAssertNil(h.frames.all["library-result-v2b-picked"], "\(name): Picked is gone from the card")
            XCTAssertEqual(app.screen, .home, "\(name): the tap does not open anything")
        }
    }

    // MARK: 4 · the taps

    /// The result the workspace's Results opens on by itself (the control: the tap must change it).
    private func resultsDefault() -> Int { ResultsModel(projectName: "x", outcome: AppBuildFixtures.outcome()).selectedVariantIndex }

    /// The workspace is up on v1's Results, on result `r`: its selected line is r's (Pick this sits on the selected line).
    private func assertResultsOn(_ h: AppBuildHost, _ r: Int, _ what: String) throws {
        guard waitFor(h, "resultsPickThis", seconds: 10) != nil else { return XCTFail("★ \(what): Results did not open") }
        // Results takes the result to open on as it appears, so its selected line moves on the next pass. The host's window is
        // off screen with no display link, and that pass's frames are not always sent again (LibraryCompareStepsHostedTests'
        // `landed`): one layout pass sends them as they are.
        h.pump(1)
        h.view.setFrameSize(NSSize(width: h.size.width, height: h.size.height + 1)); h.pump(0.3)
        h.view.setFrameSize(NSSize(width: h.size.width, height: h.size.height)); h.pump(0.5)
        let pick = try frame(h, "resultsPickThis", what)
        let rm = ResultsModel(projectName: "x", outcome: AppBuildFixtures.outcome())
        let tab = try XCTUnwrap(rm.tabs.first { $0.variantIndex == r && !$0.isLatticed }, "\(what): result \(r)'s line")
        let line = try frame(h, "resultsVersion-t\(tab.index)", what)
        XCTAssertTrue(line.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: pick.midX, y: pick.midY)),
                      "★ \(what): Results is on result \(ResultMark.letter(r)) (\(line) holds the selected line's Pick this \(pick))")
    }

    func testAPicturesTapOpensTheVersionOnThatResult() throws {
        let r = (resultsDefault() + 1) % 3   // a result Results would not open on by itself
        let letter = ResultMark.letter(r)
        XCTAssertNotEqual(r, resultsDefault(), "the control: Results would not open on it by itself")
        for (name, size) in Self.sizes {
            let (h, app, f) = try host(size, "picture")
            let mini = try h.probe("library-mini-v1\(letter)", "\(name): v1\(letter)'s picture, a 44 pt target")
            h.click(CGPoint(x: mini.midX, y: mini.midY), settle: 2)
            XCTAssertEqual(app.screen, .workspace, "\(name): ★ a tap on the picture opens it")
            XCTAssertEqual(app.project?.id, f["1"], "\(name): v1")
            XCTAssertEqual(LibraryCardOpen.lastAsked?.result, r)
            try assertResultsOn(h, r, "\(name): the picture's tap")
        }
    }

    func testAResultNamesTapOpensTheVersionOnThatResult() throws {
        let r = (resultsDefault() + 2) % 3
        let letter = ResultMark.letter(r)
        XCTAssertNotEqual(r, resultsDefault(), "the control: Results would not open on it by itself")
        for (name, size) in Self.sizes {
            let (h, app, f) = try host(size, "name")
            let n = try h.probe("library-result-v1\(letter)-name", "\(name): ★ \"v1\(letter)\", a 44 pt target")
            h.click(CGPoint(x: n.midX, y: n.midY), settle: 2)
            XCTAssertEqual(app.screen, .workspace, "\(name): ★ a tap on \"v1\(letter)\" opens it")
            XCTAssertEqual(app.project?.id, f["1"])
            try assertResultsOn(h, r, "\(name): the name's tap")
        }
    }

    /// A draft's picture opens the draft.
    func testADraftsPictureOpensIt() throws {
        let (h, app, f) = try host(AppBuildHost.landscape13, "draft")
        let pic = try h.probe("library-version-v3-picture", "v3's picture")
        h.click(CGPoint(x: pic.midX, y: pic.midY), settle: 2)
        XCTAssertEqual(app.project?.id, f["3"], "★ the draft opens")
        XCTAssertNil(LibraryCardOpen.lastAsked?.result, "a draft has no results to open on")
    }

    // MARK: 4 · Details

    func testDetailsFromTheMenuShowsTheWholeVersion() throws {
        for (name, size) in Self.sizes {
            let (h, app, f) = try host(size, "details")
            let v2 = try XCTUnwrap(f["2"])
            try h.pickFromMenu("library-version-v2-menu", "Details", what: "\(name): v2's ⋯")
            h.pump(1)
            XCTAssertEqual(app.library.route, .details(v2), "\(name): ★ ⋯ › Details")
            _ = try frame(h, "library-details-v2", "\(name): ★ v2's Details page")
            try h.probe("library-details-v2-picture", "\(name): ★ its picture (a tap opens it)")
            _ = try h.onScreen("library-details-v2-results", "\(name): ★ its numbers, stars and flags")
            for k in ["from", "settings"] { _ = try frame(h, "library-details-v2-\(k)", "\(name): ★ \(k)") }
            for l in ["a", "b", "c"] { _ = try frame(h, "library-details-v2\(l)", "\(name): v2\(l)'s line") }
            try h.probe("library-details-v2-open", "\(name): Open v2")
            try h.probe("library-details-v2-back", "\(name): back")
            // its flags come off as on the card: Picked ×
            let picked = try h.probe("library-details-v2b-picked", "\(name): ★ Picked ×")
            h.click(CGPoint(x: picked.midX, y: picked.midY), settle: 1)
            XCTAssertNil(app.library.chosen(of: try XCTUnwrap(app.library.index.part(containing: v2))), "\(name): ★ un-picked")
            let back = try frame(h, "library-details-v2-back", "\(name): back")
            h.click(CGPoint(x: back.midX, y: back.midY), settle: 1)
            XCTAssertEqual(app.library.route, .part(try XCTUnwrap(app.library.index.part(containing: v2)).id), "\(name): back to the part")
        }
    }

    func testALongPressOnACardIsTheMenuWithDetails() throws {
        for (name, size) in Self.sizes {
            let (h, app, f) = try host(size, "longpress")
            let card = try frame(h, "library-version-v2", "\(name): v2's card")
            let line = try frame(h, "library-result-v2a", "\(name): v2a's line")
            // on the card, clear of its buttons: the strip between its name line and its first result's line
            let offered = longPress(h, at: CGPoint(x: card.midX, y: line.minY - 3), pick: "Details")
            XCTAssertEqual(offered.first, "Details", "\(name): ★ the long press's menu, Details first: \(offered)")
            for k in ["Quick look", "Open v2", "New draft from v2", "Rename…", "Delete v2…"] {
                XCTAssertTrue(offered.contains(k), "\(name): ★ and what the ⋯ has: \(k) in \(offered)")
            }
            h.pump(1)
            XCTAssertEqual(app.library.route, .details(try XCTUnwrap(f["2"])), "\(name): ★ Details opens v2's page")
        }
    }

    // MARK: 2 · Compare new

    /// One more version of the lookalike, saved at `t` with three results (arms' own way).
    static func saveVersion(_ dir: URL, store: ProjectStore, t: Double) throws -> UUID {
        let model = dir.appendingPathComponent("import", isDirectory: true).appendingPathComponent("Carriage Arms.stl")
        let snap = ProjectSnapshot(id: UUID(), name: "Carriage Arms", material: "PA12", process: .fdm, modelFileName: "model.stl",
                                   originalFileName: "Carriage Arms.stl", savedAt: Date(timeIntervalSince1970: t),
                                   selection: SelectionModel(), force: ForceModel(), quality: .fast, optimized: true)
        try store.save(snap, modelSource: model)
        try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: AppBuildFixtures.outcome())), id: snap.id)
        return snap.id
    }

    func testCompareNewOnTheFormerPicksLine() throws {
        for (name, size) in Self.sizes {
            var v4: UUID?
            let (h, app, f) = try host(size, "comparenew") { app, f, dir in
                _ = app.library.finishCompare(.chosen(CompareItem(folder: try XCTUnwrap(f["2"]), result: 1)), rejected: 0)
                v4 = try Self.saveVersion(dir, store: app.library.store, t: 500)
                app.library.refresh()
                let exp = self.expectation(description: "v4's numbers")
                app.library.loadSummaries { exp.fulfill() }
                self.wait(for: [exp], timeout: 30)
            }
            let v2 = try XCTUnwrap(f["2"])
            let part = try XCTUnwrap(app.library.index.part(containing: v2))
            XCTAssertEqual(part.version(folderID: try XCTUnwrap(v4))?.number, 4, "premise: the new version is v4")
            XCTAssertNil(app.library.chosen(of: part), "\(name): ★ v4's results cleared the Compare pick")
            XCTAssertNil(h.frames.all["library-result-v2b-picked"], "\(name): v2b no longer reads Picked")
            let chip = try h.probe("library-result-v2b-compare-new", "\(name): ★ \"Compare new\" on the old pick's line")
            XCTAssertLessThanOrEqual(LibraryVersionCard.compareNewTitle.split(separator: " ").count, 3)
            h.click(CGPoint(x: chip.midX, y: chip.midY), settle: 2)
            _ = try frame(h, "compare-showing-v2b", "\(name): ★ Compare opens on the old pick")
            _ = try frame(h, "compare-showing-v4a", "\(name): ★ against the first new result")
            XCTAssertNil(h.frames.all["compare-showing-v1a"], "\(name): ★ not everything again")
        }
    }
}
#endif
