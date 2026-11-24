// Notes28OrientTests — ★ notes28 (his iPad notes on release 18, 2026-11-24, the print-orientation flow on Results):
//
//   1. Check strength failed at once (img 82: "The strength couldn't be checked · notLaid"): the check stands the result's own
//      lattice — (a) the inputs that made its file, kept with it; (b) none kept: its exact lattice laid on this iPad first, on
//      Results too, as long as it takes; every stop in plain words, never a Swift name.
//   3. "The face selection looks awful" (img 80 → img 81, Bambu Studio): each hull face a flat patch inset from its edges, each
//      edge rest its own narrow bevel face; the one under his finger brighter; the picked one outlined.
//   4. "It still says 'no supports' even though there should be some manual ones" (img 85): every line says what the file
//      carries.
// (2, Cancel left of Manual orientation, is pinned on the real screen: PrintOrientationFlowHostedTests and the hosted class
// below.)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes28OrientTests: XCTestCase {

    // MARK: 1 (b) — Check strength on Results with nothing laid lays it there first, never "notLaid"

    /// The iPad's preview as Results has it: nothing laid (its refresh lays nothing there) until the check asks it to lay.
    @MainActor final class FakePreview {
        var laid = false, laying = false, lays = 0, stressAsked = 0, stopped = 0
        var layFor: UInt64 = 40_000_000
        var problem: String?
        var neverLays = false
        let groups = [LatticeLayoutSession.OrganicGroup(regions: [3, 4], ask: .init(), name: "Back wall")]
        var preview: PrintCheckLay.Preview {
            PrintCheckLay.Preview(
                inputs: {
                    if self.laying { throw LatticeLayoutPreview.OrganicFileWait.laying }
                    guard self.laid else { throw LatticeLayoutPreview.OrganicFileWait.notLaid }
                    return (self.groups, Data("TOTENSOR".utf8))
                },
                stressReady: { self.stressAsked += 1 },
                lay: {
                    self.lays += 1
                    self.laying = true
                    let wait = self.layFor
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: wait)
                        self.laying = false
                        if !self.neverLays { self.laid = true }
                    }
                },
                busy: { self.laying }, problem: { self.problem }, stop: { self.stopped += 1; self.laying = false })
        }
    }
    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.lock(); on = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    override func setUp() {
        super.setUp()
        PrintCheckLay.pollNanoseconds = 5_000_000
        PrintCheckLay.controlNoLayOnResults = false
    }
    override func tearDown() {
        PrintCheckLay.pollNanoseconds = 300_000_000
        PrintCheckLay.controlNoLayOnResults = false
        super.tearDown()
    }

    func testCheckStrengthOnResultsWithNoLaidPreviewLaysItFirstAndNeverThrowsNotLaid() async throws {
        let f = FakePreview()
        let said = Said()
        let r = try await PrintCheckLay.organic(f.preview, isCancelled: { false }, said: { said.add($0) })
        XCTAssertEqual(r.groups.map(\.regions), [[3, 4]], "★ the lattice laid for this result's settings is what is sent")
        XCTAssertEqual(r.tensor, Data("TOTENSOR".utf8), "with the stress it followed")
        XCTAssertEqual(f.lays, 1, "★ laid on this iPad first — on Results too")
        XCTAssertGreaterThanOrEqual(f.stressAsked, 1, "the stress it follows is there first")
        XCTAssertEqual(said.all.first, "Laying the lattice on this iPad", "★ the checking pop-up says so, in plain words")
        XCTAssertEqual(f.stopped, 1, "its inputs taken, the lay laid for the check lets go (Results draws none)")

        // a slow lay is waited for as long as it takes (here ~60 polls), never failed at once
        let slow = FakePreview()
        slow.layFor = 300_000_000
        let s = try await PrintCheckLay.organic(slow.preview, isCancelled: { false }, said: { _ in })
        XCTAssertEqual(s.groups.count, 1)
        XCTAssertEqual(slow.lays, 1)

        // RED CONTROL: as before notes28 — nothing laid on Results, nothing asked to lay: notLaid at once
        PrintCheckLay.controlNoLayOnResults = true
        let old = FakePreview()
        do {
            _ = try await PrintCheckLay.organic(old.preview, isCancelled: { false }, said: { _ in })
            XCTFail("RED CONTROL: the old path must fail")
        } catch let w as LatticeLayoutPreview.OrganicFileWait {
            XCTAssertEqual(w, .notLaid, "RED CONTROL: his img 82 — notLaid at once")
            XCTAssertEqual(old.lays, 0)
        }
    }

    func testCancelStopsTheLayAndALayThatCannotBeMadeSaysWhyInPlainWords() async throws {
        // Cancel while it lays: the lay is stopped, nothing sent
        let f = FakePreview()
        f.layFor = 5_000_000_000
        let cancelled = Flag()
        let t = Task { @MainActor in try await PrintCheckLay.organic(f.preview, isCancelled: { cancelled.value }, said: { _ in }) }
        for _ in 0..<200 where f.lays == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        cancelled.set()
        do { _ = try await t.value; XCTFail("cancelled") } catch {
            XCTAssertTrue(error is CancellationError, "★ Cancel stops it")
        }
        XCTAssertEqual(f.stopped, 1, "★ the iPad's lay stopped with it")
        // the preview's own reason, when it could not lay
        let g = FakePreview()
        g.neverLays = true
        g.problem = "No lattice fits these settings: try larger cells or thinner struts"
        do { _ = try await PrintCheckLay.organic(g.preview, isCancelled: { false }, said: { _ in }); XCTFail() } catch {
            XCTAssertEqual(PrintOrientationWords.plain(error), g.problem, "its own plain line")
        }
        // laid nothing and said nothing: a few tries, then plain words — never a loop, never "notLaid"
        let h = FakePreview()
        h.neverLays = true
        do { _ = try await PrintCheckLay.organic(h.preview, isCancelled: { false }, said: { _ in }); XCTFail() } catch {
            XCTAssertEqual(h.lays, PrintCheckLay.laysWithNothing)
            XCTAssertEqual(PrintOrientationWords.plain(error), PrintOrientationWords.couldNotLayText)
        }
    }

    func testEveryStopIsSaidInPlainWordsNeverASwiftName() async throws {
        enum Weird: Error { case somethingOdd }
        let errors: [Error] = [LatticeLayoutPreview.OrganicFileWait.laying, LatticeLayoutPreview.OrganicFileWait.notLaid,
                               LatticeLayoutPreview.OrganicFileWait.outOfDate, CancellationError(), URLError(.timedOut),
                               NSError(domain: NSCocoaErrorDomain, code: 4), Weird.somethingOdd,
                               LatticeFileJob.NoJob(line: LatticeFileExport.noStressLine)]
        for e in errors {
            let w = PrintOrientationWords.plain(e)
            XCTAssertFalse(w.isEmpty)
            XCTAssertNil(w.replacingOccurrences(of: "iPad", with: "ipad").range(of: "[a-z][A-Z]", options: .regularExpression),
                         "★ no Swift name (camelCase) in \(w)")
            for bad in ["notLaid", "outOfDate", "Error", "Domain", "somethingOdd", "(", "_"] {
                XCTAssertFalse(w.contains(bad), "★ plain words only: \(w)")
            }
        }
        // the flow's pop-up (his img 82): the check threw notLaid → the centred pop-up in plain words
        let flow = PrintOrientationFlow()
        flow.start(kind: .organic, ranking: try XCTUnwrap(PrintOrientationRanking.decode(PrintOrientationJobsTests.ranking(change: true))),
                   mesh: nil)
        flow.okay()
        let host = PrintOrientationHost(kind: .organic, macReady: { true },
                                        check: { _, _, _, _ in throw LatticeLayoutPreview.OrganicFileWait.notLaid },
                                        keep: { _, _ in })
        AppPopups.shared.current = nil
        flow.check(host: host, variant: PrintCheckVariant(index: 0, stl: nil))
        for _ in 0..<200 where flow.phase != .proposed { try await Task.sleep(nanoseconds: 5_000_000) }
        let p = try XCTUnwrap(AppPopups.shared.current, "★ a centred pop-up")
        XCTAssertEqual(p.title, "The strength couldn’t be checked")
        XCTAssertFalse(p.text.contains("notLaid"), "★ never the Swift case's name (his img 82)")
        XCTAssertTrue(p.text.hasPrefix(PrintOrientationWords.couldNotLayText))
        AppPopups.shared.current = nil
    }

    // MARK: 1 (a) — the inputs that made a print file, kept with its result; the re-check sends them

    private func chainFixture() throws -> (files: URL, model: URL, root: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes28-\(UUID().uuidString)")
        let files = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: files.appendingPathComponent("r2"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        func put(_ name: String, _ d: Data) throws { try d.write(to: files.appendingPathComponent(name)) }
        let summary: [String: Any] = ["ok": true, "code": "done", "why": "", "passing": true,
                                      "strengthened": "r2/strengthened.json", "rounds_fixed": 1,
                                      "rounds": [["round": 0], ["round": 1]]]
        try put("strengthen.json", try JSONSerialization.data(withJSONObject: summary))
        try put("r2/strengthened.json", Data(#"{"version": 2, "additions": "additions.bin"}"#.utf8))
        try put("r2/additions.bin", Data([7, 7, 7, 7]))
        let tet = LatticeOrganicFileTests.model([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                                                [(0, 1, 2), (0, 1, 3), (0, 2, 3), (1, 2, 3)])
        try put("lattice.3mf", LatticeOrganicFileTests.zip([("3D/3dmodel.model", tet, true)]))
        let report = #"{"ok": true, "file": "lattice.3mf", "slicer_supports": "off", "layout": {"bars": 10}, "#
            + #""mesh": {"mm3": 100, "part_mm3": 1000}, "print_check": {"clean": true}, "strength": {"accepted": true, "#
            + #""verdict": "pass", "struts_pass": true, "margin_worst_case": 1.7, "safety_margin": 1.5, "mass_grams": 12, "#
            + #""struts": {"smallest_margin": 1.62}}}"#
        try put(LatticeFileJob.reportName, Data(report.utf8))
        let model = dir.appendingPathComponent("p.step")
        try Data("ISO-10303-21;".utf8).write(to: model)
        return (files, model, dir.appendingPathComponent("store", isDirectory: true))
    }

    static let madeJob = Data(#"{"layout": {"organic_groups": [{"name": "Back wall", "organic_mode": "traced", "regions": [3]}, "#
        .utf8) + Data(#"{"organic_mode": "grown", "regions": [4]}]}, "mode": "lattice_file", "model": "p.step", "#.utf8)
        + Data(#""strength_job": "strength_job.json", "tensor": "tensor.bin"}"#.utf8)

    func testThePrintFilesOrganicInputsAreKeptWithItsResultAndTheReCheckSendsThem() throws {
        let f = try chainFixture()
        let w = try StubWorker(filesDir: f.files, events: [], fingerprint: CoreFingerprint.value)
        defer { w.stop() }
        let config = RemoteRunnerConfig(host: "127.0.0.1", port: Int(w.port), expectedFingerprint: CoreFingerprint.value)
        let tensor = Data("TOTENSOR-his-stress".utf8), strength = Data(#"{"mode": "lattice_part"}"#.utf8)
        let job = LatticeFileJob.ForPart(json: Self.madeJob, modelPath: f.model.path, demand: nil, tensor: tensor)
        let req = RunRequest(modelPath: f.model.path, material: "PLA", materialsPath: "", rulesPath: "", resolution: 64,
                             projectName: "stand")
        let o = try LatticeFileButton.organicRunner(config: config, job: job, projectName: "stand", strengthJob: strength,
                                                    densityGCm3: 1.24)(req, { _, _, _ in true }, { _ in })
        // ★ (a): the run that made the file remembers what made it, by the result's own report
        let kept = try XCTUnwrap(OrganicResultInputs.remembered(report: o.reportJSON), "★ the inputs that made it, with its result")
        XCTAssertEqual(kept.json, Self.madeJob, "its groups and settings, byte for byte")
        XCTAssertEqual(kept.tensor, tensor, "the stress it followed")
        XCTAssertEqual(kept.strengthJob, strength)
        // … written beside the result in its version's folder as the result is saved (AppModel.writeResults)
        let store = ProjectStore(rootDir: f.root)
        let id = UUID()
        let folder = f.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))
        let app = AppModel(materialsPath: nil, store: store)
        app.writeResults(o, id: id)
        AppModel.resultsQueue.sync {}
        let dir = store.organicInputsDir(id: id)
        XCTAssertEqual(OrganicResultInputs.read(from: dir, report: o.reportJSON), kept, "★ kept in the version, read back")
        XCTAssertNil(OrganicResultInputs.read(from: dir, report: Data(#"{"another": "result"}"#.utf8)),
                     "RED CONTROL: another result never takes them")
        // … and the re-check sends them, standing the new way
        let s = try XCTUnwrap(OrganicResultInputs.standing(kept, up: SIMD3(0, 1, 0), modelPath: "/version/2/p.step"))
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: s.json) as? [String: Any])
        let made = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.madeJob) as? [String: Any])
        XCTAssertEqual((sent["print_frame"] as? [String: Any])?["up"] as? [Double], [0, 1, 0], "★ standing the way he picked")
        XCTAssertEqual(NSDictionary(dictionary: sent["layout"] as? [String: Any] ?? [:]),
                       NSDictionary(dictionary: made["layout"] as? [String: Any] ?? [:]), "★ the SAME groups and settings")
        XCTAssertEqual(s.tensor, tensor, "★ the same stress")
        XCTAssertEqual(sent["model"] as? String, "p.step")
        XCTAssertEqual(s.modelPath, "/version/2/p.step", "the version's own copy of the part")
        XCTAssertEqual(sent["strength_job"] as? String, LatticeFileJob.strengthJobName)
    }

    // MARK: 3 — Bambu Studio's patches (his img 81)

    func testEachFaceIsAnInsetPatchAndEachEdgeItsOwnBevelFace() throws {
        let b = PrintOrientationHullTests.box(120, 60, 70)
        let h = try XCTUnwrap(PrintHull.of(vertices: b.vertices, indices: b.indices))
        let p = PrintPatches.of(h)
        XCTAssertEqual(p.faces.count, 6, "every face a patch")
        XCTAssertEqual(p.edges.count, 12, "★ every edge rest its own small face (his: \"The corners should have their own 'face'\")")
        XCTAssertGreaterThan(p.bevelMM, 0)
        for patch in p.faces {
            guard case .face(let i) = patch.target else { return XCTFail() }
            let face = h.faces[i]
            let (u, v) = PrintHull.basis(face.normal)
            let outer = face.outline.map { SIMD2(simd_dot($0, u), simd_dot($0, v)) }
            for q in patch.outline {
                XCTAssertEqual(simd_dot(q - face.outline[0], face.normal), 0, accuracy: 1e-9, "flat on its face")
                XCTAssertTrue(PrintHull.inside(SIMD2(simd_dot(q, u), simd_dot(q, v)), outer), "★ inside its face")
                // inset from every side of the face by at least the facet's reach (the facets beside it never overlap it)
                for k in face.outline.indices {
                    let a = face.outline[k], c = face.outline[(k + 1) % face.outline.count]
                    let d = simd_length(simd_cross(c - a, q - a)) / simd_distance(a, c)
                    XCTAssertGreaterThanOrEqual(d, p.bevelMM - 1e-6, "★ inset from its edges")
                }
            }
        }
        for patch in p.edges {
            guard case .edge(let i) = patch.target else { return XCTFail() }
            let e = h.edges[i]
            XCTAssertEqual(patch.outline.count, 4, "a narrow quad along the edge")
            XCTAssertEqual(simd_dot(patch.normal, -e.up), 1, accuracy: 1e-9, "★ it faces the way the part would rest on it")
            let n = simd_normalize(simd_cross(patch.outline[1] - patch.outline[0], patch.outline[2] - patch.outline[0]))
            XCTAssertGreaterThan(simd_dot(n, patch.normal), 0.9999, "flat, counter-clockwise seen from outside")
            let along = simd_distance(patch.outline[0], patch.outline[1])
            let across = simd_distance(patch.outline[1], patch.outline[2])
            XCTAssertLessThan(across, along / 3, "★ narrow: a bevel, not a face")
            for q in patch.outline {   // on the hull's corner region: inside both faces' half-spaces
                XCTAssertLessThanOrEqual(simd_dot(q - e.a, e.n1), 1e-9)
                XCTAssertLessThanOrEqual(simd_dot(q - e.a, e.n2), 1e-9)
            }
        }
        // the picked one is found by the way shown
        let bottom = try XCTUnwrap(h.faces.firstIndex { $0.normal.z < -0.999 })
        XCTAssertEqual(p.picked(PrintPick(up: h.faces[bottom].up, onEdge: false, recommended: false), hull: h), .face(bottom))
        XCTAssertEqual(p.picked(PrintPick(up: h.edges[3].up, onEdge: true, recommended: false), hull: h), .edge(3))
        XCTAssertNil(p.picked(nil, hull: h))
    }

    func testTheOneUnderHisFingerIsBrighterAndThePickedOneOutlined() async throws {
        let f = PrintOrientationFlow()
        let s = PrintOrientationDrawnTests.standMesh()
        f.start(kind: .topology, ranking: nil, mesh: s)
        for _ in 0..<400 where f.patches == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        let pt = try XCTUnwrap(f.patches, "the patches made with the hull")
        let h = try XCTUnwrap(f.hull)
        XCTAssertEqual(pt.faces.count, h.faces.count)
        f.press(.face(1))
        XCTAssertEqual(f.under, .face(1), "★ under his finger")
        XCTAssertGreaterThan(PrintOrientationLayer.fill(lit: true, picked: false), PrintOrientationLayer.fill(lit: false, picked: false),
                             "★ brighter")
        f.press(nil)
        XCTAssertNil(f.under)
        f.hover(.edge(0), true); XCTAssertEqual(f.under, .edge(0), "the pointer too")
        f.hover(.edge(0), false); XCTAssertNil(f.under)
        let base = try XCTUnwrap(h.faces.firstIndex { $0.normal.z < -0.999 })
        f.pick(face: h.faces[base])
        XCTAssertEqual(pt.picked(f.shown, hull: h), .face(base), "★ the picked one (outlined)")
        XCTAssertEqual(f.phase, .manual, "Manual stays open")
        XCTAssertTrue(f.turning, "its patches wait while the part turns")
        for _ in 0..<400 where f.turning { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(f.turning, "… then come back in the new pose")
        f.cancel()
        XCTAssertNil(f.under)
        XCTAssertFalse(f.turning)
    }

    // MARK: 4 — the supports lines say what the file carries (his img 85)

    /// His v8.1 file as its lattice_file.json came back (the shape; made-up but alike numbers): no painted supports, core's word
    /// "off", 48 posts printed with the lattice.
    static func hisV81Report() -> [String: Any] {
        var r = IPadNotes1121Tests.report()
        r["slicer_supports"] = "off"
        r["mesh"] = ["triangles": 3_599_400, "bridges": 8_346, "posts": 48, "posts_mm": 155.2, "mm3": 120_000.0, "part_mm3": 100_000.0]
        return r
    }

    func outcome(_ report: [String: Any], supportVoxels: Int = 1_900) throws -> OptimizeOutcome {
        let b = PrintOrientationHullTests.box(120, 60, 70)
        let v = OptimizeVariant(requestedVolumeFraction: 0.6, achievedVolumeFraction: 0.6, massGrams: 70, supportVolumeVoxels: supportVoxels,
                                meshTriangleCount: b.indices.count / 3, worstCaseMargin: 1.59, accepted: true, v3Passes: true,
                                orientation: SIMD3(0, 0, 1), maxStressMPa: 10, maxInterlayerTensionMPa: 3, inPlaneMargin: 3,
                                interlayerMargin: 4.5, meshVertices: b.vertices, meshIndices: b.indices, vonMisesField: [],
                                displacementField: [], stressTensorField: [], diagnosis: nil)
        return OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false, acceptedCount: 1, voxelVolumeMM3: 1,
                               computedRemotely: true, reportJSON: try JSONSerialization.data(withJSONObject: report))
    }

    func testEveryLineSaysWhatTheFileCarries() throws {
        // his v8.1: the file carries none (core: "off"); the strength check's grid estimate is not shown as if it were
        let his = try outcome(Self.hisV81Report())
        let m = ResultsModel(projectName: "Stand", outcome: his)
        m.printing = ResultsPrinting(way: .asPlaced, slicerSupports: PrintReportFacts.of(report: his.reportJSON).slicerSupports)
        let rows = m.detailRows(.printing, version: nil)
        XCTAssertEqual(rows.first { $0.label == "Supports" }?.value, "No slicer supports needed")
        XCTAssertNil(rows.first { $0.label == "Support" }, "★ no grid estimate beside the file's own word (his \"Support 1.9 cm³\")")
        XCTAssertEqual(rows.first { $0.label == "Posts" }?.info, PrintOrientationWords.postsInfo,
                       "★ the posts are printed with the lattice, never slicer supports — its (i) says so")
        let row = ResultsChecks.checks(tab: m.selected, margin: 1.59, required: 1.5, safetyMargin: 1.5, scenarios: [], thinJoints: 0,
                                       bridged: false, printFile: m.reportBlocks?.printFile, printing: m.printing)
            .first { $0.tab == .printing && $0.kind == .info }
        XCTAssertEqual(row?.detail, "No slicer supports needed")

        // a file that carries painted supports (core P3): never "No supports needed", on any line
        var painted = Self.hisV81Report()
        painted["slicer_supports"] = "painted"
        painted["painted"] = ["places": 3, "places_painted": 2, "places_unpainted": 1, "triangles": 27, "area_mm2": 34.9,
                              "est_volume_mm3": 2139.8, "support_type": "tree(manual)", "at": [[-0.9, 18.9, 64.5]]] as [String: Any]
        let p = try outcome(painted)
        let pm = ResultsModel(projectName: "Stand", outcome: p)
        pm.printing = ResultsPrinting(way: .asPlaced, slicerSupports: PrintReportFacts.of(report: p.reportJSON).slicerSupports)
        let prow = pm.detailRows(.printing, version: nil)
        XCTAssertEqual(prow.first { $0.label == "Supports" }?.value, "Supports painted on overhangs · 2.1 cm³", "★ his words, ≤ 5")
        XCTAssertEqual(prow.first { $0.label == "Supports" }?.info, PrintOrientationWords.paintedInfo, "how to slice it, in its (i)")
        XCTAssertEqual(prow.first { $0.label == "Orientation" }?.value,
                       "Prints as you placed it · layers across the height · Supports painted on overhangs")
        let checks = ResultsChecks.checks(tab: pm.selected, margin: 1.59, required: 1.5, safetyMargin: 1.5, scenarios: [], thinJoints: 0,
                                          bridged: false, printFile: pm.reportBlocks?.printFile, printing: pm.printing)
        for line in prow.map(\.value) + checks.compactMap(\.detail) {
            XCTAssertFalse(line.lowercased().contains("no supports") || line.lowercased().contains("no slicer supports"),
                           "★ never \"No supports needed\" while the file carries supports: \(line)")
        }
        XCTAssertLessThanOrEqual(PrintOrientationWords.painted.split(separator: " ").count, 5)

        // a cell lattice's file (core writes no slicer_supports for it): its painted block says it — found, none painted
        var cells = Self.hisV81Report()
        cells.removeValue(forKey: "slicer_supports")
        cells["painted"] = ["places": 2, "places_painted": 0, "places_unpainted": 2, "triangles": 0, "area_mm2": 0,
                            "est_volume_mm3": 0, "support_type": "", "at": []] as [String: Any]
        XCTAssertEqual(LatticeFileFacts.decode(cells)?.slicerSupports, "needed")
        XCTAssertEqual(PrintReportFacts.decode(cells).slicerSupports, "needed")
        XCTAssertEqual(PrintOrientationWords.supports("needed"), "Overhangs need slicer supports")
        // RED CONTROL: core's raw key alone (as before) says nothing for it
        XCTAssertNil(cells["slicer_supports"] as? String)
        // a topology result (no file): the grid estimate stays, as before
        let topo = ResultsModel(projectName: "Stand", outcome: try outcome(["ok": true]))
        XCTAssertNotNil(topo.detailRows(.printing, version: nil).first { $0.label == "Support" }, "a topology result keeps its estimate")
    }
}
