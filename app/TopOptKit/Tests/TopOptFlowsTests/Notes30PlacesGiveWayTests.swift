// Notes30PlacesGiveWayTests — ★ notes30 Q1 (the strut-stream scope's S-2, his yes 2026-11-26): after a strut lattice lands, the
// chips' places search (D23, `LatticeLayoutSession.places`) runs on the part's one layout worker; on a big flat part it took
// 3.1 s, so a setting changed right then waited behind it. Now the search gives way at once:
//   * a newer lay asked while the search runs begins on the worker within 0.1 s: the search comes back cancelled — none,
//     never part of a list — and runs again for the lattice that lands next (its chips the same as a whole search's);
//   * the page's next setting (the asking task cancelled) frees the worker at once too;
//   * the solid-reason check's map (what `solidReasonCheck` reads after landing) gives way within 0.1 s too: it read the
//     session's stop once per slab, which on a flat part is most of the map (measured: 0.5 s); now once per row;
//   * through the page: a setting changed while the last lattice's search runs begins its lay within 0.1 s, and the chips on
//     screen are the new lattice's own (a whole search's, on a fresh session).
// Each "within 0.1 s" is the best of a few tries: on a busy Mac the threads' own scheduling adds its wait (measured with the
// load average over 200), while a worker that is held never gets under the bar in any try.
// RED CONTROL `LatticeLayoutSession.controlPlacesHoldTheWorker`: the search before Q1 — the lay waits for it.
// The part: a synthetic 240 x 240 x 20 mm plate with eight blind tunnels under its top (never his files).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class Notes30PlacesGiveWayTests: XCTestCase {

    override func tearDown() {
        LatticeLayoutSession.controlPlacesHoldTheWorker = false
        super.tearDown()
    }

    /// The bar: a lay asked while the worker is busy begins within this (s).
    static let atOnceS = 0.1
    /// The RED CONTROL's: a lay that waits for the search waits at least this (s) — five times the bar.
    static let waitedS = 0.5

    /// The big flat part: a 240 x 240 x 20 mm plate, eight tunnels 5-12 mm up (open at the front, blind at the back) under its
    /// top — the faces a lattice laid under the top runs into, places that no rule decides (core's D23, as LatticePlaceChipsTests'
    /// tunnel, many times over).
    static func flatPlate(_ test: XCTestCase) throws -> (path: String, top: Int32) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes30-q1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("flat-plate.stl").path
        let xy = stride(from: Float(0), through: 240, by: 10).map { $0 }
        try LatticePlaceChipsTests.gridSTL(xy, xy, [0, 5, 12, 20]) { i, j, k in !(k == 1 && i % 3 == 1 && j < 23) }
            .write(to: URL(fileURLWithPath: path))
        let mesh = try TopOptKit.importMesh(path: path)
        return (path, try XCTUnwrap(LatticePlaceChipsTests.face(mesh, axis: 2, sign: 1, at: 20), "the top"))
    }

    /// A lattice 18 mm deep under the plate's top, cells up to `cellMM`.
    static func settings(top: Int32, cellMM: Double) -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        s.regions = [.init(id: 1, faces: [top], depthMM: 18)]
        s.cellMaxMM = cellMM
        return s
    }

    /// A lay asked now: how long until it began on the worker (`LatticeLayoutSession.lastLayBegan`), and its own time.
    static func timedLay(_ session: LatticeLayoutSession, _ s: LatticeLayoutSession.Settings) async throws
        -> (startS: Double, workS: Double) {
        let asked = Date()
        let r = try await session.lay(s)
        return (LatticeLayoutSession.lastLayBegan.timeIntervalSince(asked), (r.msRead + r.msCells + r.msBars + r.msBridge) / 1000)
    }

    /// ★ A newer lay asked while the places search runs begins at once; the search comes back cancelled and runs again for the
    /// new lattice. The page's next setting frees the worker at once too. The solid-reason map gives way too. RED CONTROL: the
    /// lay waits for the search.
    func testANewerLayStartsAtOnceWhileThePlacesSearchRuns() async throws {
        let plate = try Self.flatPlate(self)
        let session = try await LatticeLayoutSession.open(path: plate.path)
        addTeardownBlock { session.close() }
        var cur = Self.settings(top: plate.top, cellMM: 6), nxt = Self.settings(top: plate.top, cellMM: 7)
        _ = try await session.lay(nxt)
        let idle = try await Self.timedLay(session, cur)   // nothing holds the worker
        let whole = try await session.places(cur)
        print(String(format: "NOTES30-Q1 plate: lay %.2f s (began %.3f s after it was asked, the worker idle); places %.2f s, "
                     + "%d places", idle.workS, idle.startS, whole.ms / 1000, whole.places.count))
        XCTAssertGreaterThan(whole.ms, 1000, "premise: a slow places search (a big flat part)")
        XCTAssertFalse(whole.places.isEmpty, "premise: the tunnels are places")
        let into = UInt64(min(whole.ms / 4, 500) * 1e6)   // well inside the search (2 s or more, quiet or busy)

        // ★ three changes, each made while the last lattice's search runs
        var starts: [Double] = []
        for _ in 0..<3 {
            let search = Task { [cur] in try await session.places(cur) }
            try await Task.sleep(nanoseconds: into)
            starts.append(try await Self.timedLay(session, nxt).startS)   // the setting changed while it runs
            let given = await search.result
            XCTAssertThrowsError(try given.get(), "★ the search gave way") { XCTAssertTrue($0 is CancellationError) }
            swap(&cur, &nxt)
        }
        print("NOTES30-Q1 ★: a lay asked during places began after " + starts.map { String(format: "%.3f s", $0) }.joined(separator: ", "))
        XCTAssertLessThan(starts.min() ?? 9, Self.atOnceS, "★ the newer lay begins within 0.1 s of being asked")
        // the search runs again for the new lattice: whole, the same as a search of it alone
        let again = try await session.places(cur)
        XCTAssertFalse(again.places.isEmpty, "★ the new lattice's chips come")
        let fresh = try await LatticeLayoutSession.open(path: plate.path)
        _ = try await fresh.lay(cur)
        let alone = try await fresh.places(cur).places
        fresh.close()
        XCTAssertEqual(again.places.map(\.faces), alone.map(\.faces), "★ its chips are the new lattice's own")
        XCTAssertEqual(again.places.map(\.solidNow), alone.map(\.solidNow))

        // ★ the page's next setting: the asking task cancelled frees the worker at once (a call of no cost queued behind it:
        // no stress, as before)
        var freed: [Double] = []
        for _ in 0..<3 {
            let asking = Task { [cur] in try await session.places(cur) }
            try await Task.sleep(nanoseconds: into)
            let t0 = Date()
            asking.cancel()
            try await session.setDemand(mpa: nil, nx: 0, ny: 0, nz: 0, origin: .zero, spacingMM: 0)
            freed.append(Date().timeIntervalSince(t0))
            _ = await asking.result
        }
        print("NOTES30-Q1 ★: the asking task cancelled, the worker free after " + freed.map { String(format: "%.3f s", $0) }.joined(separator: ", "))
        XCTAssertLessThan(freed.min() ?? 9, Self.atOnceS, "★ the worker free at once")

        // RED CONTROL: the search before Q1 — the lay, and the worker, wait for it
        LatticeLayoutSession.controlPlacesHoldTheWorker = true
        let search = Task { [cur] in try await session.places(cur) }
        try await Task.sleep(nanoseconds: into)
        let red = try await Self.timedLay(session, nxt)
        let ranOut = try await search.value
        XCTAssertFalse(ranOut.places.isEmpty, "RED CONTROL: the search ran to its end (its whole list)")
        swap(&cur, &nxt)
        let asking = Task { [cur] in try await session.places(cur) }
        try await Task.sleep(nanoseconds: into)
        let t0 = Date()
        asking.cancel()
        try await session.setDemand(mpa: nil, nx: 0, ny: 0, nz: 0, origin: .zero, spacingMM: 0)
        let redFreed = Date().timeIntervalSince(t0)
        _ = await asking.result
        LatticeLayoutSession.controlPlacesHoldTheWorker = false
        print(String(format: "NOTES30-Q1 RED CONTROL: a lay asked during places began after %.3f s; the asking task cancelled, "
                     + "the worker free after %.3f s", red.startS, redFreed))
        XCTAssertGreaterThan(red.startS, Self.waitedS, "RED CONTROL: the lay waited for the search")
        XCTAssertGreaterThan(redFreed, Self.waitedS, "RED CONTROL: the worker held until the search ends")

        // ★ the solid-reason check's map (solidReasonCheck: the first map after landing, its SolidAt made then) gives way to a
        // newer lay too, wherever it is asked (a try counts only when the map gave way: it was still running when asked)
        let box = (lo: SIMD3<Float>(0, 0, 0), hi: SIMD3<Float>(240, 240, 20))
        _ = try await session.lay(cur)
        let m0 = Date()
        _ = try await LatticeLayoutPreview.unheldReport(session, box)
        let mapS = Date().timeIntervalSince(m0)
        var asks = 0
        for at in [0.02, 0.06, 0.12] {   // s into the map (asked from here: 0.4 s, its grid alone about half of it)
            var tries: [Double] = []
            for _ in 0..<4 where tries.count < 2 {
                _ = try await session.lay(cur)
                let check = Task { try await LatticeLayoutPreview.unheldReport(session, box) }
                try await Task.sleep(nanoseconds: UInt64(at * 1e9))
                let start = try await Self.timedLay(session, nxt).startS
                if try await check.value == nil { tries.append(start) }   // it gave way: nothing read
            }
            print(String(format: "NOTES30-Q1: the solid-reason map takes %.3f s; a lay asked %.2f s in began after ", mapS, at)
                  + (tries.isEmpty ? "(the map had ended)" : tries.map { String(format: "%.3f s", $0) }.joined(separator: ", ")))
            asks += tries.count
            if !tries.isEmpty {
                XCTAssertLessThan(tries.min() ?? 9, Self.atOnceS, "★ the solid-reason map gives way to the newer lay (\(at) s in)")
            }
        }
        XCTAssertGreaterThanOrEqual(asks, 2, "premise: lays asked while the map ran")
    }

    // MARK: through the page

    /// The plate's project: Structural, a lattice group on its top, 18 mm deep, cells of 6 mm.
    @MainActor
    static func plateProject(_ plate: (path: String, top: Int32)) throws -> ProjectModel {
        let p = try FlexiblePressFixtures.project(path: plate.path, name: "flat-plate")
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.wholePart = false
        p.lattice.enabled = true
        p.lattice.cellSizeMode = .fixed
        p.lattice.cellMM = 6
        let g = try XCTUnwrap(p.latticeStageTap(face: plate.top, loop: [plate.top]), "the top's group")
        p.lattice.groupRoles[g] = .include
        p.lattice.groupDepthMM[g] = 18
        let s = LatticeLayoutPreview.settings(p)
        XCTAssertTrue(s.regions.contains { $0.faces == [plate.top] && !$0.noLattice }, "premise: a lattice region on the top")
        return p
    }

    /// ★ Through the page (Live preview: its lays are quiet): a setting changed while the last lattice's places search runs
    /// begins its lay within 0.1 s, and the chips on screen are the NEW lattice's own (a whole search's, on a fresh session).
    /// RED CONTROL: its lay begins only after the old search ends.
    @MainActor
    func testThePageLaysAtOnceDuringPlacesAndShowsTheNewLatticesChips() async throws {
        let plate = try Self.flatPlate(self)
        let p = try Self.plateProject(plate)
        let preview = LatticeLayoutPreview()
        defer { preview.clear() }

        /// Asks `cellMM` and waits for its lattice to land: how long after it was asked its lay began on the worker.
        func land(_ cellMM: Double) async throws -> Double {
            let before = preview.bars?.token
            p.lattice.cellMM = cellMM
            let asked = Date()
            preview.update(project: p, on: true, live: true)
            let end = Date().addingTimeInterval(300)
            while preview.laying || preview.bars?.token == before, Date() < end { try await Task.sleep(nanoseconds: 2_000_000) }
            XCTAssertNotEqual(preview.bars?.token, before, "\(cellMM) mm: laid")
            return LatticeLayoutSession.lastLayBegan.timeIntervalSince(asked)
        }
        /// Waits for the chips of the lattice on screen (its search asked, then its answer on the page).
        func chips(after asked: Int, _ ms: Double) async throws {
            let end = Date().addingTimeInterval(300)
            while LatticeLayoutSession.placesAsked <= asked || preview.placesMS == ms, Date() < end {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        /// Waits until the page's search for the lattice on screen is asked (it runs on the worker from then on).
        func searching(after asked: Int) async throws {
            let end = Date().addingTimeInterval(300)
            while LatticeLayoutSession.placesAsked <= asked, Date() < end { try await Task.sleep(nanoseconds: 1_000_000) }
        }

        var asked = LatticeLayoutSession.placesAsked
        let none = preview.placesMS
        _ = try await land(6)
        try await chips(after: asked, none)
        XCTAssertFalse(preview.places.isEmpty, "premise: the first lattice's chips")
        let searchMS = preview.placesMS
        // a lay asked with the worker idle (its chips came; nothing holds the worker)
        asked = LatticeLayoutSession.placesAsked
        let idle = try await land(7)
        try await chips(after: asked, searchMS)
        print(String(format: "NOTES30-Q1 page: places %.2f s; a lay asked on an idle worker began after %.3f s", searchMS / 1000,
                     idle))
        XCTAssertGreaterThan(searchMS, 1000, "premise: a slow places search")
        let into = UInt64(min(searchMS / 4, 500) * 1e6)   // well inside the search

        // ★ three changes, each made while the last lattice's search runs
        var starts: [Double] = []
        var lastMS = preview.placesMS
        asked = LatticeLayoutSession.placesAsked
        _ = try await land(6)
        for c in [7.0, 6.0, 7.0] {
            try await searching(after: asked)   // the last lattice's search runs
            try await Task.sleep(nanoseconds: into)
            lastMS = preview.placesMS
            asked = LatticeLayoutSession.placesAsked
            starts.append(try await land(c))   // the setting changed while it runs
        }
        print("NOTES30-Q1 page ★: changed during places, its lay began after "
              + starts.map { String(format: "%.3f s", $0) }.joined(separator: ", "))
        XCTAssertLessThan(starts.min() ?? 9, Self.atOnceS, "★ its lay began within 0.1 s of the change")
        // the chips on screen: the new lattice's own
        try await chips(after: asked, lastMS)
        let fresh = try await LatticeLayoutSession.open(path: plate.path, printUp: LatticeLayoutPreview.printUp(p))
        _ = try await fresh.lay(LatticeLayoutPreview.settings(p))
        let own = try await fresh.places(LatticeLayoutPreview.settings(p)).places
        fresh.close()
        XCTAssertFalse(preview.places.isEmpty, "★ the new lattice's chips")
        XCTAssertEqual(preview.places.map(\.faces), own.map(\.faces), "★ the chips are the new lattice's own")
        XCTAssertTrue(preview.isCurrent(project: p), "★ the newest settings' lattice")

        // RED CONTROL: the search before Q1 — the lay waits for it
        LatticeLayoutSession.controlPlacesHoldTheWorker = true
        asked = LatticeLayoutSession.placesAsked
        _ = try await land(8)
        try await searching(after: asked)
        try await Task.sleep(nanoseconds: into)
        let red = try await land(9)
        print(String(format: "NOTES30-Q1 page RED CONTROL: changed during places, its lay began after %.3f s", red))
        XCTAssertGreaterThan(red, Self.waitedS, "RED CONTROL: its lay waited for the old search")
    }
}
#endif
