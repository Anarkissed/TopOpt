// RedesignToStrengthenTests — Flexible (PR #362) H56: redesign to strengthen (overnight plan 2026-10-25).
//
// TO-core's item 50 (62e909b6): `loads.redesign: "strengthen"`, sent with the design box, rebuilds the part in
// its box as three versions; report.json carries a top-level `strengthen` block and per-variant `bodies`
// (items 41 / 47 / 42-B). Pinned here:
//   (1) the worker send carries loads.redesign "strengthen" + the design box, and nothing else changes;
//   (2) the cards' text for each of TO-core's REAL evidence reports (Fixtures/strengthen_reports/, copied verbatim
//       from reviewer-inbox/2026-10-25-integration-evidence: core outputs at e9205b34 on committed fixtures);
//   (3) item 47's rejection in plain words, from the README's exact shape (Fixtures/strengthen_reports/
//       anchored_detached_readme_shape: rejected_margin_bridge_held's report with rejected_variants[0] set to
//       "anchored piece detached", anchored_pieces_lost 1, lost_anchor_face_ids [13], bridge_holds
//       [{3.75, 1.21, 3, false}] — no real report carries it yet, README "Not in any real report yet");
//   (4) on device the strengthen choice is disabled with ONE line, "Runs on your Mac";
//   (5) the report reaches the results screen (OptimizeOutcome.reportJSON → ResultsModel);
//   (6) every H56 hook in a shared file, pinned once with its gate, and a red control.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RedesignToStrengthenTests: XCTestCase {

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/strengthen_reports", isDirectory: true)

    static func reportData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent(name).appendingPathComponent("report.json"))
    }

    static func blocks(_ name: String) throws -> RunReportBlocks {
        try XCTUnwrap(RunReportBlocks.decode(reportJSON: try reportData(name)), name)
    }

    static let box = TopOptKit.DesignBoxSpec(min: SIMD3(-5, -5, 0), max: SIMD3(45, 15, 30))

    static func request(minimizePlastic: Bool, box: TopOptKit.DesignBoxSpec?,
                        jobMode: String = "minimize_plastic") -> RunRequest {
        RunRequest(modelPath: "/tmp/bar.step", material: "PLA", materialsPath: "", rulesPath: "",
                   resolution: 32, projectName: "bar", anchorFaceIDs: [1],
                   loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [2], force: SIMD3(0, 0, -50))],
                   minimizePlastic: minimizePlastic, designBox: box, jobMode: jobMode)
    }

    static func jobData(_ r: RunRequest) throws -> Data { try RemoteRun.buildJobJSON(r) }

    /// The job's bytes with sorted keys: JSONSerialization's key order is not stable between two dictionaries.
    static func canonical(_ r: RunRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: try job(r), options: [.sortedKeys])
    }

    static func job(_ r: RunRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try jobData(r)) as? [String: Any])
    }

    // MARK: (1) the send

    func testTheWorkerSendCarriesRedesignStrengthenAndTheDesignBox() throws {
        let job = try Self.job(Self.request(minimizePlastic: false, box: Self.box).forWorker())
        let loads = try XCTUnwrap(job["loads"] as? [String: Any])
        XCTAssertEqual(loads["redesign"] as? String, "strengthen", "the worker send asks core for the strengthen redesign")
        XCTAssertEqual(loads["minimize_plastic"] as? Bool, false, "core refuses strengthen without minimize_plastic false")
        let box = try XCTUnwrap(job["design_box"] as? [String: Any], "core refuses strengthen without a design box")
        XCTAssertEqual(box["min"] as? [Double], [-5, -5, 0])
        XCTAssertEqual(box["max"] as? [Double], [45, 15, 30])
        XCTAssertEqual(job["mode"] as? String, "minimize_plastic")
    }

    func testEveryOtherRequestShipsNoRedesignKeyAndTheSameBytes() throws {
        let cases: [(String, RunRequest)] = [
            ("minimize plastic", Self.request(minimizePlastic: true, box: Self.box)),
            ("strengthen without a box", Self.request(minimizePlastic: false, box: nil)),
            ("the lattice run", Self.request(minimizePlastic: false, box: Self.box, jobMode: "lattice_part")),
            ("minimize plastic, no box", Self.request(minimizePlastic: true, box: nil)),
        ]
        for (name, r) in cases {
            let loads = try XCTUnwrap(try Self.job(r.forWorker())["loads"] as? [String: Any])
            XCTAssertNil(loads["redesign"], "\(name): no redesign key")
            XCTAssertEqual(try Self.canonical(r.forWorker()), try Self.canonical(r), "\(name): the same job")
        }
        // On device the request is never forWorker()'d: the strengthen request as built carries no key.
        let onDevice = try XCTUnwrap(try Self.job(Self.request(minimizePlastic: false, box: Self.box))["loads"] as? [String: Any])
        XCTAssertNil(onDevice["redesign"], "an on-device request carries no redesign key")
        XCTAssertEqual(Self.request(minimizePlastic: false, box: Self.box).redesign, "")
    }

    // MARK: (2) the cards, on TO-core's real reports

    func testStrengthenPassCards() throws {
        let b = try Self.blocks("strengthen_pass")
        let s = try XCTUnwrap(b.strengthen)
        XCTAssertEqual(s.asDrawnMargin, 5.936930304, accuracy: 1e-9)
        XCTAssertEqual(s.ceilingMargin, 11.95101129, accuracy: 1e-9)
        XCTAssertEqual(s.marginRequired, 1.5)
        XCTAssertEqual(s.originalMassGrams, 4.96)
        XCTAssertEqual(s.coarseResolution, 32)
        let unreachable = "above 0.95 x the box filled solid (margin 11.95): unreachable in this design space"
        XCTAssertEqual(StrengthenText.cards(b), [
            StrengthenCard(title: "Version 1 · 25 % less worst stress", status: "Verified",
                           lines: ["Margin 11.71×", "8.2 g · 166 % of the original"], bridged: false),
            StrengthenCard(title: "Version 2 · 50 % less worst stress", status: "Unreachable",
                           lines: [unreachable], bridged: false),
            StrengthenCard(title: "Version 3 · 75 % less worst stress", status: "Unreachable",
                           lines: [unreachable], bridged: false),
        ])
        XCTAssertEqual(StrengthenText.rejectionLines(b), [])
    }

    func testStrengthenFailCards() throws {
        let b = try Self.blocks("strengthen_fail")
        XCTAssertEqual(b.rows, [], "no variant: every version unreachable")
        let reason = "above 0.95 x the box filled solid (margin 0.1992): unreachable in this design space"
        XCTAssertEqual(StrengthenText.cards(b), [
            StrengthenCard(title: "Version 1 · 25 % less worst stress", status: "Unreachable", lines: [reason], bridged: false),
            StrengthenCard(title: "Version 2 · 50 % less worst stress", status: "Unreachable", lines: [reason], bridged: false),
            StrengthenCard(title: "Version 3 · 75 % less worst stress", status: "Unreachable", lines: [reason], bridged: false),
        ])
    }

    func testBridgedHeldVariantsReadBridged() throws {
        let b = try Self.blocks("bridged_held")
        XCTAssertNil(b.strengthen, "a reduction ladder: no strengthen block, no cards")
        XCTAssertEqual(StrengthenText.cards(b), [])
        let bridged = b.rows.filter { ($0.bodies?.bridges ?? 0) > 0 }
        XCTAssertEqual(bridged.count, 2, "the 0.38 and 0.26 rungs were bridged")
        XCTAssertEqual(bridged.first?.bodies?.bridgeHolds, [BridgeHold(sizeMM: 3.75, holdMargin: 80.47723551, thickenings: 0, held: true)])
        for r in b.rows where r.accepted {
            XCTAssertEqual(StrengthenText.isBridged(printedFraction: r.printedFraction, in: b), (r.bodies?.bridges ?? 0) > 0,
                           "vf \(r.volumeFraction)")
        }
        XCTAssertEqual(StrengthenText.rejectionLines(b), [])
    }

    func testRejectedOnMarginWithAHeldBridgeIsNotItem47() throws {
        let b = try Self.blocks("rejected_margin_bridge_held")
        let rejected = try XCTUnwrap(b.rows.first { !$0.accepted })
        XCTAssertEqual(rejected.rejectionReason, "margin below required")
        XCTAssertEqual(rejected.bodies?.bridgeHolds.first?.holdMargin ?? 0, 3.713187376, accuracy: 1e-9)
        XCTAssertEqual(rejected.bodies?.bridgeHolds.first?.held, true)
        XCTAssertEqual(StrengthenText.rejectionLines(b), [], "a margin rejection is not 'let go of an anchored bolt hole'")
        XCTAssertFalse(StrengthenText.isBridged(printedFraction: rejected.printedFraction, in: b),
                       "a rejected rung has no tab to badge")
    }

    // MARK: (3) item 47, in plain words

    func testAnAnchoredPieceDetachedReadsInPlainWordsWithNoFaceNumber() throws {
        let b = try Self.blocks("anchored_detached_readme_shape")
        let rejected = try XCTUnwrap(b.rows.first { !$0.accepted })
        XCTAssertEqual(rejected.bodies?.lostAnchorFaceIDs, [13], "parsed")
        XCTAssertEqual(rejected.bodies?.bridgeHolds, [BridgeHold(sizeMM: 3.75, holdMargin: 1.21, thickenings: 3, held: false)])
        let lines = StrengthenText.rejectionLines(b)
        XCTAssertEqual(lines, ["This version let go of an anchored bolt hole"])
        XCTAssertFalse(lines.joined().contains("13"), "no face number in user-facing text")
    }

    func testNoFaceNumberReachesALine() throws {
        let cap = try XCTUnwrap(try Self.blocks("strengthen_pass").strengthen?.cap)
        XCTAssertEqual(cap.faceID, 1)
        XCTAssertTrue(cap.atAnchorFace)
        XCTAssertTrue(cap.note.contains("face 1"), "core's cap note names a face, so it is never printed raw")
        XCTAssertEqual(StrengthenText.plain("peaks at (0.6, 0.6, 10.6) mm, on face 1, at the edge"),
                       "peaks at (0.6, 0.6, 10.6) mm, on a face, at the edge")
        XCTAssertEqual(StrengthenText.plain("anchors on faces 3, 7 and 12 let go"), "anchors on a face let go")
        for name in ["strengthen_pass", "strengthen_fail"] {
            let text = StrengthenText.cards(try Self.blocks(name)).flatMap { [$0.title, $0.status] + $0.lines }.joined(separator: "\n")
            XCTAssertFalse(text.lowercased().contains("face"), "\(name): \(text)")
        }
    }

    // MARK: (4) on device: ONE line

    func testOnDeviceTheStrengthenChoiceIsDisabledWithTheOneLine() {
        XCTAssertFalse(StrengthenRoute.canChoose(workerSelected: false))
        XCTAssertEqual(StrengthenRoute.line(workerSelected: false), "Runs on your Mac")
        XCTAssertEqual(StrengthenRoute.onDeviceToast, "Redesign to strengthen: Runs on your Mac")
        XCTAssertTrue(StrengthenRoute.canChoose(workerSelected: true))
        XCTAssertNil(StrengthenRoute.line(workerSelected: true), "on the Mac worker there is no line")
    }

    // MARK: (5) the report reaches the results screen

    func testTheOutcomeCarriesTheReportToTheResultsModel() throws {
        let data = try Self.reportData("bridged_held")
        let b = try Self.blocks("bridged_held")
        let bridgedRow = try XCTUnwrap(b.rows.first { $0.accepted && ($0.bodies?.bridges ?? 0) > 0 })
        let plainRow = try XCTUnwrap(b.rows.first { $0.accepted && $0.bodies == nil })
        func v(_ pf: Double) -> OptimizeVariant {
            OptimizeVariant(requestedVolumeFraction: pf, achievedVolumeFraction: pf, massGrams: 1,
                            supportVolumeVoxels: 0, meshTriangleCount: 0, worstCaseMargin: 5,
                            accepted: true, v3Passes: true)
        }
        let o = OptimizeOutcome(variants: [v(plainRow.printedFraction), v(bridgedRow.printedFraction)],
                                stoppedOnMargin: false, cancelled: false, acceptedCount: 2,
                                computedRemotely: true, reportJSON: data)
        XCTAssertEqual(o.withTiming(nil).withSolvedBy("Mac").withLatticeReport(nil).reportJSON, data,
                       "the copies keep the report")
        let m = ResultsModel(projectName: "plate", outcome: o)
        XCTAssertEqual(m.reportBlocks, b)
        XCTAssertEqual(m.tabs.map { m.isBridged($0) }.sorted { !$0 && $1 }, [false, true])
        let strengthen = ResultsModel(projectName: "bar", outcome: OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0,
            computedRemotely: true, reportJSON: try Self.reportData("strengthen_pass")))
        XCTAssertEqual(strengthen.reportBlocks?.strengthen?.versions.count, 3)
        XCTAssertNil(ResultsModel(projectName: "x", outcome: OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0)).reportBlocks,
                     "an on-device outcome carries no report")
    }

    // MARK: (6) the hooks

    struct Hook { let id: String; let file: String; let pin: String; let gate: String }
    static let src = "app/TopOptKit/Sources/"
    static let rm = src + "TopOptFlows/RunModel.swift"
    static let rr = src + "TopOptFlows/RemoteRunner.swift"
    static let tk = src + "TopOptKit/TopOptKit.swift"
    static let res = src + "TopOptFlows/ResultsModel.swift"
    static let rs = src + "TopOptFlows/ResultsScreen.swift"
    static let run = src + "TopOptFlows/RunScreen.swift"
    static let ws = src + "TopOptFlows/WorkspacePlaceholder.swift"
    static let tag = "// Flexible (PR #362) H56"
    static let why = "redesign to strengthen (overnight plan 2026-10-25)"

    static let hooks: [Hook] = [
        Hook(id: "H56a", file: rm, pin: "    public var redesign: String = \"\"   // Flexible (PR #362) H56a: \(why) — loads.redesign; \"\" = no key (StrengthenRoute, RunRequest.forWorker)\n", gate: "public var redesign: String = \"\""),
        Hook(id: "H56b", file: rr, pin: "        if request.redesign == StrengthenRoute.redesignValue { loads[\"redesign\"] = request.redesign }   // Flexible (PR #362) H56b: \(why) — only a worker request carries it (RunRequest.forWorker)\n", gate: "loads[\"redesign\"] = request.redesign"),
        Hook(id: "H56c-data", file: rr, pin: "        let reportJSON = try? JSONSerialization.data(withJSONObject: report)   // Flexible (PR #362) H56c: \(why) — the report rides on the outcome (strengthen, bodies)\n", gate: "JSONSerialization.data(withJSONObject: report)"),
        Hook(id: "H56c-accepted", file: rr, pin: "                                 buildOrientationJSON: buildOrientation, reportJSON: reportJSON)   // Flexible (PR #362) H56c: \(why) — accepted variants\n", gate: "reportJSON: reportJSON)"),
        Hook(id: "H56c-rejected", file: rr, pin: "                             buildOrientationJSON: buildOrientation, reportJSON: reportJSON)   // Flexible (PR #362) H56c: \(why) — report-only rows\n", gate: "reportJSON: reportJSON)"),
        Hook(id: "H56d-sig", file: rr, pin: "                               buildOrientationJSON: Data? = nil, reportJSON: Data? = nil) -> OptimizeOutcome {   // Flexible (PR #362) H56d: \(why)\n", gate: "reportJSON: Data? = nil"),
        Hook(id: "H56d-growth", file: rr, pin: "                        growthLadder: variants.contains { $0.addedMaterial != nil } || reportJSON.flatMap(RunReportBlocks.decode(reportJSON:))?.strengthen != nil,   // Flexible (PR #362) H56d: \(why) — a strengthen run is the strengthen mode (its versions carry no added_material)\n", gate: "?.strengthen != nil"),
        Hook(id: "H56d-pass", file: rr, pin: "                        reportJSON: reportJSON)   // Flexible (PR #362) H56d: \(why)\n", gate: "reportJSON: reportJSON)"),
        Hook(id: "H56e-field", file: tk, pin: "    public let reportJSON: Data?   // Flexible (PR #362) H56e: \(why) — the worker's report.json, for the blocks the app reads by key (strengthen, bodies); nil on device\n", gate: "public let reportJSON: Data?"),
        Hook(id: "H56e-param", file: tk, pin: "                growthLadder: Bool = false, reportJSON: Data? = nil) {   // Flexible (PR #362) H56e: \(why)\n", gate: "reportJSON: Data? = nil"),
        Hook(id: "H56e-assign", file: tk, pin: "        self.reportJSON = reportJSON   // Flexible (PR #362) H56e: \(why)\n", gate: "self.reportJSON = reportJSON"),
        Hook(id: "H56e-solvedBy", file: tk, pin: "                        growthLadder: growthLadder, reportJSON: reportJSON)   // Flexible (PR #362) H56e: \(why) — withSolvedBy keeps it\n", gate: "reportJSON: reportJSON"),
        Hook(id: "H56e-timing", file: tk, pin: "                        growthLadder: growthLadder, reportJSON: reportJSON)   // Flexible (PR #362) H56e: \(why) — withTiming keeps it\n", gate: "reportJSON: reportJSON"),
        Hook(id: "H56e-lattice", file: tk, pin: "                        growthLadder: growthLadder, reportJSON: reportJSON)   // Flexible (PR #362) H56e: \(why) — withLatticeReport keeps it\n", gate: "reportJSON: reportJSON"),
        Hook(id: "H56f-var", file: res, pin: "    public private(set) var reportBlocks: RunReportBlocks?   // Flexible (PR #362) H56f: \(why) — the strengthen cards + bodies (RedesignToStrengthen.swift)\n", gate: "var reportBlocks: RunReportBlocks?"),
        Hook(id: "H56f-apply", file: res, pin: "        if let d = outcome.reportJSON { reportBlocks = RunReportBlocks.decode(reportJSON: d) }   // Flexible (PR #362) H56f: \(why) — a streamed partial (no report) never erases it\n", gate: "reportBlocks = RunReportBlocks.decode(reportJSON: d)"),
        Hook(id: "H56f-bridged", file: res, pin: "    public func isBridged(_ tab: ResultVariantVM) -> Bool { tab.latticeAlternative == nil && accepted.indices.contains(tab.variantIndex) && reportBlocks.map { StrengthenText.isBridged(printedFraction: accepted[tab.variantIndex].printedFraction, in: $0) } == true }   // Flexible (PR #362) H56f: \(why) — bodies.bridges > 0\n", gate: "StrengthenText.isBridged("),
        Hook(id: "H56g-cards", file: rs, pin: "            if let blocks = model.reportBlocks { RunReportCardsView(blocks: blocks) }   // Flexible (PR #362) H56g: \(why) — the versions' cards + item 47's line\n", gate: "RunReportCardsView(blocks: blocks)"),
        Hook(id: "H56g-badge", file: rs, pin: "                            if model.isBridged(tab) { Text(StrengthenText.bridgedBadge).font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(DS.Color.warning.color) }   // Flexible (PR #362) H56g: \(why) — BRIDGED\n", gate: "model.isBridged(tab)"),
        Hook(id: "H56h-blocks", file: run, pin: "                        let blocks = model.outcome?.reportJSON.flatMap(RunReportBlocks.decode(reportJSON:))   // Flexible (PR #362) H56h: \(why)\n", gate: "RunReportBlocks.decode(reportJSON:)"),
        Hook(id: "H56h-if", file: run, pin: "                        if blocks?.strengthen == nil {   // Flexible (PR #362) H56h: \(why) — a strengthen run's cards say what failed (the margin line would read 0.00×)\n", gate: "if blocks?.strengthen == nil {"),
        Hook(id: "H56h-end", file: run, pin: "                        }   // Flexible (PR #362) H56h: \(why) — (the margin line)\n", gate: "}"),
        Hook(id: "H56h-cards", file: run, pin: "                        if let blocks { RunReportCardsView(blocks: blocks) }   // Flexible (PR #362) H56h: \(why) — the versions' cards + item 47's line\n", gate: "RunReportCardsView(blocks: blocks)"),
        Hook(id: "H56i", file: ws, pin: "        run.start(isRemote ? request.forWorker() : request, remote: isRemote, workerName: compute.selectedWorkerName)   // Flexible (PR #362) H56i: \(why) — loads.redesign on the Mac worker only\n", gate: "isRemote ? request.forWorker() : request"),
        Hook(id: "H56j-line", file: ws, pin: "        let macOnly = StrengthenRoute.line(workerSelected: compute.activeRemote != nil)   // Flexible (PR #362) H56j: \(why) — on device: Runs on your Mac\n", gate: "StrengthenRoute.line(workerSelected: compute.activeRemote != nil)"),
        Hook(id: "H56j-tap", file: ws, pin: "        return Button { if project.minimizePlastic, macOnly != nil { model.toast = StrengthenRoute.onDeviceToast; return }; project.minimizePlastic.toggle() } label: {   // Flexible (PR #362) H56j: \(why) — the strengthen choice, disabled on device\n", gate: "model.toast = StrengthenRoute.onDeviceToast; return"),
    ]

    static func source(_ file: String) throws -> String {
        try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent(file), encoding: .utf8)
    }

    /// What is wrong with the H56 hooks ([] = each pin once, its gate in it, and no untracked H56 line).
    static func failures(_ files: [String: String]) -> [String] {
        var out: [String] = []
        for h in hooks {
            let n = (files[h.file] ?? "").components(separatedBy: h.pin).count - 1
            if n != 1 { out.append("\(h.id): the hook appears \(n) times (must be exactly once)") }
            if !h.pin.contains(h.gate) { out.append("\(h.id): its gate is not in it") }
        }
        for (file, text) in files {
            let tagged = text.components(separatedBy: "\n").filter { $0.contains(tag) }.count
            let pinned = hooks.filter { $0.file == file }.count
            if tagged != pinned { out.append("\(file): \(tagged) H56 lines, \(pinned) pinned") }
        }
        return out
    }

    private func files() throws -> [String: String] {
        var f: [String: String] = [:]
        for h in Self.hooks where f[h.file] == nil { f[h.file] = try Self.source(h.file) }
        return f
    }

    func testEveryH56HookIsPinnedOnceWithItsGate() throws {
        XCTAssertEqual(Self.failures(try files()), [])
        XCTAssertEqual(Set(Self.hooks.map { String($0.id.prefix(4)) }), Set(["H56a", "H56b", "H56c", "H56d", "H56e", "H56f", "H56g", "H56h", "H56i", "H56j"]))
    }

    func testAGateRemovedCopyGoesRed() throws {
        let real = try files()
        for h in Self.hooks {
            var f = real
            f[h.file] = f[h.file]!.replacingOccurrences(of: h.pin, with: h.pin.replacingOccurrences(of: h.gate, with: ""))
            XCTAssertFalse(Self.failures(f).isEmpty, "\(h.id): removing its gate must go red")
        }
        var f = real
        f[Self.ws] = f[Self.ws]! + "\n// an untracked line " + Self.tag + "z\n"
        XCTAssertFalse(Self.failures(f).isEmpty, "an untracked H56 line must go red")
    }
}
