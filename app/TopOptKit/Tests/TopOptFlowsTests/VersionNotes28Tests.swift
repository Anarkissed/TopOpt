// VersionNotes28Tests — ★ his iPad notes on release 18 (2026-11-24):
//   img 83: "very little difference between them... a guessing game" — "Is there any way to go back and update all the
//           descriptions...? I really need to know which is which ASAP"; his own words on a version, everywhere;
//   img 84: "it automatically opens on the topology stage";
//   img 85/86: the top row higher on Results; Export an STL while the Checks name a 3MF;
//   img 79: Break "should *end* at the break, showing an actual breakage of the model. It shouldn't return back."
// Model-level tests, each with its RED control where one makes sense; the hosted ones (his two iPad sizes) are in
// VersionNotes28HostedTests.
import XCTest
import SwiftUI
import TopOptKit
import simd
@testable import TopOptFlows

@MainActor
final class VersionNotes28Tests: VersionNotes1123Base {

    override func tearDownWithError() throws {
        AppPopups.shared.current = nil
        VersionDescriptionEditor.shared.close()
        VersionDescriptionEdit.controlNoAsks = false
        try super.tearDownWithError()
    }

    // MARK: fixtures

    private func snap(_ edit: (inout ProjectSnapshot) -> Void = { _ in }) -> ProjectSnapshot {
        var force = ForceModel()
        force.unit = .kg
        var sel = SelectionModel()
        let a = sel.addGroup(); sel.addFaces([131, 133, 132], to: a); force.makeAnchor(a)
        let l = sel.addGroup(); sel.addFaces([18, 34], to: l); force.makeLoad(l); force.setWeight(l, kg: 41)
        var s = ProjectSnapshot(id: UUID(), name: "2040 Extrusion Stand", material: "PA12", process: .fdm,
                                modelFileName: "model.step", originalFileName: "stand.step",
                                savedAt: Date(timeIntervalSince1970: 0), selection: sel, force: force, quality: .fast)
        var lat = LatticeSettings(enabled: true)
        lat.stageMode = .structural
        s.lattice = lat
        edit(&s)
        return s
    }

    private func texts(_ c: [VersionChange]) -> [String] { c.map(\.text) }

    // MARK: 1 · what changed, named his way

    /// A lattice-only version names what changed in the lattice. RED CONTROL: release 18 said one line, "Structural lattice
    /// settings", for every such change.
    func testALatticeOnlyVersionNamesWhatChanged() {
        let v8 = snap()
        let v81 = snap { s in
            s.lattice?.cellSizeMode = .fixed; s.lattice?.cellMM = 6
            s.lattice?.boundary = .fullSkin
            s.lattice?.manualStrutThicknessMM = 1.2
        }
        let c = VersionChanges.between(v8, v81)
        XCTAssertFalse(texts(c).contains("Structural lattice settings"), "RED CONTROL: the one blanket line is gone")
        XCTAssertTrue(texts(c).contains("Cell size Auto → 6 mm"), "★ his way: \(texts(c))")
        XCTAssertTrue(texts(c).contains("Finish None → Skin"), "★ \(texts(c))")
        XCTAssertTrue(texts(c).contains("Strut thickness Auto → 1.2 mm"), "★ \(texts(c))")
        XCTAssertEqual(c.map(\.rank), c.map(\.rank).sorted(), "biggest first, by the naming rule")
        // Organic or a cell type, and the type itself
        let octet = LatticeType.displayName(forID: LatticeType.octet.id)
        let organic = texts(VersionChanges.between(v8, snap { $0.lattice?.algorithm = "organic"; $0.lattice?.stageMode = .aesthetic }))
        XCTAssertEqual(Array(organic.prefix(2)), ["Lattice: Aesthetic", "\(octet) → Organic"], "★ \(organic)")
        XCTAssertTrue(texts(VersionChanges.between(v8, snap { $0.lattice?.topologyID = "gyroid" })).contains("Cell type \(octet) → Gyroid"))
        XCTAssertTrue(texts(VersionChanges.between(v8, snap { $0.lattice?.wholePart = true })).contains("Start from Solid → All lattice"))
        XCTAssertTrue(texts(VersionChanges.between(v8, snap { $0.lattice?.paintDepthMM = 6 })).contains("Depth 4 → 6 mm"))
    }

    /// A lattice group is HIS name for it, or how many faces it has — never a face number; each group's own settings say whose.
    func testGroupsAreHisNameOrTheirFaceCountNeverAFaceNumber() {
        let base = snap()
        var list = SelectionModel()
        let rail = list.addGroup(); list.addFaces([131, 133], to: rail); list.rename(rail, to: "Rail")
        let plain = list.addGroup(); list.addFaces([4, 146, 147], to: plain)
        let v2 = snap { s in
            s.lattice?.latticeList = list
            var g = LatticeAreaGrading(); g.skin = "rim"
            s.lattice?.areaGrading = [rail: g]
            s.lattice?.groupDepthMM = [plain: 7]
            s.lattice?.selectableDepthMM = [LatticeSelectableRef.face(group: rail, face: 131).key: 3]
        }
        let lines = texts(VersionChanges.between(base, v2))
        XCTAssertTrue(lines.contains("Lattice group Rail"), "★ his name: \(lines)")
        XCTAssertTrue(lines.contains("Lattice group 3 faces"), "★ or its face count: \(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Rail: Finish ") }, "★ a group's own Finish, by its name: \(lines)")
        XCTAssertTrue(lines.contains("3 faces: Depth Auto → 7 mm"), "★ \(lines)")
        XCTAssertTrue(lines.contains("Rail: face depths changed"), "★ a face's own setting is said by its group: \(lines)")
        for l in lines {
            for id in ["131", "133", "146", "147"] { XCTAssertFalse(l.contains(id), "★ never a face number: \(l)") }
        }
    }

    /// The print settings and the print orientation, each by name (release 18: one "Print settings" line, no orientation).
    func testPrintSettingsAndOrientationAreNamed() {
        let a = snap()
        let b = snap { s in
            var p = PrintParams.fdmDefault
            p.layerHeightMM = 0.16; p.wallLineWidthOuterMM = 0.45; p.infillPercent = 25
            s.printParams = p
            s.plateUp = SIMD3(1, 0, 0)
        }
        let lines = texts(VersionChanges.between(a, b))
        XCTAssertFalse(lines.contains("Print settings"), "RED CONTROL: the one blanket line is gone")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Layer height ") && $0.hasSuffix(" → 0.16 mm") }, "★ \(lines)")
        XCTAssertTrue(lines.contains("Outer line width 0.42 → 0.45 mm"), "★ \(lines)")
        XCTAssertTrue(lines.contains("Infill 20 → 25 %"), "★ \(lines)")
        XCTAssertTrue(lines.contains("Print orientation As placed → Chosen face"), "★ never an axis: \(lines)")
    }

    /// "same settings" only when truly nothing differs: a setting no line names still counts; what a bake or a run writes
    /// back (core's verdicts, the size probe's answer) does not.
    func testSameSettingsOnlyWhenTrulyNothingDiffers() {
        let a = snap()
        XCTAssertEqual(VersionChanges.between(a, snap()), [], "the same settings (two copies set up apart, too)")
        XCTAssertEqual(VersionChanges.between(a, a), [], "the same settings")
        var margin = a; margin.force.safetyMargin = 2
        XCTAssertEqual(texts(VersionChanges.between(a, margin)), ["Safety margin 150 → 200 %"])
        var b = a; b.lattice?.organicTieSwirl = 2   // a setting no line names
        // RED CONTROL: the named lines alone say nothing about it (release 18 would have said "same settings")
        XCTAssertEqual(VersionChanges.latticeLines(VersionChanges.latticeSettingsOnly(a.lattice), VersionChanges.latticeSettingsOnly(b.lattice),
                                                   groupsA: [], groupsB: []), [])
        XCTAssertEqual(texts(VersionChanges.between(a, b)), ["Other lattice settings"], "★ never \"same settings\" when one differs")
        var cached = a
        cached.lattice?.selectableWallCoreDead = ["f:x:1": true]
        cached.lattice?.organicFittingSeparationsMM = [3, 4]
        cached.lattice?.thinWallsNoticeSeen = true
        XCTAssertEqual(VersionChanges.between(a, cached), [], "★ what a bake writes back is not a setting")
        var picked = a; picked.selection.clearActive()
        XCTAssertEqual(VersionChanges.between(a, picked), [], "a pick is not a setting")
    }

    /// Every version and draft ON DISK says what changed the moment the update installs — from its settings and its
    /// parent's, never rewriting a file. RED CONTROL: the list library.json kept said nothing (filed before the edits).
    func testEveryVersionOnDiskSaysItFromItsOwnSettings() throws {
        let src = root.appendingPathComponent("import", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("stand.step")
        try Data("solid stand".utf8).write(to: model)
        var v8 = snap(); v8.savedAt = Date(timeIntervalSince1970: 100); v8.optimized = true
        try store.save(v8, modelSource: model)
        try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: AppBuildFixturesLite.outcome())), id: v8.id)
        let lib = LibraryModel(store: store)
        lib.refresh()
        try lib.group(projectName: "Squish Mechanism", partIDs: nil)
        // a draft from v8, filed with the same settings, then edited (his v8.1.1 draft)
        var draft = v8; draft.id = UUID(); draft.optimized = nil; draft.savedAt = Date(timeIntervalSince1970: 200)
        try store.save(draft, modelSource: model)
        lib.noteParent(v8.id, of: draft.id)
        lib.refresh()
        let libraryBefore = try Data(contentsOf: store.libraryURL)
        draft.lattice?.cellSizeMode = .fixed; draft.lattice?.cellMM = 6
        draft.lattice?.boundary = .rim; draft.lattice?.paintDepthMM = 5; draft.lattice?.allowQuilt = true
        try store.save(draft, modelSource: nil)
        lib.refresh()
        let part = try XCTUnwrap(lib.index.part(containing: draft.id))
        let v = try XCTUnwrap(part.version(folderID: draft.id))
        XCTAssertEqual(v.changes, [], "RED CONTROL: the list kept at filing says nothing")
        XCTAssertEqual(lib.changes(of: v, in: part).count, 4, "★ worked out now: \(texts(lib.changes(of: v, in: part)))")
        let line = lib.differencesLine(of: v, in: part)
        XCTAssertEqual(line, "from v1 · Cell size Auto → 6 mm · Finish None → Rim · Depth 4 → 5 mm · +1 more",
                       "★ the biggest three, then +n more")
        XCTAssertFalse(line.contains("same settings"))
        XCTAssertTrue(lib.title(of: v, in: part).contains("Cell size Auto → 6 mm"), "the automatic name too")
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), libraryBefore, "★ no saved file is rewritten for it")
        XCTAssertEqual(LibraryVersionFacts.origin(v, snapshot: draft, draft: true, changes: lib.changes(of: v, in: part)).count, 5,
                       "★ Details lists them all (after where it came from)")
        // the version it came from reads its first run; the same settings say so only when nothing differs
        let v1 = try XCTUnwrap(part.version(folderID: v8.id))
        XCTAssertEqual(lib.differencesLine(of: v1, in: part), "first run · res 64")
    }

    // MARK: 2 · his own words

    /// His words live on the version's entry in library.json, optional: an older library.json reads and saves as it was.
    func testHisDescriptionIsKeptAndAnOldLibraryFileReadsAsBefore() throws {
        let f = UUID()
        let old = #"{"folderID":"\#(f)","number":1,"changes":[],"marks":[]}"#
        let v = try JSONDecoder().decode(LibraryVersion.self, from: Data(old.utf8))
        XCTAssertNil(v.versionDescription, "★ an old entry has none, and decodes")
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(v)) as? [String: Any])
        XCTAssertNil(again["versionDescription"], "★ and saves without the new key")
        let (app, cube) = try optimizedCube()
        let lib = app.library
        let before = try projectJSON(cube.id)
        lib.setDescription("  Thicker rim, Organic off  ", folder: cube.id)
        XCTAssertEqual(lib.description(of: cube.id), "Thicker rim, Organic off")
        XCTAssertEqual(try projectJSON(cube.id), before, "★ never a setting: project.json untouched")
        let fresh = LibraryModel(store: store); fresh.refresh()
        XCTAssertEqual(fresh.description(of: cube.id), "Thicker rim, Organic off", "★ kept across launches")
        XCTAssertFalse(lib.makesNextVersion(of: cube.id) && app.project != nil, "nothing opened, nothing moved")
        lib.setDescription("   ", folder: cube.id)
        XCTAssertNil(lib.description(of: cube.id), "empty clears it")
        XCTAssertEqual(lib.descriptionDraft(of: cube.id), "", "a first version has no differences to start from")
    }

    /// (c) a save asks to edit its description; (d) a new version asks to describe either one. RED CONTROL: no ask.
    func testASaveAndANewVersionAskForHisWords() throws {
        FlexibleSaid.recording = true
        defer { FlexibleSaid.recording = false; VersionDescriptionEditor.recorded = [] }
        let (app, v1) = try optimizedCube()
        try open(app, v1.id)
        waitForResults(try XCTUnwrap(app.project))
        VersionDescriptionEdit.controlNoAsks = true
        app.saveVersion()
        XCTAssertNil(AppPopups.shared.current, "RED CONTROL: release 18 asked nothing")
        VersionDescriptionEdit.controlNoAsks = false
        app.saveVersion()
        XCTAssertEqual(app.toast, VersionChipCopy.saved("v1"), "the save still says so")
        let ask = try XCTUnwrap(AppPopups.shared.current, "★ (c) the save asks")
        XCTAssertEqual(ask.title, VersionDescriptionCopy.savedTitle("v1"))
        XCTAssertEqual(AppPopups.shared.action?.title, VersionDescriptionCopy.edit)
        AppPopups.shared.action?.run()
        XCTAssertEqual(VersionDescriptionEditor.shared.editing?.folder, v1.id, "★ Edit description opens the editor on v1")
        VersionDescriptionEditor.shared.text = "The first stand"
        VersionDescriptionEditor.shared.commit()
        XCTAssertEqual(app.library.description(of: v1.id), "The first stand")
        AppPopups.shared.current = nil
        // (d) Save and start a new version
        let made = try XCTUnwrap(app.saveAndStartNewVersion())
        let ask2 = try XCTUnwrap(AppPopups.shared.current, "★ (d) the new version asks")
        XCTAssertEqual(ask2.title, VersionDescriptionCopy.newTitle("v2"))
        XCTAssertEqual(AppPopups.shared.action?.title, VersionDescriptionCopy.describe("v2"))
        XCTAssertEqual(AppPopups.shared.second?.title, VersionDescriptionCopy.describe("v1"), "★ or the one it came from")
        XCTAssertEqual(AppPopups.shared.third?.title, VersionDescriptionCopy.notNow)
        AppPopups.shared.second?.run()
        XCTAssertEqual(VersionDescriptionEditor.shared.editing?.folder, v1.id)
        XCTAssertEqual(VersionDescriptionEditor.shared.text, "The first stand", "★ his words to start from")
        VersionDescriptionEditor.shared.close()
        AppPopups.shared.action?.run()   // (the pop-up's buttons are its own; the first describes the new one)
        AppPopups.shared.current = nil
        VersionDescriptionEdit.open(library: app.library, folder: made.id)
        XCTAssertEqual(VersionDescriptionEditor.shared.editing?.title, VersionDescriptionCopy.title("v2"))
        for w in [VersionDescriptionCopy.edit, VersionDescriptionCopy.heading, VersionDescriptionCopy.placeholder,
                  VersionDescriptionCopy.notNow, VersionDescriptionCopy.describe("v8.1.1")] {
            XCTAssertLessThanOrEqual(w.split(separator: " ").count, 5, "★ his rule: at most five words: \(w)")
        }
        XCTAssertLessThanOrEqual(VersionChipCopy.descriptionLine("one two three four five six seven").split(separator: " ").count, 5)
    }

    // MARK: 3 · a version opens as he left it

    /// The view state is its own file beside project.json (never in it); a folder without one, or with one that can't be
    /// read, opens as before.
    func testTheViewStateIsItsOwnFileAndOldFoldersOpenAsBefore() throws {
        let (_, cube) = try optimizedCube()
        XCTAssertNil(store.loadViewState(id: cube.id), "★ an older version has none: it opens as today")
        let before = try projectJSON(cube.id)
        let pose = VersionCameraPose(azimuth: 1.1, elevation: 0.4, roll: 0, distance: 220, target: SIMD3(1, 2, 3))
        let v = VersionViewState(stage: "lattice", page: VersionViewState.pageCells, selectionsCollapsed: true, outlines: true,
                                 forces: false, camera: pose)
        store.saveViewState(v, id: cube.id)
        XCTAssertEqual(store.loadViewState(id: cube.id), v, "★ kept with the version")
        XCTAssertEqual(try projectJSON(cube.id), before, "★ project.json untouched: it can never stop the version decoding")
        XCTAssertNotNil(store.snapshot(id: cube.id), "the version still reads")
        try Data("{ not json".utf8).write(to: store.viewStateURL(id: cube.id))
        XCTAssertNil(store.loadViewState(id: cube.id), "a file that can't be read is ignored: it opens as before")
        let gone = UUID()
        store.saveViewState(v, id: gone)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(gone.uuidString).path), "never recreates a folder")
        // a field a newer build adds, or one an older one left out, is ignored / left as the page opens
        let partial = try JSONDecoder().decode(VersionViewState.self, from: Data(#"{"stage":"topology","later":1}"#.utf8))
        XCTAssertEqual(partial.stage, "topology"); XCTAssertNil(partial.camera)
    }

    /// The page restores once per open: the workspace's always-there host reappears when a full-screen page (the Cells page)
    /// closes, and must change nothing then.
    func testThePageRestoresOncePerOpen() throws {
        let (app, cube) = try optimizedCube()
        XCTAssertFalse(VersionViewOpen.shared.takeOpened(cube.id), "nothing opened yet")
        try open(app, cube.id)
        XCTAssertFalse(VersionViewOpen.shared.takeOpened(UUID()), "another version's page never takes it")
        XCTAssertTrue(VersionViewOpen.shared.takeOpened(cube.id), "★ the open restores its page")
        XCTAssertFalse(VersionViewOpen.shared.takeOpened(cube.id), "★ once: a host reappearing later restores nothing")
    }

    /// The camera is put back as he left it — its turn now, and its zoom and pan once the part is framed. RED CONTROL: framing
    /// alone (release 18) re-fits the zoom and the pan.
    func testTheCameraIsPutBackWhenThePartIsFramed() {
        let m = OrbitCameraModel()
        let pose = VersionCameraPose(azimuth: 2.0, elevation: 0.5, roll: 0.1, distance: 42, target: SIMD3(5, 6, 7))
        var framed = OrbitCamera(target: SIMD3(0, 0, 0), distance: 300, azimuth: 0.3, elevation: 0.2, maxDistance: 1000)
        let control = OrbitCameraModel()
        control.adoptFramed(framed)
        XCTAssertEqual(control.camera.distance, 300, "RED CONTROL: the frame's own zoom")
        m.restore(pose)
        XCTAssertEqual(m.camera.azimuth, 2.0, accuracy: 1e-6, "★ turned at once")
        framed.azimuth = m.camera.azimuth   // the viewer mirrors the turn before it frames
        m.adoptFramed(framed)
        XCTAssertEqual(m.camera.distance, 42, accuracy: 1e-4, "★ his zoom, after the frame")
        XCTAssertEqual(m.camera.target, SIMD3(5, 6, 7), "★ his pan")
        XCTAssertEqual(m.camera.elevation, 0.5, accuracy: 1e-6)
        XCTAssertEqual(m.camera.roll, 0.1, accuracy: 1e-6)
        XCTAssertNil(m.pendingPose, "once")
        m.adoptFramed(framed)
        XCTAssertEqual(m.camera.distance, 300, "a later part is framed as before")
        XCTAssertEqual(VersionCameraPose(m.camera).distance, 300, "what is kept is what is shown")
    }

    // MARK: 4b · Break ends at the break

    /// Break climbs to the break, breaks there, stays broken for the hold, and starts again from the start — it never animates
    /// back down. RED CONTROL: Bend's loop eases back (release 18's Break did too).
    func testBreakEndsOnTheBreakHoldsThenResets() throws {
        let tl = LoadMotion.breakTimeline
        XCTAssertEqual(tl.down, 0, "★ no way down")
        XCTAssertGreaterThan(tl.hold, 1.5, "★ a pause on the break")
        let bend = LoadMotion.bendTimeline
        XCTAssertGreaterThan(LoadMotion.share(time: bend.up + bend.hold + bend.down * 0.5, bend), 0.01, "RED CONTROL: Bend eases back")
        for t in stride(from: tl.up + tl.hold * LoadMotion.breakShare + 0.01, to: tl.up + tl.hold - 0.01, by: 0.05) {
            XCTAssertEqual(LoadMotion.share(time: t, tl), 1, "★ at the break all through the hold (\(t))")
            XCTAssertEqual(LoadMotion.giveWay(time: t, tl), 1, accuracy: 1e-9, "★ broken all through the hold (\(t))")
        }
        XCTAssertEqual(LoadMotion.share(time: tl.up + tl.hold + 0.01, tl), 0, "★ then straight back to the start")
        XCTAssertEqual(LoadMotion.giveWay(time: tl.up + tl.hold + 0.01, tl), 0, "★ whole again, never springing back on screen")
        // the break is a crack through the place: the near side pulled away, the far side a little back
        let m = try Notes25Fixture.model()
        m.loadMotion.setPosition((tl.up + tl.hold * 0.9) / tl.cycle, .breakIt)
        let s = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))
        let patch = try XCTUnwrap(s.patch, "★ it breaks where it gives first")
        XCTAssertTrue(s.frame.atTop)
        let way = simd_normalize(s.prep.giveAtPlace)
        var near: Float = 0, far: Float = 0
        for (i, j) in patch.indices.enumerated() {
            let base = SIMD3(s.prep.disp[3 * Int(j)], s.prep.disp[3 * Int(j) + 1], s.prep.disp[3 * Int(j) + 2])
            let now = SIMD3(patch.values[3 * i], patch.values[3 * i + 1], patch.values[3 * i + 2])
            let d = simd_dot(now - base, way)
            near = max(near, d); far = min(far, d)
        }
        XCTAssertGreaterThan(near, 0, "★ the near side pulled away")
        XCTAssertGreaterThanOrEqual(far, -Float(LoadMotion.crackBackShare) * near - 1e-5, "the far side less, and back")
        XCTAssertEqual(LoadMotion.giveShare, 1, "★ the whole movement again (it was half, a fold)")
    }

    // MARK: 4c · Export is a 3MF

    /// Export writes a 3MF by default; a print file's result hands out the print file itself once it is kept with its version.
    /// RED CONTROL: release 18 wrote the STL (and kept no print file).
    func testExportIsA3MFAndAPrintFilesOwnFileIsKept() throws {
        let rm = ResultsModel(projectName: "Stand", outcome: AppBuildFixturesLite.outcome(), materialName: "PA12")
        XCTAssertNil(rm.printFileIdentity, "a Topology result is no print file")
        XCTAssertTrue(rm.exportFilename.hasSuffix(".stl"), "RED CONTROL: the STL's name (the ⌃'s Export as STL)")
        XCTAssertTrue(rm.exportThreeMFFilename.hasSuffix(".3mf"))
        XCTAssertEqual(rm.exportThreeMFFilename.dropLast(4), rm.exportFilename.dropLast(4), "the same name, as a 3MF")
        let data = try XCTUnwrap(rm.exportThreeMFData(), "★ the shape as a 3MF")
        let read = try XCTUnwrap(PartsThreeMF.read(data))
        XCTAssertEqual(read.count, 1); XCTAssertEqual(read.first?.triangleCount, 1)
        XCTAssertLessThanOrEqual(ResultsExportCopy.stlLine.split(separator: " ").count, 5, "★ his rule: five words")
        XCTAssertTrue(ResultsExportCopy.stlInfo.contains("no painted supports"), "★ the (i) says what an STL leaves out")
        // a print file, kept with its version
        let (_, cube) = try optimizedCube()
        let file = Data(repeating: 7, count: 4096)
        let report = try JSONSerialization.data(withJSONObject: [
            "ok": true, "file": "lattice.3mf", "file_bytes": file.count, "layout": ["bars": 10], "mesh": ["triangles": 1],
            "print_check": ["clean": true]])
        let one = AppBuildFixturesLite.outcome(1)
        let outcome = OptimizeOutcome(variants: one.variants, stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
                                      reportJSON: report)
        let id = try XCTUnwrap(PrintFileKeep.identity(of: outcome))
        XCTAssertEqual(id, PrintFileKeep.Identity(name: "lattice.3mf", bytes: 4096))
        // RED CONTROL: a file that is not this result's (another size) is never kept as it
        PrintFileKeep.stash(Data(repeating: 1, count: 10), name: "lattice.3mf", projectID: cube.id)
        PrintFileKeep.keep(projectID: cube.id, outcomes: [outcome], store: store)
        XCTAssertNil(PrintFileKeep.file(id, folder: cube.id, store: store), "RED CONTROL: another file is not this result's")
        PrintFileKeep.stash(file, name: "lattice.3mf", projectID: cube.id)
        PrintFileKeep.keep(projectID: cube.id, outcomes: [AppBuildFixturesLite.outcome(), outcome], store: store)
        let kept = try XCTUnwrap(PrintFileKeep.file(id, folder: cube.id, store: store), "★ kept beside its version")
        XCTAssertEqual(try Data(contentsOf: kept), file, "★ the print file itself, byte for byte")
        XCTAssertNil(PrintFileKeep.file(PrintFileKeep.Identity(name: "lattice.3mf", bytes: 5), folder: cube.id, store: store),
                     "another result's file is not handed out")
        PrintFileKeep.open = { [store] in (cube.id, store!) }
        defer { PrintFileKeep.open = nil }
        XCTAssertTrue(PrintFileKeep.openFile(exists: id))
        let out = try XCTUnwrap(PrintFileKeep.openFile(id, named: "Stand-PA12-37pct"))
        XCTAssertEqual(out.lastPathComponent, "Stand-PA12-37pct.3mf", "named for the result")
        XCTAssertEqual(try Data(contentsOf: out), file)
    }

    // MARK: 4a · the top row on Results

    /// The workspace's safe area is noted (Results puts its top row down by it); the RED control leaves it at the top.
    func testTheSafeAreaTopIsNotedForResultsTopRow() {
        let g = ChromeGeometry()
        g.noteSafeTop(24)
        let exp = expectation(description: "noted"); DispatchQueue.main.async { exp.fulfill() }; wait(for: [exp], timeout: 2)
        XCTAssertEqual(g.safeTop, 24)
        ChromeGeometry.controlNoSafeTop = true
        defer { ChromeGeometry.controlNoSafeTop = false }
        g.noteSafeTop(24)
        let exp2 = expectation(description: "noted"); DispatchQueue.main.async { exp2.fulfill() }; wait(for: [exp2], timeout: 2)
        XCTAssertEqual(g.safeTop, 0, "RED CONTROL: release 18's Results row at the screen's top")
    }
}
