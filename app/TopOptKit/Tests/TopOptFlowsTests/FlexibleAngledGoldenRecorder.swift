// FlexibleAngledGoldenRecorder — the ANGLED PRESSES baselines (task 2026-10-07, batch AP0), recorded at
// 01ec5e3c BEFORE any angled-press code exists, so every later batch can prove that existing face presses
// keep their job bytes and core's frames (spec §14, §15).
//
// Run by hand, under deterministic hashing (the lattice SUBTREES' raw bytes carry UUID-keyed
// dictionaries, which encode in hash order; every other golden is the same under any seed, measured),
// naming the base the goldens are of:
//
//     RECORD=1 SWIFT_DETERMINISTIC_HASHING=1 FLEX_AP_BASE=<sha> swift test --filter FlexibleAngledGoldenRecorder
//
// ★ AP0 FIX-UP (verifier, 2026-10-07): no compared line carries core's fingerprint (it is the repo HEAD
// at build_core.sh time, not core's content: CI and every rebuild would read red) — it is printed and
// kept in MANIFEST.txt only; probe_refusals_base.json is NEVER overwritten (AP6 reads the base texts; a
// later core's answers go to probe_answers.json); and the recorder adds (6) every existing send's job
// of his 0004, his r5 and the A1 store's Flexible projects (frozen), (7) the STEP cube's and his
// l bracket's frames, (8) core's designs and density / owner / handover fields.
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

    /// The commit the goldens are the base OF (FLEX_AP_BASE; the recorder requires it) — never a
    /// literal, so a re-base at S1 cannot claim 01ec5e3c.
    static var baseLabel: String { ProcessInfo.processInfo.environment["FLEX_AP_BASE"] ?? "UNLABELLED (set FLEX_AP_BASE)" }

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
        // ★ AP0 fix-up: the A1 store's three Flexible projects (frozen): the M2 stand's face 2, the pad's
        // five stamped presses in three groups, and the later save of 'Pad split top' (its faces differ)
        ("lattice_subtree_A1_0002.json", FlexiblePressFixtures.a1Dir(2).appendingPathComponent("project.json")),
        ("lattice_subtree_A1_0003.json", FlexiblePressFixtures.a1Dir(3).appendingPathComponent("project.json")),
        ("lattice_subtree_A1_0004.json", FlexiblePressFixtures.a1Dir(4).appendingPathComponent("project.json")),
    ]

    /// ★ AP0 FIX-UP: the WHOLE subtree, in a form no hash seed reaches — compared in every run (CI
    /// included). JSONEncoder writes a dictionary keyed by UUID as a flat [key, value, key, value, …]
    /// array in HASH order (groupDepthMM, groupRoles, groupDensities, frozenRegionDensity); each such
    /// array (even length, every even element a UUID string, not every odd one) becomes an object, and
    /// everything is written through ONE serializer with sorted keys. An ordered list of UUIDs stays a
    /// list. Values are untouched: a changed depth is still a changed line.
    static func canonicalSubtree(_ json: String) throws -> String {
        func isUUID(_ x: Any) -> Bool { (x as? String).flatMap { UUID(uuidString: $0) } != nil }
        func canon(_ x: Any) -> Any {
            if let d = x as? [String: Any] { return d.mapValues(canon) }
            if let a = x as? [Any] {
                let evens = stride(from: 0, to: a.count, by: 2).map { a[$0] }
                let odds = stride(from: 1, to: a.count, by: 2).map { a[$0] }
                if !a.isEmpty, a.count % 2 == 0, evens.allSatisfy(isUUID), !odds.allSatisfy(isUUID),
                   Set(evens.compactMap { $0 as? String }).count == evens.count {
                    var o: [String: Any] = [:]
                    for (k, v) in zip(evens, odds) { o[k as! String] = canon(v) }
                    return o
                }
                return a.map(canon)
            }
            return x
        }
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        let data = try JSONSerialization.data(withJSONObject: canon(obj), options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

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

    /// ★ AP0 FIX-UP: the sampled columns spread over the face in BOTH directions — the first, the last,
    /// and the column nearest each point of a 5 × 5 lattice over the (iu, iv) range. (A stride over the
    /// iv-major column list kept iu = 0: 16 of 17 samples sat on one edge, where no sector cut or new X
    /// axis shows.)
    static func sampleIndices(_ cols: [FlexColumn]) -> [Int] {
        guard let iu0 = cols.map(\.iu).min(), let iu1 = cols.map(\.iu).max(),
              let iv0 = cols.map(\.iv).min(), let iv1 = cols.map(\.iv).max() else { return [] }
        var picked: Set<Int> = [0, cols.count - 1]
        for a in 0...4 {
            for b in 0...4 {
                let tu = Double(iu0) + Double(iu1 - iu0) * Double(a) / 4
                let tv = Double(iv0) + Double(iv1 - iv0) * Double(b) / 4
                var best = 0, bestD = Double.infinity
                for (k, c) in cols.enumerated() {
                    let d = (Double(c.iu) - tu) * (Double(c.iu) - tu) + (Double(c.iv) - tv) * (Double(c.iv) - tv)
                    if d < bestD { bestD = d; best = k }
                }
                picked.insert(best)
            }
        }
        return picked.sorted()
    }

    /// ★ AP0 FIX-UP: one short SHA-256 (12 hex) per ROW of columns (iv), over each column's grid and
    /// depth bit patterns, 16 rows a line — so S1 can say WHICH rows a moved column is in, not only
    /// that one moved.
    static func rowDigestLines(_ cols: [FlexColumn]) -> [String] {
        var rows: [Int: [String]] = [:]
        for c in cols {
            rows[c.iv, default: []].append("\(c.iu) \(hex(c.uMM)) \(hex(c.vMM)) \(hex(c.areaMM2)) \(hex(c.entryT)) \(hex(c.exitT)) \(hex(c.latticeMM)) \(c.exitFace)")
        }
        let cells = rows.keys.sorted().map { iv in "\(iv):" + sha(rows[iv]!.joined(separator: "\n")).prefix(12) }
        return stride(from: 0, to: cells.count, by: 16).map { "rows " + cells[$0..<min($0 + 16, cells.count)].joined(separator: " ") }
    }

    /// One stack's lines: every frame value as its bit pattern; the columns as a count, two SHA-256s
    /// (the grid: iu iv u v area; the depths: entry exit lattice exitFace), one short SHA-256 per row,
    /// and ≤ 27 sampled columns in full.
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
        l += rowDigestLines(s.columns).map { "  " + $0 }
        for k in sampleIndices(s.columns) {
            let c = s.columns[k]
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
        // ★ AP0 FIX-UP: core's fingerprint is PRINTED, never in the compared text (it is the repo HEAD
        // when build_core.sh ran — CI and every rebuild at another commit would read every frame red)
        print("FLEX-AP frames '\(label)' · built against core \(CoreFingerprint.value) (printed, not compared)")
        var out = ["# FlexStackInfo golden · \(label)",
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
        var obj: [String: Any] = ["base": baseLabel, "core": CoreFingerprint.value]
        for (k, v) in a { obj[k] = v ?? NSNull() }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - the slabs' facts (recorded, never assumed)

    /// Each slab's pseudo-faces as core segments them, and which ones WRAP: core's normal-spread flag
    /// (> 30°) from its own frame, or core's refusal when the face's normals cancel outright.
    static func slabFacts() async throws -> String {
        let s = FlexiblePressFixtures.slab
        print("FLEX-AP slab facts · built against core \(CoreFingerprint.value) (printed, not compared)")
        var out = ["# slabs \(s.width) x \(s.depth) x \(s.height) mm, vertical fillets r \(s.radius) mm, \(s.facets) facets per 90°"]
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

    // MARK: - (6) every existing send (AP0 fix-up)

    /// The projects whose EVERY send is pinned: his 0004 and r5 as saved, and the A1 store's three
    /// Flexible projects (frozen): the M2 stand's face 2, the pad's five stamped presses in three
    /// groups, and the later save of 'Pad split top'.
    static let sendSets = ["his_0004", "his_r5", "A1_0002", "A1_0003", "A1_0004"]

    /// The set's project as saved, its model opened and settled.
    static func sendSetModel(_ label: String, _ test: XCTestCase) async throws -> (roots: [(path: String, token: String)], m: FlexibleStageModel) {
        let r: FlexibleHisProject.Restored
        switch label {
        case "his_0004": r = try FlexiblePressFixtures.his0004(test)
        case "his_r5": r = try FlexiblePressFixtures.hisRound5(test)
        case "A1_0002": r = try FlexiblePressFixtures.a1Project(2, test)
        case "A1_0003": r = try FlexiblePressFixtures.a1Project(3, test)
        case "A1_0004": r = try FlexiblePressFixtures.a1Project(4, test)
        default: throw XCTSkip("no send set \(label)")
        }
        let m = FlexibleStageModel(project: r.project, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await settleAllowingRefusedStacks(m, label)
        return (rootToken(r), m)
    }

    /// Settled the way the page settles — every loaded stack built (with its geometry) OR refused by
    /// core, then no design in flight. (The A1 store's M2 project, as saved, loads 19 faces through its
    /// main-page groups and core refuses 9 of their stacks — "no column at a 3.410559 mm pitch" — so a
    /// wait for every stack never ends; the Export step still offers its sends, and those are pinned.)
    static func settleAllowingRefusedStacks(_ m: FlexibleStageModel, _ what: String) async throws {
        try await FlexibleHisProject.waitFor(120, "\(what): every loaded stack built or refused") {
            m.sceneState == .ready
                && m.loadedKeys.allSatisfy { (m.stacks[$0] != nil && m.geometry[$0] != nil) || m.stackErrors[$0] != nil }
        }
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(120, "\(what): designs") { !m.readiness.designing && !m.designsInFlight }
        await m.waitForIdle()
        let refused = m.loadedKeys.filter { m.stackErrors[$0] != nil }.map(\.region).sorted()
        print("FLEX-AP \(what): \(m.loadedKeys.count) loaded key(s), core refused \(refused.count) stack(s) \(refused)")
    }

    /// What the Export step sends for the project as it stands: each FlexibleCoreHold send (its
    /// resting faces), or — nothing held — the job itself ("direct", resting none).
    static func sends(_ m: FlexibleStageModel) -> [(title: String, resting: [Int])] {
        guard let hold = m.coreHold else { return [("direct", [])] }
        return hold.fixes.compactMap { f in f.scope == nil ? nil : (f.title, f.resting) }
    }

    /// Send n's (1-based) golden; his r5's first keeps its AP0 name.
    static func sendFile(_ label: String, _ n: Int) -> String {
        label == "his_r5" && n == 1 ? "his_r5_held_send_run_job.json" : "\(label)_send\(n)_run_job.json"
    }

    static func sceneFile(_ label: String) -> String { "\(label)_scene_job.json" }

    /// The set's index: one line per send — its title, its resting faces and the file of its job.
    static func sendIndex(_ label: String, _ s: [(title: String, resting: [Int])]) -> String {
        "# \(label): the Export step's sends as the project stands (FlexibleCoreHold; 'direct' = nothing held)\n"
            + s.enumerated().map { "send \($0.offset + 1) · \($0.element.title) · resting \($0.element.resting) · \(sendFile(label, $0.offset + 1))" }
                .joined(separator: "\n") + "\n"
    }

    // MARK: - (7) frames on STEP parts (AP0 fix-up)

    /// Core's 10 mm STEP cube (B-rep faces, tied squares: the principal_2d case) and his 'l bracket 3'
    /// (frozen S0 92A8016E), nothing pressed — their frames before S1.
    static func stepFrameModels(_ test: XCTestCase, _ testName: String) async throws -> [(file: String, label: String, m: FlexibleStageModel)] {
        let cube = try await openModel(test, try FlexiblePressFixtures.stepCubeProject(testName), "the STEP cube")
        let bracket = try await openModel(test, try FlexiblePressFixtures.lBracketProject(testName), "his l bracket")
        return [("frames_step_cube.txt", "STEP cube 10 mm (nothing pressed)", cube),
                ("frames_l_bracket.txt", "his l bracket 3 (nothing pressed)", bracket)]
    }

    // MARK: - (8) core's designs and fields (AP0 fix-up)

    /// SHA-256 over an array's raw bytes (little-endian bit patterns; an Int owner is 8 bytes).
    static func bytesSHA<T>(_ xs: [T]) -> String {
        let d = xs.withUnsafeBufferPointer { Data(buffer: $0) }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// One core design (every column's every value as its bit pattern, hashed; the counts, tier,
    /// ranges and refusal in full; the 2-D samples of the stack's columns in full).
    static func designLines(_ d: FlexFaceDesignInfo, stack: FlexStackInfo?) -> [String] {
        func rng(_ r: ClosedRange<Double>?) -> String { r.map { "\(num($0.lowerBound))..\(num($0.upperBound))" } ?? "nil" }
        func opt(_ x: Double?) -> String { x.map { hex($0) } ?? "nil" }
        func col(_ c: FlexColumnDesign) -> String {
            "\(hex(c.s)) \(hex(c.pressureMPa)) \(hex(c.heightMM)) \(hex(c.targetDepthMM)) \(hex(c.targetStrain)) \(c.status) "
                + "\(c.targetExtrapolated) \(hex(c.targetDensity)) \(opt(c.nearestDepthMM)) \(c.nearestKnown) \(hex(c.clampedDensity)) "
                + "\(opt(c.clampedDepthMM)) \(hex(c.buildableDensity)) \(hex(c.buildableDepthMM)) \(c.buildableOK) "
                + "\(c.buildableExtrapolated) \(hex(c.cellMM)) \(hex(c.sigmaMM))"
        }
        var l = ["refusal \(d.refusal.map { "\($0.code): \($0.reason)" } ?? "none") · tier \(d.tier.tier) band \(num(d.tier.band)) why \"\(d.tier.why)\"",
                 "ok \(d.ok) tooFirm \(d.tooFirm) tooSoft \(d.tooSoft) beyondData \(d.beyondData) noLattice \(d.noLattice) "
                    + "solidUnderMap \(d.solidUnderMap) targetExtrapolated \(d.targetExtrapolated) buildableExtrapolated \(d.buildableExtrapolated) "
                    + "buildableBeyondData \(d.buildableBeyondData) nearEdge \(d.nearEdge)",
                 "pressureEven \(num(d.designPressureEvenMPa)) stamp used \(d.designStampUsed) rigidAveraged \(d.designStampRigidAveraged) "
                    + "offFace \(d.designStampOffFace) \(num(d.designStampOffFaceN)) maxSmoothingChange \(num(d.maxSmoothingChangeMM)) "
                    + "materialVolume \(num(d.materialVolumeMM3))",
                 "ranges targetDepth \(rng(d.targetDepthRange)) buildableDepth \(rng(d.buildableDepthRange)) "
                    + "buildableDensity \(rng(d.buildableDensityRange)) cell \(rng(d.cellRange)) sigma \(rng(d.sigmaRange))",
                 "columns \(d.columns.count) sha256 \(sha(d.columns.map(col).joined(separator: "\n")))"]
        let idx: [Int]
        if let st = stack, st.columns.count == d.columns.count { idx = sampleIndices(st.columns) } else {
            idx = Array(stride(from: 0, to: d.columns.count, by: max(1, d.columns.count / 8)))
        }
        for k in idx where k < d.columns.count { l.append("  col[\(k)] " + col(d.columns[k])) }
        return l
    }

    /// One assembled density field: the grid; SHA-256s of the density (Float) and owner bytes; the
    /// classes (−1 not lattice, 0 lattice under no loaded face, > 0 ρ) and ρ's sum; the owners'
    /// histogram; one short SHA-256 per z layer (16 a line). `perturbOwner`: the red control's door
    /// (one lattice voxel's owner + 1).
    static func fieldLines(_ f: FlexDensityField, perturbOwner: Bool = false) -> [String] {
        var owner = f.owner
        if perturbOwner, let i = f.density.indices.first(where: { f.density[$0] > 0 }) { owner[i] += 1 }
        var notLattice = 0, unowned = 0, dense = 0, sum = 0.0
        for x in f.density {
            if x < -0.5 { notLattice += 1 } else if x == 0 { unowned += 1 } else { dense += 1; sum += Double(x) }
        }
        var hist: [Int: Int] = [:]
        for o in owner { hist[o, default: 0] += 1 }
        let layer = f.nx * f.ny
        let layers = (0..<f.nz).map { k -> String in
            let r = (k * layer)..<min((k + 1) * layer, f.density.count)
            return "\(k):" + sha(bytesSHA(Array(f.density[r])) + bytesSHA(Array(owner[r]))).prefix(12)
        }
        var l = ["grid \(f.nx)x\(f.ny)x\(f.nz) spacing \(num(f.spacing)) origin \(vec(f.origin))",
                 "density sha256 \(bytesSHA(f.density)) owner sha256 \(bytesSHA(owner))",
                 "voxels notLattice \(notLattice) unowned \(unowned) rho>0 \(dense) sum \(num(sum))",
                 "owners " + hist.keys.sorted().map { "\($0):\(hist[$0]!)" }.joined(separator: " ")]
        l += stride(from: 0, to: layers.count, by: 16).map { "layers " + layers[$0..<min($0 + 16, layers.count)].joined(separator: " ") }
        return l
    }

    /// ★ The base S1 attributes core's `in_stack` → `stack_owns_projection` change against (spec §0,
    /// §15.2, §20): for the model's settled designs, (a) core's design of every loaded key; (b) core's
    /// assembled density field of each squeeze group, keys sorted by region (or core's refusal: a pinch
    /// is one profile per stack), with core's voxel counts and handovers; (c) the field the app's
    /// lattice is built from (generateLattice, the combined field kept), or why it is not built.
    static func fieldsText(_ m: FlexibleStageModel, label: String, perturbOwner: Bool = false) async throws -> String {
        await m.waitForIdle()
        let build = m.build
        let sortedKeys: ([FlexFaceKey]) -> [FlexFaceKey] = { ks in ks.sorted { a, b in (a.region, a.rotation) < (b.region, b.rotation) } }
        print("FLEX-AP fields '\(label)' · built against core \(CoreFingerprint.value) (printed, not compared)")
        var out = ["# core's designs and density fields · \(label)",
                   "# build \(build.topology) beadsPerWall \(build.beadsPerWall) beadWidth \(num(build.beadWidthMM)) · design temp \(m.designTempC.map { num($0) } ?? "-")"]
        for k in sortedKeys(m.loadedKeys) {
            out.append("design region \(k.region) rot \(k.rotation) \"\(m.name(k.region))\"")
            guard let d = m.designs[k] else { out.append("  none"); continue }
            out += designLines(d, stack: m.stacks[k]).map { "  " + $0 }
        }
        var first = true
        for g in m.squeezeGroups {
            let keys = sortedKeys(m.loadedKeys.filter { g.regions.contains($0.region) })
            out.append("group \(g.number) keys \(keys.map { "\($0.region)@\($0.rotation)" }.joined(separator: " ")) · core's assembled field")
            do {
                let (f, s) = try await m.workerForTests.withScene { scene -> (FlexDensityField, FlexFieldSliceInfo) in
                    let f = try scene.densityField(faces: keys.map(\.region), rotations: keys.map(\.rotation), build: build)
                    let s = try scene.densitySlice(faces: keys.map(\.region), rotations: keys.map(\.rotation), build: build,
                                                   axis: 2, index: f.nz / 2)
                    return (f, s)
                }
                out += fieldLines(f, perturbOwner: perturbOwner && first).map { "  " + $0 }
                first = false
                out.append("  core voxels lattice \(s.latticeVoxels) assigned \(s.assignedVoxels) unassigned \(s.unassignedVoxels)")
                out.append("  handovers " + (s.handovers.isEmpty ? "none" : s.handovers.map {
                    "\($0.faceA)|\($0.faceB) overlap \(num($0.overlapMM3)) blended \(num($0.blendedMM3))" }.joined(separator: " · ")))
            } catch {
                out.append("  error \"\(error)\"")
            }
        }
        guard m.readiness.isReady else {
            out.append("app field: not built — blocking: \(m.readiness.blocking.map(\.oneLine))")
            return out.joined(separator: "\n") + "\n"
        }
        m.keepCombinedField = true
        m.generateLattice()
        try await FlexibleHisProject.waitFor(180, "\(label): the lattice") { (m.lattice != nil && !m.latticeIsStale) || m.latticeError != nil }
        await m.waitForIdle()
        if let e = m.latticeError {
            out.append("app field: the build failed \"\(e)\"")
        } else {
            let f = try XCTUnwrap(m.lastCombinedField, "\(label): the field the lattice was built from")
            out.append("app field (the lattice is built from it) · groups \(m.squeezeGroups.count) · shared voxels \(m.lattice?.sharedVoxels ?? -1)")
            out += fieldLines(f, perturbOwner: perturbOwner && first).map { "  " + $0 }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The models whose fields are pinned: C1's pad (top pressed 30 kg, bottom resting), his 0004 and r5 as saved.
    static let fieldSets = ["c1_pad", "his_0004", "his_0004_r5"]

    static func fieldSetModel(_ label: String, _ test: XCTestCase) async throws -> FlexibleStageModel {
        switch label {
        case "c1_pad": return try await padModel(test).0
        case "his_0004": return try await sendSetModel("his_0004", test).m
        case "his_0004_r5": return try await sendSetModel("his_r5", test).m
        default: throw XCTSkip("no field set \(label)")
        }
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
        print("FLEX-AP RECORD \(G.hashingMode) base \(G.baseLabel) core \(CoreFingerprint.value) → \(G.dir.path)")
        XCTAssertTrue(G.deterministicHashing, "★ record under SWIFT_DETERMINISTIC_HASHING=1 (the subtrees' raw bytes carry hash-ordered UUID dictionaries)")
        XCTAssertNotNil(ProcessInfo.processInfo.environment["FLEX_AP_BASE"], "★ name the base: FLEX_AP_BASE=<sha>")
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

    /// ★ AP0 FIX-UP: probe_refusals_base.json is the BASE core's refusal texts — AP6's injected probe
    /// reads them after S1, when core accepts both forms — so it is NEVER overwritten. With the base in
    /// place, this core's answers are compared with it, and written to probe_answers.json only if they differ.
    func testRecord5ProbeRefusals() throws {
        let a = try G.probeAnswers()
        print("FLEX-AP RECORD probe answers: \(a)")
        let base = G.dir.appendingPathComponent("probe_refusals_base.json")
        guard FileManager.default.fileExists(atPath: base.path) else {
            XCTAssertNil(a["control"] ?? "missing", "the control parses")
            try G.write("probe_refusals_base.json", try G.probeGoldenText(a))
            return
        }
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: base)) as? [String: Any])
        let same = ["control", "tilt", "edge"].allSatisfy { k in (obj[k] as? String) == (a[k] ?? nil) }
        if same {
            print("FLEX-AP RECORD probe_refusals_base.json kept: this core gives the base's answers (nothing written)")
        } else {
            print("FLEX-AP RECORD probe_refusals_base.json kept (never overwritten); this core's answers → probe_answers.json")
            try G.write("probe_answers.json", try G.probeGoldenText(a))
        }
    }

    func testRecord6RoundedSlabFacts() async throws {
        try G.write("rounded_slab.txt", try await G.slabFacts())
    }

    func testRecord7Manifest() throws {
        try G.write("MANIFEST.txt", """
        # Angled presses (task 2026-10-07): the BASE goldens of \(G.baseLabel) (claude/flexible-screens, PR #362),
        # recorded by FlexibleAngledGoldenRecorder (RECORD=1, \(G.hashingMode)), built against core \(CoreFingerprint.value).
        # The core fingerprint is the repo HEAD when build_core.sh ran, so it lives HERE only: no compared golden
        # line carries it (testNoComparedGoldenCarriesTheCoreFingerprint). Read by FlexibleAngledGoldenTests.
        # AP0 recorded the first base at 01ec5e3c, BEFORE any angled-press code. S1 (the #361 sync) re-ran them,
        # REPORTED every difference with the commit that caused it, and re-recorded them as the post-S1 base
        # (FLEX_AP_BASE=<the final merge>) — except probe_refusals_base.json, which the recorder never overwrites
        # (AP6 reads the base texts; a later core's differing answers go to probe_answers.json).
        # Every later batch must equal that base.
        c1_pad_pure_run_job.json          FlexibleJob.runJobJSON(FlexibleStageTests.inputs(settings())) — paths as $REPO
        c1_pad_pure_stamp_run_job.json    the same, face 1 shaped Stamp (thumb, centred, 2 mm pitch)
        c1_pad_model_run_job.json         the app's model over C1's pad: top pressed 30 kg, bottom resting
        c1_pad_model_scene_job.json       that model's scene job
        his_r5_held_send_run_job.json     his 0004_r5 AS SAVED: runJobJSON(resting:) of the first FlexibleCoreHold send ($ROOT = the temp store)
        his_r5_held_send.txt              which send that was
        his_r5_scene_job.json             his 0004_r5's scene job
        <set>_sends.txt                   every send the Export step offers as the project stands (FlexibleCoreHold, or 'direct'):
        <set>_send<n>_run_job.json          its job, for his_0004, his_r5 (send 1 = his_r5_held_send_run_job.json),
        <set>_scene_job.json                A1_0002, A1_0003, A1_0004 (the A1 store's Flexible projects, s0_frozen/a1)
        lattice_subtree_*.json            the snapshot's `lattice`, decoded and re-encoded (.sortedKeys) — never re-saved;
                                          compared canonically in every run (UUID-keyed dictionaries as objects), raw under
                                          SWIFT_DETERMINISTIC_HASHING=1
        frames_*.txt                      core's FlexStackInfo for every declared region (rotation 0) and every pressed key,
                                          bit patterns: two SHA-256s over every column, one short SHA-256 per row, ≤ 27 columns
                                          on a 5 × 5 (iu, iv) lattice in full (C1 pad, his 0004, r5, the 60 mm cube, the M2
                                          stand, the STEP cube, his l bracket)
        fields_*.txt                      core's design of every loaded key (every column hashed), core's assembled density
                                          field of each squeeze group (density / owner SHA-256s, owner histogram, per-layer
                                          SHA-256s, voxel counts, handovers) or its refusal, and the app's combined field
                                          (C1 pad, his 0004, his 0004_r5)
        probe_refusals_base.json          the BASE core's answer to the probe's control / tilt / edge documents (null = accepted), AP0's
        probe_answers.json                this core's answers, written when they differ from the base's (since S1: all accepted)
        rounded_slab.txt                  the two slabs' pseudo-faces and which wrap (core's normal-spread flag, or its "normals cancel" refusal)

        """)
    }

    /// ★ AP0 FIX-UP: EVERY existing send's job (and the scene job) of his 0004, his r5 and the A1
    /// store's three Flexible projects — the ruling's "every existing face press is unchanged: job bytes".
    func testRecord8EverySendsJob() async throws {
        for label in G.sendSets {
            let (roots, m) = try await G.sendSetModel(label, self)
            let s = G.sends(m)
            print("FLEX-AP RECORD \(label): \(s.count) send(s) \(s.map(\.title))")
            try G.write("\(label)_sends.txt", G.sendIndex(label, s))
            for (n, send) in s.enumerated() {
                try G.write(G.sendFile(label, n + 1), try G.runJob(m, resting: Set(send.resting), roots: roots))
            }
            try G.write(G.sceneFile(label), try G.sceneJob(m, roots: roots))
        }
    }

    func testRecord9FramesOnStepParts() async throws {
        for (file, label, m) in try await G.stepFrameModels(self, "FlexibleAngledGoldenRecorder.testRecord9FramesOnStepParts") {
            try G.write(file, try await G.frames(m, label: label))
        }
    }

    func testRecordFieldsAndDesigns() async throws {
        for label in G.fieldSets {
            let m = try await G.fieldSetModel(label, self)
            try G.write("fields_\(label).txt", try await G.fieldsText(m, label: label))
        }
    }
}
