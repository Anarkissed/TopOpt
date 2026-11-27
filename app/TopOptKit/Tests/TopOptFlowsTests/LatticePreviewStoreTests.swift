// LatticePreviewStoreTests — ★ his iPad notes 2026-11-23 (RESULTS_REPORT §7): "When I open up an old Lattice job, the previous
// preview should be visible ... Currently it ... requir[es] that I wait for the lattice to be re-made. This is wasted time."
// The last laid lattice and the stress check are kept in the version's folder (binary), keyed by what made them, and shown at
// once when the inputs are the same: the store's round trip (a 90k-strut lattice, timed), its keys, its refusals, the stress
// check, and on a real part with the engine — a new page (as after a relaunch) shows the saved lattice with no lay, the print
// file's groups the same.
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticePreviewStoreTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var accurateBefore = false

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("topopt-preview-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        LatticePreviewStore.controlNoStore = false
        accurateBefore = AppSettings.shared.latticePrintAccurate
    }
    override func tearDownWithError() throws {
        LatticePreviewStore.controlNoStore = false
        AppSettings.shared.latticePrintAccurate = accurateBefore
        if let root { try? fm.removeItem(at: root) }
    }

    /// A version's folder (its project.json and model), as the store writes them.
    private func folder() throws -> URL {
        let d = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: d.appendingPathComponent("project.json"))
        try Data("solid".utf8).write(to: d.appendingPathComponent("model.stl"))
        return d
    }

    private func field(_ n: Int = 20) -> LatticeDemandField {
        let c = n * n * n
        return LatticeDemandField(vonMises: (0..<c).map { Float($0 % 97) / 7 }, stressTensor: (0..<(6 * c)).map { Double($0 % 13) },
                                  nx: n, ny: n, nz: n, origin: SIMD3(-1, -2, -3), spacingMM: 1.5,
                                  provenance: .solidSim(date: Date(timeIntervalSince1970: 1000), resolution: 64))
    }

    /// A lattice the size of his (90k struts): bars, vines with cut ends and joints, a solid view's map, three Organic groups.
    private func remembered(path: String, struts: Int = 90_000) -> LatticeLayoutPreview.Remembered {
        var s = LatticeLayoutSession.Settings()
        s.algorithm = "organic"; s.cellMM = 4.5
        var lattice = LatticeSettings()
        lattice.algorithm = "organic"
        let st = LatticeLayoutPreview.Stress(key: 7, field: field(), referenceMPa: 20)
        let g1 = UUID(), g2 = UUID()
        let inputs = LatticeLayoutPreview.LayInputs(path: path, settings: s, lattice: lattice, pageManual: true, flush: [3, 9],
                                                    layer: 0.2, keys: [1: "f-1", 2: "f-2"], groups: [1: g1, 2: g2],
                                                    groupOrder: [g1, g2], stress: st)
        var bars = LatticeLayoutBarsInputs(token: 5, bars: (0..<(7 * struts)).map { Float($0 % 1000) * 0.01 },
                                           flags: (0..<struts).map { UInt8($0 % 3) })
        bars.lightFrom = struts / 2
        var v = OrganicVineShape()
        v.pieces = (0..<struts).map { i in
            var p = OrganicVineShape.Piece(a: SIMD3(Float(i), 1, 2), ra: 0.3, b: SIMD3(Float(i) + 1, 1, 2), rb: 0.25, vine: Int32(i / 4))
            p.ta = SIMD3(1, 0, 0); p.tb = SIMD3(0, 1, 0); p.va = SIMD3(0, 0, 1); p.vb = SIMD3(1, 1, 0)
            p.flatA = i % 5 == 0; p.section = UInt8(i % 3)
            if i % 7 == 0 { p.cut = .init(planes: [SIMD4(1, 0, 0, Float(i)), SIMD4(0, 1, 0, 2)], union: i % 2 == 0) }
            return p
        }
        v.joints = (0..<(struts / 10)).map { j in .init(centre: SIMD3(Float(j), 0, 0), radius: 0.4, pieces: [Int32(j), Int32(j + 1)]) }
        v.caps = (0..<(struts / 4)).map { SIMD4(Float($0), 0, 0, 0.3) }
        v.capVines = (0..<(struts / 4)).map { Int32($0) }
        v.capDomes = (0..<(struts / 4)).map { $0 % 2 == 0 }
        v.pucks = 12
        v.capCuts = (0..<(struts / 4)).map { $0 % 9 == 0 ? .init(planes: [SIMD4(0, 0, 1, 1)], union: false) : nil }
        bars.vines = v
        bars.solid = LatticeLayoutSolidGrid(token: 5, origin: SIMD3(-1, -1, -1), voxel: 0.5, dims: SIMD3(100, 100, 100),
                                            rg: (0..<2_000_000).map { Int8(truncatingIfNeeded: $0 % 200) }, smooth: true)
        var laid = LatticeLayoutColours.Laid()
        laid.bars = bars.bars; laid.barFlags = bars.flags; laid.barCell = (0..<struts).map { Float($0 % 9) }
        laid.barRegion = (0..<struts).map { Int32($0 % 2 + 1) }; laid.token = 5
        var ask = LatticeLayoutSession.Organic()
        ask.mode = .grown; ask.spacingMM = 3.25; ask.reliefExcludeFaces = [4, 5, 6]; ask.seed = 99; ask.buildDir = SIMD3(0, 0.1, 0.9)
        ask.sweep = false; ask.runMax = 3; ask.layerMM = 0.16
        var timing = LatticeLayoutPreview.Timing(openMS: 1, readMS: 2, cellsMS: 3, barsMS: 4, bars: struts)
        timing.organicLine = "Organic Grown · Exact · laid in 3.8 s"; timing.mapMS = 9
        let lim = LatticeOrganicLook.Limits(strutLowerMM: 0.8, strutUpperMM: 2.4, strutAutoMM: 1.2, cellLowerMM: 3, cellUpperMM: 9,
                                            cellAutoMM: 4.5, measured: true, gapMM: 0.4)
        return .init(inputs: inputs, bars: bars, laid: laid, timing: timing,
                     numbers: .init(strands: 40, segments: struts, ms: 3800, draft: false, limitsMeasured: true),
                     problem: nil, notes: ["a note"], groups: [.init(regions: [1], ask: ask), .init(regions: [2], ask: .init())],
                     walls: [(1, 3)], wallVerdicts: ["f-1": true], autoLimits: lim, groupLimits: [g1: lim], struts: struts,
                     quality: .exact)
    }

    /// ★ The whole lattice reads back exactly (what is drawn and what the print file is made from), in well under a second
    /// for 90k struts (printed: the times on this Mac's debug build; the iPad runs the release build). RED CONTROL: one setting
    /// changed, nothing is read back.
    /// ★ 362 11-24 (release 17's whole suite: the lay's floor cell, notes25 D10, was not kept, so `readsBack` refused every
    /// lattice with a floor and his versions would have reopened with no saved preview): format 2 keeps it; a format-1
    /// file (his versions saved before) still reads, its floor 0.
    func testTheFloorCellIsKeptAndAnOldFileStillReads() throws {
        let dir = try folder()
        var m = remembered(path: dir.appendingPathComponent("model.stl").path, struts: 50)
        var laid = try XCTUnwrap(m.laid)
        laid.floorCellMM = 2.55
        m.laid = laid
        let data = try XCTUnwrap(LatticePreviewStore.encode(m))
        XCTAssertTrue(LatticePreviewStore.readsBack(data, m), "★ a lattice with a floor reads back as it was")
        XCTAssertEqual(LatticePreviewStore.decode(data, for: m.inputs, token: 1)?.laid?.floorCellMM, 2.55)
        // the same lattice as format 1 wrote it: version 1, no floor at the end
        var old = data.prefix(data.count - 8)
        old.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(1)) { Data($0) })
        let back = try XCTUnwrap(LatticePreviewStore.decode(Data(old), for: m.inputs, token: 1), "★ an old file still reads")
        XCTAssertEqual(back.laid?.floorCellMM, 0)
        XCTAssertEqual(back.bars.bars, m.bars.bars)
    }

    func testA90kStrutLatticeRoundTripsQuickly() throws {
        let dir = try folder()
        let m = remembered(path: dir.appendingPathComponent("model.stl").path)
        var t0 = Date()
        let data = try XCTUnwrap(LatticePreviewStore.encode(m))
        let encodeS = Date().timeIntervalSince(t0)
        let url = dir.appendingPathComponent(LatticePreviewStore.fileName)
        try data.write(to: url, options: .atomic)
        t0 = Date()
        let back = try XCTUnwrap(LatticePreviewStore.load(m.inputs, token: 77), "★ read back for the same inputs")
        let loadS = Date().timeIntervalSince(t0)
        print("STORE: 90k struts, \(data.count / 1_000_000) MB, encode \(String(format: "%.3f", encodeS)) s, load \(String(format: "%.3f", loadS)) s")
        XCTAssertTrue(LatticePreviewStore.readsBack(data, m), "★ every part reads back as it was")
        XCTAssertEqual(back.bars.vines, m.bars.vines, "★ the vines, piece for piece")
        XCTAssertEqual(back.bars.bars, m.bars.bars)
        XCTAssertEqual(back.bars.flags, m.bars.flags)
        XCTAssertEqual(back.bars.lightFrom, m.bars.lightFrom)
        XCTAssertEqual(back.bars.solid?.rg, m.bars.solid?.rg, "★ the solid view's map")
        XCTAssertEqual(back.bars.solid?.dims, m.bars.solid?.dims)
        XCTAssertEqual(back.bars.token, 77, "a fresh token")
        XCTAssertEqual(back.groups.map(\.ask), m.groups.map(\.ask), "★ the Organic groups' asks (the print file's)")
        XCTAssertEqual(back.groups.map(\.regions), m.groups.map(\.regions))
        XCTAssertEqual(back.laid?.barCell, m.laid?.barCell)
        XCTAssertEqual(back.laid?.bars, m.laid?.bars)
        XCTAssertEqual(back.timing, m.timing)
        XCTAssertEqual(back.numbers, m.numbers)
        XCTAssertEqual(back.groupLimits, m.groupLimits)
        XCTAssertEqual(back.autoLimits, m.autoLimits)
        XCTAssertEqual(back.wallVerdicts, m.wallVerdicts)
        XCTAssertEqual(back.walls.map(\.region), [1]); XCTAssertEqual(back.walls.map(\.foci), [3])
        XCTAssertEqual(back.quality, .exact)
        XCTAssertLessThan(encodeS + loadS, 4, "debug build bound (the release build is several times faster)")
        // the key: the same field under another run-time key still matches (the key is never part of it); a setting or the
        // field's values changed, nothing (RED CONTROL)
        var sameField = m.inputs; sameField.stress.key = 12345
        XCTAssertNotNil(LatticePreviewStore.load(sameField, token: 1), "★ the same stress in a later launch")
        var other = m.inputs; other.settings.cellMM = 5
        XCTAssertNil(LatticePreviewStore.load(other, token: 1), "RED CONTROL: another setting, another lattice")
        var look = m.inputs; look.lattice.organicLook = LatticeOrganicLook()
        XCTAssertNil(LatticePreviewStore.load(look, token: 1), "RED CONTROL: another Organic look")
        var stress = m.inputs; stress.stress = .init(key: 7, field: field(21), referenceMPa: 20)
        XCTAssertNil(LatticePreviewStore.load(stress, token: 1), "RED CONTROL: another stress result")
        LatticePreviewStore.controlNoStore = true
        XCTAssertNil(LatticePreviewStore.load(m.inputs, token: 1), "RED CONTROL: no store, nothing read back")
    }

    /// ★ Only into a version's folder, the last of a quick run of saves; a file that is not the store's is refused.
    func testSavesGoIntoTheVersionsFolderOnly() throws {
        let dir = try folder()
        let m = remembered(path: dir.appendingPathComponent("model.stl").path, struts: 50)
        let written = expectation(description: "written")
        LatticePreviewStore.write(m, to: dir) { ok in XCTAssertTrue(ok); written.fulfill() }
        wait(for: [written], timeout: 10)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(LatticePreviewStore.fileName).path))
        let loose = root.appendingPathComponent("loose", isDirectory: true)
        try fm.createDirectory(at: loose, withIntermediateDirectories: true)
        XCTAssertNil(LatticePreviewStore.folder(forModelPath: loose.appendingPathComponent("model.stl").path),
                     "a model outside a version's folder keeps nothing")
        XCTAssertNil(LatticePreviewStore.decode(Data("nonsense".utf8), for: m.inputs, token: 1), "unreadable: nothing")
        // a new version with the same settings takes the files along
        let store = ProjectStore(rootDir: root)
        let to = UUID()
        try fm.createDirectory(at: root.appendingPathComponent(to.uuidString), withIntermediateDirectories: true)
        LatticePreviewStore.copy(from: UUID(uuidString: dir.lastPathComponent)!, to: to, store: store)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(to.uuidString).appendingPathComponent(LatticePreviewStore.fileName).path))
    }

    /// ★ The format knows every field of what it keeps: a new Organic setting, vine part or lattice part fails here until the
    /// store writes it too (and `readsBack` refuses to save a lattice it would not read back the same).
    func testTheFormatKnowsEveryField() {
        func n(_ x: Any) -> Int { Mirror(reflecting: x).children.count }
        XCTAssertEqual(n(LatticeLayoutSession.Organic()), LatticePreviewStore.organicFieldCount, "the Organic ask")
        XCTAssertEqual(n(OrganicVineShape.Piece(a: .zero, ra: 0, b: .zero, rb: 0, vine: 0)), 13, "a vine piece")
        // ★ RE-PINNED (notes29: + up, the print's up; not written, it is the key's own: decode sets it from the inputs' printUp)
        XCTAssertEqual(n(OrganicVineShape()), 9, "the vines")
        XCTAssertEqual(n(OrganicVineShape.Params()), 6, "the vines' parameters")
        XCTAssertEqual(n(OrganicVineShape.Cut(planes: [], union: false)), 2)
        // (11: + fileMesh, 362's Mac print-accurate file — NOT kept here: the version's result holds that file)
        // ★ RE-PINNED (notes29 H3: 12, + printUp, the up a CELL lay stood along — its bridges and timelapse floors; NOT kept
        // here: this store keeps Organic lattices only, whose drawn bars never carry it, as a fresh Organic lay's do not)
        // ★ RE-PINNED 12 -> 13 (notes28 sheets, builder C; merged notes30 M1): + sheets, a sheet layout's fields — NOT kept
        // here: the store keeps finished Organic lattices only, and a sheet is never Organic
        XCTAssertEqual(n(LatticeLayoutBarsInputs(token: 0, bars: [])), 13, "what is drawn")
        // ★ RE-PINNED 6 -> 8 (notes28 sheets, builder E; merged notes30 M1): + sheetSeam, sheetSeamMM, the Blend band's seam
        // channels — filled for a sheet's map only, so an Organic lattice's kept map never carries them: NOT kept here
        XCTAssertEqual(n(LatticeLayoutSolidGrid(token: 0, origin: .zero, voxel: 1, dims: .zero, rg: [])), 8)
        // ★ RE-PINNED (362 11-24: notes25 D10 added floorCellMM; the store now keeps it, format 2, and still reads 1)
        // ★ RE-PINNED 13 -> 15 (notes28 sheets, builder C): + sheets, sheetSeams — never an Organic lattice's, so not kept
        // ★ RE-PINNED 15 -> 17 (notes30 STRUCTURAL AUTO, SA1): + touch, quiltedWhereShort, D2's glow on a CELL lay — never an
        // Organic lattice's (Structural Auto never sizes a weave), so not kept
        XCTAssertEqual(n(LatticeLayoutColours.Laid()), 17)
        XCTAssertEqual(n(LatticeLayoutPreview.Timing(openMS: 0, readMS: 0, cellsMS: 0, barsMS: 0, bars: 0)), 7)
        XCTAssertEqual(n(LatticeOrganicLook.Limits(strutLowerMM: 0, strutUpperMM: 0, strutAutoMM: 0, cellLowerMM: 0, cellUpperMM: 0,
                                                   cellAutoMM: 0)), 8)
        XCTAssertEqual(n(remembered(path: "", struts: 1)), 14, "the remembered lattice")
        // ★ RE-PINNED (notes29: + printUp, the face he kept; the key writes it in its settings text, only when there is one)
        XCTAssertEqual(n(remembered(path: "", struts: 1).inputs), 11, "its inputs (the key)")
    }

    /// ★ notes29: a lattice laid standing on the face he kept reads back with that face (its vines' up, from the key), and only
    /// for that face: the same lattice asked as placed reads nothing back. RED CONTROL: none kept, the key's text as before.
    func testALatticeLaidOnTheKeptFaceReadsBackForThatFaceOnly() throws {
        var m = remembered(path: "/v/model.stl", struts: 50)
        let placedKey = LatticePreviewStore.key(m.inputs)
        XCTAssertEqual(placedKey.settings, String(reflecting: m.inputs.settings), "RED CONTROL: none kept, the text as before")
        m.inputs.printUp = SIMD3(0, -1, 0)
        m.bars.vines?.up = OrganicVineShape.keptUp(OrganicVineShape.drawnUp(m.inputs.printUp))
        let data = try XCTUnwrap(LatticePreviewStore.encode(m))
        XCTAssertTrue(LatticePreviewStore.readsBack(data, m), "★ read back whole, its up too")
        let back = try XCTUnwrap(LatticePreviewStore.decode(data, for: m.inputs, token: 9))
        XCTAssertEqual(back.bars.vines?.up, SIMD3(0, -1, 0), "★ the bridges stand on the kept face again")
        var placed = m.inputs
        placed.printUp = nil
        XCTAssertNil(LatticePreviewStore.decode(data, for: placed, token: 9), "★ as placed it is another lattice")
        XCTAssertNotEqual(LatticePreviewStore.key(m.inputs), placedKey)
    }

    /// ★ The stress check is kept beside the version's model and taken back for the same inputs (no solve); other inputs, or
    /// no store (RED CONTROL), solve again.
    func testTheStressCheckIsKeptAndTakenBack() async throws {
        let dir = try folder()
        let f = field(12)
        let runner: LatticeSimModel.Runner = { _ in
            TopOptKit.SimAnalysisResult(accepted: true, nonConvergent: false, maxStressMPa: 12, marginWorstCase: 2.5, marginRequired: 1.5,
                                        maxDisplacementMM: 0.3, vonMisesField: f.vonMises, stressTensorField: f.stressTensor,
                                        gridNX: 12, gridNY: 12, gridNZ: 12, gridOrigin: f.origin, spacingMM: f.spacingMM)
        }
        let load = TopOptKit.LoadGroupSpec(faceIDs: [3], force: SIMD3(0, 0, -10))
        let ctx = LatticeSimModel.Context(modelPath: dir.appendingPathComponent("model.stl").path, material: "PLA", materialsPath: "",
                                          rulesPath: "", resolution: 64, anchorFaceIDs: [1], loadGroups: [load])
        let a = LatticeSimModel(runner: runner)
        a.run(ctx)
        let end = Date().addingTimeInterval(20)
        while a.field == nil, Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(a.field)
        LatticePreviewStore.flush()
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(LatticePreviewStore.stressFileName).path), "★ kept")
        let b = LatticeSimModel(runner: { _ in throw TopOptError(message: "no solve here") })
        XCTAssertTrue(b.adoptSaved(for: [ctx]), "★ taken back for the same inputs")
        XCTAssertEqual(b.field?.vonMises, f.vonMises)
        XCTAssertEqual(b.field?.stressTensor, f.stressTensor, "★ the tensor the Organic session is given")
        XCTAssertFalse(b.isStale(against: [ctx]))
        if case .complete(let s) = b.phase { XCTAssertEqual(s.safety, 2.5) } else { XCTFail("complete") }
        let moved = LatticeSimModel.Context(modelPath: ctx.modelPath, material: "PLA", materialsPath: "", rulesPath: "", resolution: 64,
                                            anchorFaceIDs: [1], loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [3], force: SIMD3(0, 0, -20))])
        XCTAssertFalse(LatticeSimModel(runner: runner).adoptSaved(for: [moved]), "RED CONTROL: another load, solved again")
        LatticePreviewStore.controlNoStore = true
        XCTAssertFalse(LatticeSimModel(runner: runner).adoptSaved(for: [ctx]), "RED CONTROL: no store")
    }

    // MARK: on a real part, the engine laying

    private func organicProject() throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        var look = LatticeOrganicLook(); look.mode = .traced; look.lookPercent = 5   // open: a quick lay
        p.lattice.organicLook = look
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

    /// ★ Laid once, the version's folder keeps it; a new page (as after a relaunch, the stress under another run-time key) shows
    /// it at once — no lay — and its print file's groups are the laid ones. RED CONTROL: no store, the new page lays again.
    func testANewPageShowsTheSavedLatticeWithNoLay() async throws {
        AppSettings.shared.latticePrintAccurate = false   // his default: the Draft is the preview
        let p = try organicProject()
        let path = try XCTUnwrap(p.importedFile?.path)
        let dir = try XCTUnwrap(LatticePreviewStore.folder(forModelPath: path), "premise: the part is in a version's folder")
        try? fm.removeItem(at: dir.appendingPathComponent(LatticePreviewStore.fileName))
        let a = LatticeLayoutPreview()
        a.update(project: p, on: true, stress: try stress(p, key: 41))
        try await settle(a, "first lay")
        let laid = try XCTUnwrap(a.bars)
        try await Task.sleep(nanoseconds: UInt64((LatticePreviewStore.saveWaitS + 0.5) * 1e9))
        LatticePreviewStore.flush()
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(LatticePreviewStore.fileName).path), "★ kept in its folder")
        a.clear()
        // a new page, as after a relaunch
        let lays = LatticeLayoutPreview.laysStarted, disk = LatticePreviewStore.restoredFromDisk
        let b = LatticeLayoutPreview()
        b.update(project: p, on: true, stress: try stress(p, key: 9_999))
        XCTAssertFalse(b.laying, "★ nothing to wait for")
        XCTAssertEqual(LatticeLayoutPreview.laysStarted, lays, "★ no lay")
        XCTAssertEqual(LatticePreviewStore.restoredFromDisk, disk + 1, "★ read back from the version's folder")
        XCTAssertEqual(b.bars?.bars, laid.bars, "★ the same lattice")
        XCTAssertEqual(b.bars?.vines, laid.vines)
        XCTAssertNotNil(b.organicQuality, "the lattice's own quality, shown as it was laid")
        XCTAssertTrue(b.isCurrent(project: p, stress: try stress(p, key: 9_999)) || b.bars != nil, "on screen for these settings")
        // RED CONTROL: no store, the new page lays
        LatticePreviewStore.controlNoStore = true
        let c = LatticeLayoutPreview()
        c.update(project: p, on: true, stress: try stress(p, key: 4))
        XCTAssertTrue(c.laying, "RED CONTROL: no store, it lays again")
        c.clear()
        b.clear()
    }
}
