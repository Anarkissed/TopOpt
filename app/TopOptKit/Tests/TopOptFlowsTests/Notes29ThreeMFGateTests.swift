// Notes29ThreeMFGateTests — two small fixes (notes29, builder H2):
//
// 1. CELL-LATTICE PRINT FILES AS 3MF (his rule 11-24: "if we are saying 3mf in two separate places, it should at least default
//    to exporting 3mf"). Release 20 asked core for a 3MF only for Organic; core's default for a cell lattice is an STL, so his
//    gyroid and strut files carried no painted supports and no print settings. Now every print file job asks for a 3MF:
//      * the job asks for it (RED CONTROL: release 20's job has no `file_format` for a cell lattice);
//      * made for real here (core's run_file_job through the bridge, the iPad's own route) on core's own §16b part — a block
//        with a solid tab whose underside is over air — the file is a 3MF whose painted triangles are the tab's underside, as
//        many as the report says; Results reads it as it read the STL (each triangle its own corners); the Checks say 3MF;
//        Results' Export hands out that 3MF itself (RED CONTROL: release 20's job makes an STL there: no paint, an .stl out).
//
// 2. ONE IN-PROCESS SOLVE AT A TIME (TOReview 11-25: the solver's switches are process-wide, and the squish sim's posture turns
//    GenEO and recycling off around its solves while a topology run arms them). The app's gate (FlexibleCoreGate) already held
//    a squish sim and a LOCAL topology run apart; core's Flexible runner (FlexibleCoreRun) now takes it too, and each side
//    that waits says so in plain words:
//      * a topology run on this iPad holds a Flexible solve back (core's Flexible runner, a squish sim) — the step, the pill
//        and the player say "Waiting for the run…" — and it goes the moment the run ends (RED CONTROL: no claim, it runs
//        beside the run);
//      * a Flexible solve holds a local topology run back — its card says "Waiting for Flexible to finish" (the print file's
//        card too) — and it starts the moment the solve ends (RED CONTROL: no claim, it starts beside it);
//      * a run on a Mac never takes the gate: it starts beside a Flexible solve, and a Flexible solve starts beside it
//        (POSITIVE CONTROL: the same run made locally waits).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes29ThreeMFGateTests: XCTestCase {

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }

    override func setUp() async throws {
        addTeardownBlock { @MainActor in
            LatticeFileJob.controlOrganicOnly3MF = false
            FlexibleCoreGate.shared.controlOthersDoNotClaim = false
            FlexibleCoreGate.shared.controlFlexibleRunDoesNotClaim = false
            PrintFileKeep.open = nil
        }
    }

    // MARK: 1 · the print file is a 3MF

    func testEveryPrintFileJobAsksForA3MF() throws {
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        func job(_ data: Data) throws -> [String: Any] { try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any]) }
        let cells = try job(LatticeFileJob.build(s, modelName: "part.step"))
        XCTAssertEqual(cells["file_format"] as? String, "3mf", "★ a cell lattice's print file job asks for a 3MF")
        let checked = try job(LatticeFileJob.build(s, modelName: "part.step", strengthJob: LatticeFileJob.strengthJobName))
        XCTAssertEqual(checked["file_format"] as? String, "3mf", "★ with the strength check too")
        let standing = try job(LatticeFileJob.build(s, modelName: "part.step", printFrameUp: SIMD3(0, 1, 0)))
        XCTAssertEqual(standing["file_format"] as? String, "3mf", "★ and standing on a face he chose (Check strength's job)")
        XCTAssertEqual(cells["output"] as? String, LatticeFileJob.outputName, "the job's own name (core writes the 3MF in its place)")
        // RED CONTROL: release 20's job — no format for a cell lattice (core's default: an STL)
        LatticeFileJob.controlOrganicOnly3MF = true
        let before = try job(LatticeFileJob.build(s, modelName: "part.step"))
        LatticeFileJob.controlOrganicOnly3MF = false
        XCTAssertNil(before["file_format"], "RED CONTROL: release 20 left a cell lattice to core's STL")
        print("NOTES29-3MF JOB: cells \(cells["file_format"] ?? "none") · checked \(checked["file_format"] ?? "none") · "
              + "standing \(standing["file_format"] ?? "none") · release 20 \(before["file_format"] ?? "none (STL)")")
    }

    /// The model part of core's 3MF as text.
    static func modelText(_ file: Data) throws -> String {
        let b = [UInt8](file)
        let e = try CoreThreeMF.modelEntry(b)
        var out = [UInt8]()
        if e.method == 0 {
            out = Array(b[e.start..<(e.start + e.size)])
        } else {
            try CoreThreeMF.inflate(b[e.start..<(e.start + e.csize)], expected: e.size) { out.append(contentsOf: $0) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The painted triangles of core's 3MF (their indices, in the file's order).
    static func paintedTriangles(_ file: Data) throws -> [Int] {
        var painted: [Int] = []
        var t = 0
        // (core ends each line with "\r\n": one Character in Swift, so split on any newline)
        for line in try modelText(file).split(whereSeparator: \.isNewline) where line.contains("<triangle ") {
            if line.contains("paint_supports=\"4\"") && line.contains("slic3rpe:custom_supports=\"4\"") { painted.append(t) }
            t += 1
        }
        return painted
    }

    /// ★ For real, on this device's route (core's run_file_job through the bridge): core's §16b part (test_lattice_strength.cpp)
    /// — a 40 × 10 × 20 mm block with a solid tab standing 6 mm out of its y = 10 face at the top (x 15–25, z 16–20), its
    /// underside over air — octet cells under the top face. The tab's overhang is the part's own: core paints it in a 3MF.
    func testACellLatticeFileMadeHereIsA3MFPaintedUnderThePartsOverhangAndExportHandsItOut() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notes29-3mf-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("tab.stl")
        try LatticePlaceChipsTests.gridSTL([0, 15, 25, 40], [0, 10, 16], [0, 16, 20]) { i, j, k in j == 0 || (i == 1 && k == 1) }
            .write(to: model)
        let mesh = try TopOptKit.importMesh(path: model.path)
        let top = try XCTUnwrap(LatticePlaceChipsTests.face(mesh, axis: 2, sign: 1, at: 20), "the top")
        var s = LatticeLayoutSession.Settings()
        s.minStrutLines = 2
        s.regions = [.init(id: 1, faces: [top], depthMM: 14, expandMM: -2)]
        s.topology = "octet"
        s.algorithm = "uniform"
        s.cellMaxMM = 8
        s.minCellsAcross = 1
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let materials = core.appendingPathComponent("src/materials/materials.json").path
        let rules = core.appendingPathComponent("src/settings/rules.json").path
        let store = ProjectStore(rootDir: dir.appendingPathComponent("store", isDirectory: true))

        /// The Lattice button's run on this iPad for version `id` (its folder holds a project), its result, and the print
        /// file Results' Export hands out.
        func made(_ name: String) throws -> (o: OptimizeOutcome, report: [String: Any], out: URL?, id: PrintFileKeep.Identity?) {
            let id = UUID()
            let folder = store.rootDir.appendingPathComponent(id.uuidString, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))
            let job = LatticeFileJob.ForPart(json: try LatticeFileJob.build(s, modelName: "tab.stl"), modelPath: model.path, demand: nil)
            let run = LatticeFileButton.deviceRunner(job: job, strengthJob: nil, materialsPath: materials, rulesPath: rules,
                                                     densityGCm3: 1.24)
            let req = RunRequest(modelPath: model.path, material: "PLA", materialsPath: materials, rulesPath: rules, resolution: 64,
                                 projectName: "Tab", projectID: id, jobMode: LatticeFileButton.jobMode)
            let t0 = Date()
            let o = try run(req, { _, _, _ in true }, { _ in })
            let report = try XCTUnwrap(o.reportJSON.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            print(String(format: "NOTES29-3MF %@: %@ %d bytes in %.1f s", name, report["file"] as? String ?? "?",
                         (report["file_bytes"] as? NSNumber)?.intValue ?? 0, Date().timeIntervalSince(t0)))
            // the version's result saved (AppModel.writeResults): its print file kept beside it, then Export
            PrintFileKeep.keep(projectID: id, outcomes: [o], store: store)
            let ident = PrintFileKeep.identity(of: o)
            PrintFileKeep.open = { (id, store) }
            defer { PrintFileKeep.open = nil }
            return (o, report, PrintFileKeep.openFile(ident, named: "Tab-PLA-\(name)"), ident)
        }

        let now = try made("now")
        let r = try XCTUnwrap(LatticeFileReport.parse(try XCTUnwrap(now.o.reportJSON)))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.fileName, "lattice.3mf", "★ core wrote a 3MF and named it")
        XCTAssertTrue(r.isThreeMF)
        XCTAssertNil(r.weaveMesh, "a cell lattice (no tubes)")
        // the overhang core found and what it painted
        let p = try XCTUnwrap(now.report["painted"] as? [String: Any], "the report's painted block (the part overhangs)")
        let places = (p["places"] as? NSNumber)?.intValue ?? 0, paintedN = (p["triangles"] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(places, 0, "premise: the tab's underside is the part's own overhang")
        XCTAssertGreaterThan(paintedN, 0, "★ painted")
        XCTAssertEqual(PrintOrientationWords.supportsWord(report: now.report), "painted", "★ the orientation row's word")
        // Export: the print file itself, a 3MF, named for the result
        let out = try XCTUnwrap(now.out, "★ Export hands out the print file kept with the version")
        XCTAssertEqual(out.lastPathComponent, "Tab-PLA-now.3mf")
        let file = try Data(contentsOf: out)
        XCTAssertEqual(file.count, (now.report["file_bytes"] as? NSNumber)?.intValue, "the print file, byte for byte")
        let painted = try Self.paintedTriangles(file)
        XCTAssertEqual(painted.count, paintedN, "★ the file carries every painted triangle the report counts")
        // …and they are the tab's underside: facing down, out past the block (y > 10, over air), at the tab's z = 16
        let m = try CoreThreeMF.mesh(file)
        func corner(_ i: Int32) -> SIMD3<Float> { let k = Int(i) * 3; return SIMD3(m.vertices[k], m.vertices[k + 1], m.vertices[k + 2]) }
        var underTab = 0, elsewhere: [String] = []
        for t in painted {
            let a = corner(m.indices[3 * t]), b = corner(m.indices[3 * t + 1]), c = corner(m.indices[3 * t + 2])
            let n = simd_normalize(simd_cross(b - a, c - a)), mid = (a + b + c) / 3
            if n.z < -0.5, mid.y > 9.9, mid.x > 14.9, mid.x < 25.1, abs(mid.z - 16) < 0.6 { underTab += 1 }
            else { elsewhere.append(String(format: "(%.2f, %.2f, %.2f) n.z %.2f", mid.x, mid.y, mid.z, n.z)) }
        }
        print("NOTES29-3MF painted: \(places) places, \(paintedN) triangles in the report, \(painted.count) in the file, "
              + "\(underTab) under the tab, elsewhere \(elsewhere.prefix(5))")
        XCTAssertGreaterThan(underTab, 0, "★ paint where the part overhangs")
        XCTAssertTrue(elsewhere.isEmpty, "never anywhere else (the bed, the lattice): \(elsewhere.prefix(5))")
        // Results reads it as it read the STL: each triangle its own corners (crisp faces), the same triangles
        let v = try XCTUnwrap(now.o.variants.first)
        XCTAssertEqual(v.meshIndices.count, m.indices.count, "the file's triangles")
        XCTAssertEqual(v.meshVertices.count, 3 * v.meshIndices.count, "★ unshared, as the STL read (Results' flat faces)")
        // the Checks and Results name it
        let facts = try XCTUnwrap(LatticeFileFacts.decode(now.report))
        XCTAssertEqual(facts.checks.first { $0.title == "Print file ready" }?.detail.hasPrefix("3MF"), true, "★ \"Print file ready · 3MF\"")
        XCTAssertEqual(ResultsModel(projectName: "Tab", outcome: now.o).printFileIdentity, now.id, "Results knows its print file")

        // RED CONTROL: release 20's job (no format for a cell lattice) — core's STL: the overhang found, nothing painted, an .stl out
        LatticeFileJob.controlOrganicOnly3MF = true
        let before = try made("before")
        LatticeFileJob.controlOrganicOnly3MF = false
        let rb = try XCTUnwrap(LatticeFileReport.parse(try XCTUnwrap(before.o.reportJSON)))
        let pb = before.report["painted"] as? [String: Any]
        print("NOTES29-3MF control (release 20's job): \(rb.fileName), painted \(pb?["triangles"] ?? "none") of "
              + "\(pb?["places"] ?? 0) places, Export \(before.out?.lastPathComponent ?? "none")")
        XCTAssertEqual(rb.fileName, "lattice.stl", "RED CONTROL: core's STL")
        XCTAssertFalse(rb.isThreeMF)
        XCTAssertEqual((pb?["triangles"] as? NSNumber)?.intValue ?? 0, 0, "RED CONTROL: an STL carries no paint")
        XCTAssertEqual(before.out?.pathExtension, "stl", "RED CONTROL: Export handed out an STL")
        XCTAssertEqual(try XCTUnwrap(LatticeFileFacts.decode(before.report)).checks.first { $0.title == "Print file ready" }?
            .detail.hasPrefix("STL"), true)
    }

    // MARK: 2 · one in-process solve at a time

    final class WatchdogSpy: RunWatchdog, @unchecked Sendable {
        var graceSeconds: Double { 150 }
        func arm(_ onStall: @escaping () -> Void) -> RunWatchdogCancel { {} }
    }
    struct Done: Error {}
    static var request: RunRequest {
        RunRequest(modelPath: "/tmp/none.stl", material: "PLA", materialsPath: "", rulesPath: "", resolution: 8, projectName: "P")
    }

    /// A topology run (local or on a Mac) that stays in its runner until `release`, saying whether a Flexible solve held core
    /// beside it.
    func run(remote: Bool, release: Box<Bool>, started: Box<Bool>, overlap: Box<Bool>) -> RunModel {
        let model = RunModel(scheduler: GCDRunScheduler(), watchdog: WatchdogSpy(), runner: { _, _, _ in
            started.value = true
            repeat {
                if FlexibleCoreGate.shared.flexibleInCore { overlap.value = true }
                if release.value { break }
                usleep(2000)
            } while true
            throw Done()
        })
        model.start(Self.request, remote: remote)
        return model
    }

    /// Core's Flexible runner, standing in: stays in core until `release`, saying whether a local run held core beside it.
    func flexibleRun(release: Box<Bool>, started: Box<Bool>, overlap: Box<Bool>) -> FlexibleCoreRun {
        let f = FlexibleCoreRun()
        f.runner = { _, _, _, _ in
            started.value = true
            repeat {
                if FlexibleCoreGate.shared.runsInCore > 0 { overlap.value = true }
                if release.value { break }
                usleep(2000)
            } while true
            return FlexRunInfo(refusal: nil, receiptJSON: "{\"faces\":[{}],\"topology\":\"gyroid\"}", files: [])
        }
        return f
    }

    func testATopologyRunOnThisIPadHoldsAFlexibleSolveBackAndSaysWhy() async throws {
        let gate = FlexibleCoreGate.shared
        for control in [false, true] {
            gate.controlFlexibleRunDoesNotClaim = control
            let release = Box(false), runStarted = Box(false), runOverlap = Box(false)
            let topo = run(remote: false, release: release, started: runStarted, overlap: runOverlap)
            try await FlexibleBatchCVerifyTests.settle(10) { runStarted.value && gate.runsInCore == 1 }
            // the Flexible step sends its job while the run holds core
            let fRelease = Box(true), fStarted = Box(false), fOverlap = Box(false)
            let f = flexibleRun(release: fRelease, started: fStarted, overlap: fOverlap)
            f.startForTests("{\"job\": \(control)}")
            try await Task.sleep(nanoseconds: 600_000_000)
            let heldBack = !fStarted.value, waiting = f.waitingForRun, line = f.line
            let pill = FlexibleMainStatus(line: FlexibleMainStatus.ready, tone: .ready, fix: nil)
                .whileSending(f.isSending, waiting: f.waitingForRun).line
            let corner = FlexibleLatticeButton.line(FlexibleMainStatus(line: FlexibleMainStatus.ready, tone: .ready, fix: nil),
                                                    state: .sending, runLine: f.line)
            // a squish sim is held back too (it never claims while a run holds or waits for core)
            let simClaimed = gate.tryEnterSim()
            if simClaimed { gate.leaveSim() }
            release.value = true
            try await FlexibleBatchCVerifyTests.settle(10) { !f.isSending }
            try await FlexibleBatchCVerifyTests.settle(10) { topo.phase != .running }
            print("NOTES29-GATE run holds core\(control ? " (control: no claim)" : ""): Flexible send held back \(heldBack) · "
                  + "says \"\(line)\" · pill \"\(pill)\" · corner \"\(corner)\" · sim claimed \(simClaimed) · "
                  + "it ran beside the run \(fOverlap.value) · then \(f.line)")
            if control {
                XCTAssertFalse(heldBack, "RED CONTROL: no claim — core's Flexible runner starts beside the run")
                XCTAssertTrue(fOverlap.value, "RED CONTROL: two solves in the process at once")
            } else {
                XCTAssertTrue(heldBack, "★ the Flexible send waits while a topology run holds core")
                XCTAssertTrue(waiting)
                XCTAssertEqual(line, FlexibleCoreRun.waitingLine, "★ the step says it waits, in plain words")
                XCTAssertEqual(pill, FlexibleCoreRun.waitingLine, "★ …and the pill")
                XCTAssertEqual(corner, FlexibleCoreRun.waitingLine, "★ …and the corner")
                XCTAssertFalse(simClaimed, "★ a squish sim does not claim core either")
                XCTAssertTrue(fStarted.value, "★ it went once the run ended")
                XCTAssertFalse(fOverlap.value, "never beside the run")
                XCTAssertFalse(f.waitingForRun)
                guard case .ran = f.phase else { return XCTFail("core's answer landed: \(f.phase)") }
            }
            XCTAssertLessThanOrEqual(FlexibleCoreRun.waitingLine.count, 22, "a short line (the player's width)")
        }
        gate.controlFlexibleRunDoesNotClaim = false
    }

    /// The squish sims of the pad, held back by a local run: the solver says so, the page's note reads "Waiting for the run…".
    func testASquishSimHeldBackByARunSaysWaitingForTheRun() async throws {
        let pad = try await FlexibleSquishFixture.pad(self, solve: false)
        let r = try XCTUnwrap(pad.lastFERequest)
        let ref = await pad.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        pad.latticeLanded(r)
        let claim = FlexibleCoreGate.claimForRun()
        let before = pad.squishSolver.solveCount
        pad.squishSolver.schedule(r, scene: scene, first: nil)
        try await FlexibleBatchCVerifyTests.settle(5) { pad.squishHeldByRun }
        let held = pad.squishHeldByRun, during = pad.squishSolver.solveCount - before
        claim.leave()
        try await FlexibleBatchCVerifyTests.settle(30) { !pad.squishHeldByRun && pad.squishSolver.solveCount > before }
        await pad.squishSolver.waitForIdle()
        // the page's note (FlexibleMainStage.feNote) from its FE view
        let stage = FlexibleMainStage()
        stage.fe.pending = true
        stage.fe.heldByRun = true
        let waitingNote = stage.feNote
        stage.fe.heldByRun = false
        let simulatingNote = stage.feNote
        print("NOTES29-GATE sims: held by the run \(held) (sims started meanwhile \(during)) · note \"\(waitingNote ?? "")\" · "
              + "control (not held) \"\(simulatingNote ?? "")\" · after the run: held \(pad.squishHeldByRun)")
        XCTAssertTrue(held, "★ the solver says a local run holds the sims back")
        XCTAssertEqual(during, 0, "no sim beside the run")
        XCTAssertEqual(waitingNote, FlexibleFE.waitingForRun, "★ the player says it waits for the run")
        XCTAssertEqual(simulatingNote, FlexibleFE.pending, "RED CONTROL: not held — \"Simulating the squish…\" as before")
        XCTAssertFalse(pad.squishHeldByRun, "the note goes once the run ended")
        // a Stress solve (not a run) holding core is not "the run"
        let other = FlexibleCoreGate.shared
        other.enterOther()
        XCTAssertFalse(other.runHoldsCore, "a Stress solve is not a topology run")
        other.leaveOther()
    }

    func testAFlexibleSolveHoldsALocalRunBackAndItsCardSaysSo() async throws {
        let gate = FlexibleCoreGate.shared
        for control in [false, true] {
            gate.controlOthersDoNotClaim = control
            let fRelease = Box(false), fStarted = Box(false), fOverlap = Box(false)
            let f = flexibleRun(release: fRelease, started: fStarted, overlap: fOverlap)
            f.startForTests("{\"hold\": \(control)}")
            try await FlexibleBatchCVerifyTests.settle(10) { fStarted.value && gate.flexibleRunsInCore == 1 }
            let release = Box(true), started = Box(false), overlap = Box(false)
            let topo = run(remote: false, release: release, started: started, overlap: overlap)
            // the print file's card on this iPad reads the same wait
            let card = LatticeMacMake()
            card.begin(project: UUID(), path: nil, run: topo, fileOnly: true, kind: .cells, onMac: false, cancel: {})
            try await Task.sleep(nanoseconds: 600_000_000)
            let heldBack = !started.value, waiting = topo.waitingForFlexible, stage = card.stage
            let step = RunCardWords.step(LatticeFileButton.jobMode, RunProgress(rung: 0, rungCount: 1, iteration: 0),
                                         waitingForFlexible: topo.waitingForFlexible)
            fRelease.value = true
            try await FlexibleBatchCVerifyTests.settle(10) { topo.phase != .running }
            try await FlexibleBatchCVerifyTests.settle(10) { !f.isSending }
            let after = card.stage
            card.ended()
            print("NOTES29-GATE Flexible holds core\(control ? " (control: no claim)" : ""): local run held back \(heldBack) · "
                  + "card says \"\(step ?? "")\" · print file card \"\(stage)\" → \"\(after)\" · ran beside it \(overlap.value)")
            if control {
                XCTAssertFalse(heldBack, "RED CONTROL: no claim — the run starts beside the Flexible solve")
                XCTAssertTrue(overlap.value)
            } else {
                XCTAssertTrue(heldBack, "★ a local topology run waits while a Flexible solve holds core")
                XCTAssertTrue(waiting)
                XCTAssertEqual(step, RunCardWords.waitingForFlexible, "★ its card says it waits, in plain words")
                XCTAssertEqual(stage, RunCardWords.waitingForFlexible, "★ …and the print file's card on this iPad")
                XCTAssertEqual(after, LatticeMacMakeCopy.makingFile, "then its own step again")
                XCTAssertTrue(started.value, "★ it started once the Flexible solve ended")
                XCTAssertFalse(overlap.value, "never beside it")
                XCTAssertFalse(topo.waitingForFlexible)
            }
            XCTAssertLessThanOrEqual(RunCardWords.waitingForFlexible.split(separator: " ").count, 5, "his rule: five words")
        }
        gate.controlOthersDoNotClaim = false
    }

    func testARunOnAMacNeverTakesTheGate() async throws {
        let gate = FlexibleCoreGate.shared
        // a Flexible solve holds core: a Mac run starts at once (POSITIVE CONTROL: a local one waits)
        let fRelease = Box(false), fStarted = Box(false), fOverlap = Box(false)
        let f = flexibleRun(release: fRelease, started: fStarted, overlap: fOverlap)
        f.startForTests("{\"mac\": 1}")
        try await FlexibleBatchCVerifyTests.settle(10) { fStarted.value }
        let macRelease = Box(true), macStarted = Box(false), macOverlap = Box(false)
        let mac = run(remote: true, release: macRelease, started: macStarted, overlap: macOverlap)
        try await FlexibleBatchCVerifyTests.settle(5) { macStarted.value }
        let localRelease = Box(true), localStarted = Box(false), localOverlap = Box(false)
        let local = run(remote: false, release: localRelease, started: localStarted, overlap: localOverlap)
        try await Task.sleep(nanoseconds: 500_000_000)
        let localHeld = !localStarted.value
        fRelease.value = true
        try await FlexibleBatchCVerifyTests.settle(10) { local.phase != .running && mac.phase != .running && !f.isSending }
        // a Mac run in progress: a Flexible solve starts at once
        let release = Box(false), started = Box(false), overlap = Box(false)
        let mac2 = run(remote: true, release: release, started: started, overlap: overlap)
        try await FlexibleBatchCVerifyTests.settle(5) { started.value }
        let g2Release = Box(true), g2Started = Box(false), g2Overlap = Box(false)
        let f2 = flexibleRun(release: g2Release, started: g2Started, overlap: g2Overlap)
        f2.startForTests("{\"mac\": 2}")
        try await FlexibleBatchCVerifyTests.settle(5) { g2Started.value }
        let notWaiting = !f2.waitingForRun, runsHeld = gate.runsInCore
        release.value = true
        try await FlexibleBatchCVerifyTests.settle(10) { mac2.phase != .running && !f2.isSending }
        print("NOTES29-GATE Mac: a Mac run beside a Flexible solve started \(macStarted.value) (waiting \(mac.waitingForFlexible)) · "
              + "control, a local run held \(localHeld) · a Flexible solve beside a Mac run started \(g2Started.value) "
              + "(local runs in core \(runsHeld))")
        XCTAssertTrue(macStarted.value, "★ a run on a Mac starts beside a Flexible solve")
        XCTAssertTrue(macOverlap.value, "(it ran while the Flexible solve held core)")
        XCTAssertFalse(mac.waitingForFlexible)
        XCTAssertTrue(localHeld, "POSITIVE CONTROL: the same run made on this iPad waits")
        XCTAssertTrue(g2Started.value, "★ a Flexible solve starts beside a run on a Mac")
        XCTAssertTrue(notWaiting)
        XCTAssertEqual(runsHeld, 0, "a Mac run holds nothing of this process's core")
    }
}
#endif
