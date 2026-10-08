// FlexibleAngledGoldenRecorder — the ANGLED PRESSES baselines (task 2026-10-07, batch AP0), recorded at
// 01ec5e3c BEFORE any angled-press code exists, so every later batch can prove that existing face presses
// keep their job bytes and core's frames (spec §14, §15).
//
// Run by hand, under deterministic hashing (his projects' jobs carry lattice outlines whose loops come
// out in HASH order otherwise — memory "stage job outline order is hash order"):
//
//     RECORD=1 SWIFT_DETERMINISTIC_HASHING=1 swift test --filter FlexibleAngledGoldenRecorder
//
// It writes to Tests/TopOptFlowsTests/Fixtures/angled_press_goldens/ (FLEX_AP_GOLDEN_DIR reads another
// copy — the perturbed-golden red run):
//   (1) C1's pad: the pure encoder's run job (FlexibleStageTests.settings, with and without a stamp), and
//       the app's own run and scene jobs over the pad (top pressed 30 kg, bottom resting);
//   (2) his round-5 pad AS SAVED: runJobJSON(resting:) of the FIRST FlexibleCoreHold.sends set, and its
//       scene job;
//   (3) the `lattice` subtree of 0004, 0004_r5 and Fixtures/102117B9_project.json, DECODED then
//       re-encoded with ProjectStore's encoder settings (never re-saved: savedAt changes on a save);
//   (4) core's frames and stacks (FlexStackInfo, every double as its bit pattern) of every declared
//       region of C1's pad, his 0004 and 0004_r5, the M2 stand and the 60 mm cube, the face presses
//       marked — so S1 can attribute what #361's principal_2d fix moves;
//   (5) the refusal texts THIS core gives the probe's tilt and edge documents (built by
//       FlexibleJob.document, checked through TopOptKit.jobSchemaError), each form pinned to its OWN
//       text, with the control document (the entry exactly as faceEntry writes it) parsing.
// Every path in a job is replaced by $REPO / $ROOT, so the goldens do not depend on where the repo or
// the temp store lives.
import XCTest
import CryptoKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
enum FlexibleAngledGoldens {

    // MARK: - where

    static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["FLEX_AP_GOLDEN_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/angled_press_goldens", isDirectory: true)
    }

    /// The red runs' door: a control's change fed into the MAIN comparison (FlexibleAngledGoldenTests).
    static var mutation: String? { ProcessInfo.processInfo.environment["FLEX_AP_MUTATE"] }

    static var deterministicHashing: Bool { ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == "1" }
    static var hashingMode: String {
        "SWIFT_DETERMINISTIC_HASHING=\(ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] ?? "unset")"
    }

    static func read(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        guard let d = try? Data(contentsOf: url) else {
            XCTFail("golden \(name) is missing under \(dir.path) — record it with RECORD=1 (FlexibleAngledGoldenRecorder)")
            throw XCTSkip("no golden \(name)")
        }
        return String(decoding: d, as: UTF8.self)
    }

    static func write(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
        print("FLEX-AP RECORDED \(name) (\(text.utf8.count) bytes)")
    }

    /// Exact comparison; on a miss, the first differing lines (for attribution), then the failure.
    static func assertGolden(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let golden = try read(name)
        if text == golden {
            print("FLEX-AP GOLDEN \(name): identical (\(text.utf8.count) bytes)")
            return
        }
        let d = lineDiff(text, golden)
        print("FLEX-AP GOLDEN \(name): DIFFERS — \(d.count) line(s); first: \(d.prefix(6).map { "\n   line \($0.line): now '\($0.now)' was '\($0.was)'" }.joined())")
        XCTFail("\(name): \(d.count) line(s) differ from the golden (first at line \(d.first?.line ?? 0))", file: file, line: line)
    }

    struct LineDiff { let line: Int; let now: String; let was: String }
    static func lineDiff(_ a: String, _ b: String) -> [LineDiff] {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        return (0..<max(x.count, y.count)).compactMap { i in
            let p = i < x.count ? x[i] : "<none>", q = i < y.count ? y[i] : "<none>"
            return p == q ? nil : LineDiff(line: i + 1, now: p, was: q)
        }
    }
    /// How many bytes differ: the span between the longest common prefix and the longest common
    /// suffix (one replaced byte ⇒ 1; a number that grew ⇒ its new digits).
    static func byteDiff(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf8), y = Array(b.utf8)
        var p = 0
        while p < min(x.count, y.count), x[p] == y[p] { p += 1 }
        var q = 0
        while q < min(x.count, y.count) - p, x[x.count - 1 - q] == y[y.count - 1 - q] { q += 1 }
        return max(x.count, y.count) - p - q
    }

    // MARK: - paths out of the bytes

    /// `json` with each root replaced by its token. JSONSerialization writes "/" as "\/", so both
    /// spellings are replaced, the /private twin of a temp path first.
    static func normalised(_ json: String, _ roots: [(path: String, token: String)]) -> String {
        var out = json
        var pairs: [(String, String)] = []
        for r in roots {
            let p = r.path.hasSuffix("/") ? String(r.path.dropLast()) : r.path
            var forms = [p]
            if p.hasPrefix("/private/") { forms.append(String(p.dropFirst("/private".count))) } else { forms.insert("/private" + p, at: 0) }
            for f in forms { pairs.append((f, r.token)) }
        }
        for (path, token) in pairs.sorted(by: { $0.0.count > $1.0.count }) {
            out = out.replacingOccurrences(of: path.replacingOccurrences(of: "/", with: "\\/"), with: token)
            out = out.replacingOccurrences(of: path, with: token)
        }
        return out
    }

    static var repo: (path: String, token: String) { (FlexibleHisProject.repoRoot.path, "$REPO") }

    // MARK: - (1) C1's pad

    /// The pure encoder on FlexibleStageTests' settings (face 1 pressed 30 kg with drawn curves, face 0
    /// resting) — no core call.
    static func padPureRunJob(weightDeltaKg: Double = 0, deepestDeltaMM: Double = 0) throws -> String {
        var s = FlexibleStageTests.settings()
        if weightDeltaKg != 0 || deepestDeltaMM != 0, var f = s.face(FlexibleJob.regionID(face: 1)) {
            f.weightKg += weightDeltaKg
            f.deepestMM += deepestDeltaMM
            s.setFace(f)
        }
        return normalised(try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(s)), [repo])
    }

    /// The same with face 1 shaped as a Stamp (the library's thumb, centred) on a 2 mm pitch.
    static func padPureStampRunJob() throws -> String {
        let lib = try FlexibleStampLibrary.load(path: FlexibleStageTests.stampsPath)
        var s = FlexibleStageTests.settings()
        let thumb = FlexibleStamps.place(try XCTUnwrap(lib.shape("thumb")), uExtentMM: 100, vExtentMM: 100, weightKg: 5)
        var f = try XCTUnwrap(s.face(FlexibleJob.regionID(face: 1)))
        f.designStamp = thumb
        f.shape = "stamp"
        s.setFace(f)
        let g = try XCTUnwrap(FlexibleStamps.grid(thumb, library: lib, uExtentMM: 100, vExtentMM: 100, pitchMM: 2,
                                                  onFace: { _, _ in true }))
        return normalised(try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(s, stamps: [thumb.id: g])), [repo])
    }

    /// The app's model over C1's pad: its top pressed at 30 kg, its bottom resting, designs settled.
    static func padModel(_ test: XCTestCase) async throws -> (FlexibleStageModel, top: Int, bottom: Int) {
        let pm = try FlexiblePressFixtures.padProject()
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(90, "the pad's scene") { m.sceneState == .ready }
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh), bottom = FlexibleSquishFixture.bottomFace(mesh)
        XCTAssertTrue(m.press(top, kg: 30))
        m.rest(bottom)
        try await FlexibleSquishFixture.settle(m, "the pad")
        return (m, top, bottom)
    }

    static func runJob(_ m: FlexibleStageModel, resting: Set<Int> = [], roots: [(path: String, token: String)]) throws -> String {
        normalised(try m.runJobJSON(resting: resting), roots)
    }
    static func sceneJob(_ m: FlexibleStageModel, roots: [(path: String, token: String)]) throws -> String {
        normalised(try XCTUnwrap(try m.sceneJob(), "a scene job").json, roots)
    }

    // MARK: - (2) his round 5, as saved

    /// His r5 restored as saved, its model opened and settled; the FIRST of core hold's sends.
    static func hisRound5Model(_ test: XCTestCase) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel, FlexibleCoreFix) {
        let r = try FlexiblePressFixtures.hisRound5(test)
        let m = try await FlexibleHisProject.openedModel(r.project, test: test)
        try await FlexibleSquishFixture.settle(m, "his r5")
        let hold = try XCTUnwrap(m.coreHold, "premise: his r5 as saved is held (two squeeze groups)")
        let first = try XCTUnwrap(hold.fixes.first, "premise: core hold offers a send")
        return (r, m, first)
    }

    static func rootToken(_ r: FlexibleHisProject.Restored) -> [(path: String, token: String)] {
        [(r.root.path, "$ROOT"), (r.root.resolvingSymlinksInPath().path, "$ROOT"), repo]
    }

    // MARK: - (3) lattice subtrees

    static let subtreeSources: [(name: String, url: URL)] = [
        ("lattice_subtree_0004.json", FlexibleHisProject.dir.appendingPathComponent("project.json")),
        ("lattice_subtree_0004_r5.json", FlexibleHisProject.round5Dir.appendingPathComponent("project.json")),
        ("lattice_subtree_102117B9.json", URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/102117B9_project.json")),
    ]

    /// The snapshot's `lattice`, decoded by the store's own decoder and re-encoded with the store's
    /// encoder settings (ProjectStore.save: JSONEncoder, .sortedKeys). `mutate` is the red controls' door.
    static func latticeSubtree(_ url: URL, mutate: ((inout LatticeSettings) -> Void)? = nil) throws -> String {
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: url))
        var lattice = try XCTUnwrap(snap.lattice, "\(url.lastPathComponent) has a lattice block")
        mutate?(&lattice)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(lattice), as: UTF8.self)
    }

    /// The subtree's `flexible` object through ONE canonical serializer (JSONSerialization, sorted
    /// keys), or "none" — the part of the subtree whose bytes never depend on the hash seed.
    static func flexibleBlock(_ subtree: String) throws -> String {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(subtree.utf8)) as? [String: Any])
        guard let f = obj["flexible"] else { return "none" }
        return String(decoding: try JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: - (4) frames

    static func hex(_ d: Double) -> String {
        let h = String(d.bitPattern, radix: 16)
        return String(repeating: "0", count: 16 - h.count) + h
    }
    static func num(_ d: Double) -> String { String(format: "%.17g", d) + "/" + hex(d) }
    static func vec(_ v: SIMD3<Double>) -> String { "[\(num(v.x)) \(num(v.y)) \(num(v.z))]" }
    static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// One stack's lines: every frame value as its bit pattern; the columns as a count, two SHA-256s
    /// (the grid: iu iv u v area; the depths: entry exit lattice exitFace) and ≤ 17 sampled columns in full.
    static func stackLines(_ s: FlexStackInfo) -> [String] {
        var l: [String] = []
        l.append("frameValid \(s.frameValid) reason \"\(s.frameReason)\"")
        l.append("load \(vec(s.load))")
        l.append("xAxis \(vec(s.xAxis))")
        l.append("yAxis \(vec(s.yAxis))")
        l.append("centroid \(vec(s.centroid))")
        l.append("rotationDeg \(s.rotationDeg)")
        l.append("uMin \(num(s.uMin)) vMin \(num(s.vMin))")
        l.append("uExtent \(num(s.uExtentMM)) vExtent \(num(s.vExtentMM))")
        l.append("area \(num(s.areaMM2)) projectedArea \(num(s.projectedAreaMM2))")
        l.append("normalSpread \(num(s.normalSpreadDeg)) flag \(s.normalSpreadFlag)")
        l.append("buildAngle \(num(s.buildAngleDeg)) side \(s.side) principalAxisTied \(s.principalAxisTied)")
        l.append("pitch \(num(s.pitchMM)) nu \(s.nu) nv \(s.nv)")
        l.append("cell \(s.cell.count) sha256 \(sha(s.cell.map(String.init).joined(separator: ",")))")
        let geom = s.columns.map { "\($0.iu) \($0.iv) \(hex($0.uMM)) \(hex($0.vMM)) \(hex($0.areaMM2))" }.joined(separator: "\n")
        let depth = s.columns.map { "\(hex($0.entryT)) \(hex($0.exitT)) \(hex($0.latticeMM)) \($0.exitFace)" }.joined(separator: "\n")
        l.append("columns \(s.columns.count) sha256-grid \(sha(geom)) sha256-depth \(sha(depth))")
        let step = max(1, s.columns.count / 16)
        for (k, c) in s.columns.enumerated() where k % step == 0 || k == s.columns.count - 1 {
            l.append("  col[\(k)] iu \(c.iu) iv \(c.iv) u \(num(c.uMM)) v \(num(c.vMM)) area \(num(c.areaMM2)) "
                     + "entry \(num(c.entryT)) exit \(num(c.exitT)) lattice \(num(c.latticeMM)) exitFace \(c.exitFace)")
        }
        l.append("exitFaces " + s.exitFaces.map { "\($0.id):\(num($0.fraction))" }.joined(separator: " "))
        l.append("exitRegions " + s.exitRegions.map { "\($0.id):\(num($0.fraction))" }.joined(separator: " "))
        l.append("exitUnresolved \(num(s.exitUnresolvedFraction)) footprintArea \(num(s.footprintAreaMM2))")
        l.append("latticedColumns \(s.latticedColumns) latticeMM \(num(s.latticeMMMin)) \(num(s.latticeMMMean)) \(num(s.latticeMMMax)) stackMMMax \(num(s.stackMMMax))")
        return l
    }

    /// Core's stack for EVERY declared region of the model's open scene (rotation 0) and for every
    /// pressed face's own key — read straight from core through the page's own scene. The face presses
    /// are marked "pressed", resting faces "resting". `perturb` is the red control's door (applied to
    /// the first stack read).
    static func frames(_ m: FlexibleStageModel, label: String,
                       perturb: ((FlexStackInfo) -> FlexStackInfo)? = nil) async throws -> String {
        await m.waitForIdle()
        let info = try XCTUnwrap(m.sceneInfo, "\(label): the scene is open")
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref, "\(label): the scene")
        var keys = Set(info.regions.map { FlexFaceKey(region: $0.id, rotation: 0) })
        for k in m.loadedKeys { keys.insert(k) }
        let sorted = keys.sorted { ($0.region, $0.rotation) < ($1.region, $1.rotation) }
        var out = ["# FlexStackInfo golden · \(label) · core \(CoreFingerprint.value)",
                   "# scene \(info.nx)x\(info.ny)x\(info.nz) spacing \(num(info.spacing)) origin \(vec(info.origin)) build \(vec(info.buildDir)) latticeVoxels \(info.latticeVoxels)",
                   "# regions \(info.regions.map { "\($0.id)=\($0.faces.map(String.init).joined(separator: "+"))" }.joined(separator: " "))"]
        var first = true
        for k in sorted {
            let f = m.settings.face(k.region)
            let role = f.map { $0.isLoaded ? (k.rotation == $0.rotationDeg ? "pressed" : "pressed-other-rotation") : "resting" } ?? "-"
            out.append("region \(k.region) rot \(k.rotation) \(role) \"\(m.name(k.region))\"")
            do {
                var s = try scene.stack(face: k.region, rotation: k.rotation)
                if first, let perturb { s = perturb(s) }
                first = false
                out += stackLines(s).map { "  " + $0 }
            } catch {
                out.append("  error \"\(error)\"")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A stack with its FIRST column's entry moved by one ulp (the frames' red control).
    static func oneULP(_ s: FlexStackInfo) -> FlexStackInfo {
        guard let c = s.columns.first else { return s }
        var cols = s.columns
        cols[0] = FlexColumn(iu: c.iu, iv: c.iv, uMM: c.uMM, vMM: c.vMM, areaMM2: c.areaMM2, entryT: c.entryT.nextUp,
                             exitT: c.exitT, latticeMM: c.latticeMM, exitFace: c.exitFace)
        return FlexStackInfo(frameValid: s.frameValid, frameReason: s.frameReason, load: s.load, xAxis: s.xAxis, yAxis: s.yAxis,
                             centroid: s.centroid, rotationDeg: s.rotationDeg, uMin: s.uMin, vMin: s.vMin,
                             uExtentMM: s.uExtentMM, vExtentMM: s.vExtentMM, areaMM2: s.areaMM2,
                             projectedAreaMM2: s.projectedAreaMM2, normalSpreadDeg: s.normalSpreadDeg,
                             normalSpreadFlag: s.normalSpreadFlag, buildAngleDeg: s.buildAngleDeg, side: s.side,
                             principalAxisTied: s.principalAxisTied, pitchMM: s.pitchMM, nu: s.nu, nv: s.nv, cell: s.cell,
                             columns: cols, exitFaces: s.exitFaces, exitRegions: s.exitRegions,
                             exitUnresolvedFraction: s.exitUnresolvedFraction, footprintAreaMM2: s.footprintAreaMM2,
                             latticedColumns: s.latticedColumns, latticeMMMin: s.latticeMMMin, latticeMMMean: s.latticeMMMean,
                             latticeMMMax: s.latticeMMMax, stackMMMax: s.stackMMMax)
    }

    /// A model over `pm` with its scene open; `prepare` presses / rests (then the stacks settle).
    static func openModel(_ test: XCTestCase, _ pm: ProjectModel, _ what: String,
                          prepare: ((FlexibleStageModel) -> Void)? = nil) async throws -> FlexibleStageModel {
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(120, "\(what): the scene") { m.sceneState == .ready }
        prepare?(m)
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(120, "\(what): the pressed stacks") { m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }
        return m
    }

    /// The M2 stand with its top pressed at 5 kg and its bottom resting (FlexibleFEFieldTests' setup).
    static func m2Model(_ test: XCTestCase, _ testName: String) async throws -> FlexibleStageModel {
        let pm = try FlexiblePressFixtures.m2Project(testName)
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = try XCTUnwrap(FlexibleReadiness.suggestedFace(mesh: mesh, up: SIMD3(0, 0, 1))?.face)
        let bottom = try XCTUnwrap(FlexibleReadiness.suggestedFace(mesh: mesh, up: SIMD3(0, 0, -1))?.face)
        return try await openModel(test, pm, "the M2 stand") { m in _ = m.press(top, kg: 5); m.rest(bottom) }
    }

    // MARK: - (5) the probe's documents

    /// 2 declared faces, varioshore_tpu, ONE loaded entry (spec §10).
    static func probeDocument(_ entry: [String: Any]) throws -> String {
        let i = FlexibleJob.Inputs(modelPath: "part.stl", resolution: 48, beadWidthMM: 0.42, faceCount: 2,
                                   settings: FlexibleStageSettings(materialID: "varioshore_tpu"))
        var block = FlexibleJob.header(i, material: "varioshore_tpu")
        block["faces"] = [entry]
        return try FlexibleJob.document(i, material: "varioshore_tpu", block: block)
    }

    /// The entry exactly as faceEntry writes a pressed face today.
    static func controlEntry() throws -> [String: Any] {
        try FlexibleJob.faceEntry(FlexibleFaceSettings(faceRegionID: 0), finish: .covered, stamps: [:])
    }

    static func probeDocuments() throws -> (control: String, tilt: String, edge: String) {
        let control = try controlEntry()
        var tilt = control
        tilt["press_direction"] = [0.0, 0.0, -1.0]
        var edge = control
        edge["face_region_id"] = nil
        edge["face_region_ids"] = [0, 1]
        edge["press_direction"] = [0.0, 0.0, -1.0]
        return (try probeDocument(control), try probeDocument(tilt), try probeDocument(edge))
    }

    /// Core's answer to each document today (nil = accepted).
    static func probeAnswers() throws -> [String: String?] {
        let d = try probeDocuments()
        return ["control": TopOptKit.jobSchemaError(Data(d.control.utf8)),
                "tilt": TopOptKit.jobSchemaError(Data(d.tilt.utf8)),
                "edge": TopOptKit.jobSchemaError(Data(d.edge.utf8))]
    }

    static func probeGoldenText(_ a: [String: String?]) throws -> String {
        var obj: [String: Any] = ["base": "01ec5e3c", "core": CoreFingerprint.value]
        for (k, v) in a { obj[k] = v ?? NSNull() }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - the slabs' facts (recorded, never assumed)

    /// Each slab's pseudo-faces as core segments them, and which ones WRAP: core's normal-spread flag
    /// (> 30°) from its own frame, or core's refusal when the face's normals cancel outright.
    static func slabFacts() async throws -> String {
        let s = FlexiblePressFixtures.slab
        var out = ["# slabs \(s.width) x \(s.depth) x \(s.height) mm, vertical fillets r \(s.radius) mm, \(s.facets) facets per 90° · core \(CoreFingerprint.value)"]
        for kind in FlexiblePressFixtures.SlabKind.allCases {
            let path = try FlexiblePressFixtures.slabPath(kind)
            let mesh = try TopOptKit.importMesh(path: path)
            let areas = FlexiblePressFixtures.faceAreas(mesh)
            out.append("\(kind.rawValue): corner radii \(kind.radii) · pseudoFaces \(mesh.pseudoFaces) · triangles \(mesh.triangleCount) · faces \(mesh.faceCount)")
            let inputs = FlexibleJob.Inputs(modelPath: path, resolution: 50, beadWidthMM: 0.42, faceCount: mesh.faceCount,
                                            settings: FlexibleStageSettings(materialID: "varioshore_tpu"))
            let scene = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(inputs, fallbackMaterial: "varioshore_tpu"),
                                          jobDir: (path as NSString).deletingLastPathComponent)
            for f in 0..<mesh.faceCount {
                let tris = mesh.faceIDs.filter { Int($0) == f }.count
                do {
                    let st = try scene.stack(face: FlexibleJob.regionID(face: f), rotation: 0)
                    out.append(String(format: "  face %d triangles %d area %.6f mm2 load (%.6f, %.6f, %.6f) normalSpread %.4f° wraps %@",
                                      f, tris, areas[f] ?? 0, st.load.x, st.load.y, st.load.z, st.normalSpreadDeg,
                                      st.normalSpreadFlag ? "YES (spread flag)" : "no"))
                } catch {
                    out.append(String(format: "  face %d triangles %d area %.6f mm2 wraps %@ · core: %@", f, tris, areas[f] ?? 0,
                                      "\(error)".contains("cancel") ? "YES (normals cancel)" : "?", "\(error)"))
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

/// RECORD=1 only: writes the goldens above. Skipped (and counted) on every other run.
@MainActor
final class FlexibleAngledGoldenRecorder: XCTestCase {
    typealias G = FlexibleAngledGoldens

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["RECORD"] == "1" else {
            throw XCTSkip("set RECORD=1 to record the angled-press goldens")
        }
        print("FLEX-AP RECORD \(G.hashingMode) → \(G.dir.path)")
        XCTAssertTrue(G.deterministicHashing, "★ record under SWIFT_DETERMINISTIC_HASHING=1 (his jobs carry hash-ordered outlines)")
    }

    func testRecord1PadJobs() async throws {
        try G.write("c1_pad_pure_run_job.json", try G.padPureRunJob())
        try G.write("c1_pad_pure_stamp_run_job.json", try G.padPureStampRunJob())
        let (m, _, _) = try await G.padModel(self)
        try G.write("c1_pad_model_run_job.json", try G.runJob(m, roots: [G.repo]))
        try G.write("c1_pad_model_scene_job.json", try G.sceneJob(m, roots: [G.repo]))
    }

    func testRecord2HisRound5Jobs() async throws {
        let (r, m, first) = try await G.hisRound5Model(self)
        print("FLEX-AP RECORD his r5 held send: [\(first.title)] resting \(first.resting) · \(G.hashingMode)")
        try G.write("his_r5_held_send_run_job.json", try G.runJob(m, resting: Set(first.resting), roots: G.rootToken(r)))
        try G.write("his_r5_held_send.txt", "title \(first.title)\nresting \(first.resting)\nscope \(first.scope ?? "-")\n\(G.hashingMode)\n")
        try G.write("his_r5_scene_job.json", try G.sceneJob(m, roots: G.rootToken(r)))
    }

    func testRecord3LatticeSubtrees() throws {
        for s in G.subtreeSources { try G.write(s.name, try G.latticeSubtree(s.url)) }
    }

    func testRecord4Frames() async throws {
        let (pad, _, _) = try await G.padModel(self)
        try G.write("frames_c1_pad.txt", try await G.frames(pad, label: "C1 pad (top pressed 30 kg, bottom resting)"))
        let r3 = try FlexiblePressFixtures.his0004(self)
        let m3 = try await FlexibleHisProject.openedModel(r3.project, test: self)
        try G.write("frames_his_0004.txt", try await G.frames(m3, label: "his 0004 as saved"))
        let r5 = try FlexiblePressFixtures.hisRound5(self)
        let m5 = try await FlexibleHisProject.openedModel(r5.project, test: self)
        try G.write("frames_his_0004_r5.txt", try await G.frames(m5, label: "his 0004_r5 as saved"))
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "the 60 mm cube")
        try G.write("frames_cube60.txt", try await G.frames(cube, label: "60 mm cube (nothing pressed)"))
        let m2 = try await G.m2Model(self, "FlexibleAngledGoldenRecorder.testRecord4Frames")
        try G.write("frames_m2.txt", try await G.frames(m2, label: "M2 stand (top pressed 5 kg, bottom resting)"))
    }

    func testRecord5ProbeRefusals() throws {
        let a = try G.probeAnswers()
        print("FLEX-AP RECORD probe answers: \(a)")
        XCTAssertNil(a["control"] ?? "missing", "the control parses")
        try G.write("probe_refusals_base.json", try G.probeGoldenText(a))
    }

    func testRecord6RoundedSlabFacts() async throws {
        try G.write("rounded_slab.txt", try await G.slabFacts())
    }

    func testRecord7Manifest() throws {
        try G.write("MANIFEST.txt", """
        # Angled presses (task 2026-10-07), batch AP0: the BASE goldens, recorded at 01ec5e3c
        # (claude/flexible-screens, PR #362) BEFORE any angled-press code, core \(CoreFingerprint.value),
        # \(G.hashingMode), by FlexibleAngledGoldenRecorder (RECORD=1). Read by FlexibleAngledGoldenTests.
        # S1 (the #361 sync) re-runs them, REPORTS every difference with the commit that caused it, and
        # re-records them as the post-S1 base; every later batch must equal that base.
        c1_pad_pure_run_job.json          FlexibleJob.runJobJSON(FlexibleStageTests.inputs(settings())) — paths as $REPO
        c1_pad_pure_stamp_run_job.json    the same, face 1 shaped Stamp (thumb, centred, 2 mm pitch)
        c1_pad_model_run_job.json         the app's model over C1's pad: top pressed 30 kg, bottom resting
        c1_pad_model_scene_job.json       that model's scene job
        his_r5_held_send_run_job.json     his 0004_r5 AS SAVED: runJobJSON(resting:) of the first FlexibleCoreHold send ($ROOT = the temp store)
        his_r5_held_send.txt              which send that was
        his_r5_scene_job.json             his 0004_r5's scene job
        lattice_subtree_*.json            the snapshot's `lattice`, decoded and re-encoded (.sortedKeys) — never re-saved
        frames_*.txt                      core's FlexStackInfo for every declared region (rotation 0) and every pressed key, bit patterns
        probe_refusals_base.json          core's answer to the probe's control / tilt / edge documents (null = accepted)
        rounded_slab.txt                  the two slabs' pseudo-faces and which wrap (core's normal-spread flag, or its "normals cancel" refusal)

        """)
    }
}
