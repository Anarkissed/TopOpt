// OrganicBareVinesTests — ★ notes30 (the reviewer's ruling with the owner's approval, 2026-11-26; core OS19, the interim guard):
// the app reads core's `load_on_bare_lattice` wherever it reads the Organic strength result —
//   * the strength block parsed (its load on the vines, the whole load, the share, the place, core's sentence);
//   * Results' Checks line and Details › Strength say what lands where, never a margin;
//   * the certify wizard's ONE pop-up for it (its line to the place, Solve offering both covers), no "struts still short";
//   * the strengthening's stop (rounds_fixed 0) said in core's words;
//   * the two offers on the part: a Solid finish on the loaded face's area, a Protect skin group holding the loaded face;
//   * his rules: the exact sentence (core's own), positive words, five-word captions, the app's own names for the finishes.
// Each assertion that reads core's shape has a RED control (OrganicBareVines.controlUnread: the read before notes30).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class OrganicBareVinesTests: XCTestCase {

    override nonisolated func tearDown() {
        OrganicBareVines.controlUnread = false
        OrganicBareVines.controlSolidFirst = false
        OrganicBareVines.controlNoDepth = false
        super.tearDown()
    }

    // MARK: fixtures (core's own §7c numbers: 0.55 of 0.55 N on the frame, the place (6, 2.5, 0); made-up margins)

    /// A print file's report as core writes it for a load on bare vines (`fail_text` its sentence), the struts' numbers there
    /// (3 short) and margins that, read without the reason, would say "Strong enough". `depth`: core's `solid_depth_needed_mm`
    /// (nil: an older worker's core, no key).
    static func report(bare: Bool = true, failText: Bool = true, depth: Double? = nil) -> [String: Any] {
        var s: [String: Any] = [
            "accepted": false, "verdict": "fail", "safety_margin": 1.5, "voxel_mm": 0.75,
            "struts": ["judged": 400, "under_safety": 3, "smallest_margin": 2.0] as [String: Any],
            "weakest": [["margin": 2.0, "by": "bending", "width_mm": 1.2, "length_mm": 6.0, "at": [1.0, 2.0, 3.0]] as [String: Any]],
            "solid_margin": ["effective": 3.2, "spots": [] as [Any]] as [String: Any],
            "frame": ["load_share": 1.0] as [String: Any],
        ]
        if bare {
            s["fail_reason"] = "load_on_bare_lattice"
            s["load_on_frame_n"] = 0.55; s["load_total_n"] = 0.55; s["load_share"] = 1.0
            s["load_on_lattice_at"] = [6.0, 2.5, 0.0]
            if failText { s["fail_text"] = coreSentence }
            if let depth { s["solid_depth_needed_mm"] = depth }
        } else {
            s["fail_reason"] = "strut_margin"
        }
        return ["layout": ["bars": 400] as [String: Any], "mesh": ["triangles": 1000] as [String: Any], "strength": s]
    }
    static let coreSentence =
        "A load lands on bare vines. Give the loaded face a Solid finish or a protected skin so its strength can be checked."
    static let place = SIMD3<Double>(6, 2.5, 0)

    static var repoRoot: URL { Notes24ResultsTests.repoRoot }

    // MARK: the strength block

    /// ★ The block parsed: the reason, the load on the vines, the whole load, the share, the place and core's sentence; the
    /// print file's line says what lands where (never a margin). RED CONTROL: the read before notes30 knows no such reason.
    func testTheStrengthBlockIsParsed() throws {
        let block = try XCTUnwrap(Self.report()["strength"] as? [String: Any])
        let st = LatticeFileStrength(block: block)
        XCTAssertEqual(st.failReason, .loadOnBareLattice, "★ the reason")
        let b = try XCTUnwrap(st.bareVines, "★ what core said with it")
        XCTAssertEqual(b.onFrameN, 0.55)
        XCTAssertEqual(b.totalN, 0.55)
        XCTAssertEqual(b.share, 1.0)
        XCTAssertEqual(b.at, Self.place, "★ where it lands (the part's own mm)")
        XCTAssertEqual(b.text, Self.coreSentence, "★ core's sentence")
        XCTAssertEqual(st.line, OrganicBareVines.line, "★ the print file's line: what lands where, and the fix")
        XCTAssertFalse(st.line.contains("margin"), "never a margin: \(st.line)")
        XCTAssertNil(st.noPathLine, "a setting fixes it: never the no-path words")
        // no fail_text (an older core's block): the app's copy of the sentence
        let older = LatticeFileStrength(block: try XCTUnwrap(Self.report(failText: false)["strength"] as? [String: Any]))
        XCTAssertEqual(older.bareVines?.text, OrganicBareVines.text)
        // another reason: nothing read
        XCTAssertNil(LatticeFileStrength(block: try XCTUnwrap(Self.report(bare: false)["strength"] as? [String: Any])).bareVines)
        // RED CONTROL: the read before notes30
        OrganicBareVines.controlUnread = true
        let old = LatticeFileStrength(block: block)
        XCTAssertNil(old.failReason, "RED CONTROL: the reason unknown")
        XCTAssertNil(old.bareVines)
        XCTAssertNotEqual(old.line, OrganicBareVines.line, "RED CONTROL: a margin line instead (\(old.line))")
    }

    // MARK: Results

    /// ★ Results' Checks line: "Load on bare vines", its fix in five words, the place lit, core's sentence behind the (i);
    /// Details › Strength: no "Holds" number. RED CONTROL: read as before, the same margins said "Strong enough".
    func testResultsSayWhatLandsWhereNeverAMargin() throws {
        let a = try XCTUnwrap(LatticeStrengthAnswer.decode(report: Self.report()))
        XCTAssertNotNil(a.bareVines)
        XCTAssertFalse(a.holds, "★ never 'holds' while the check refuses to judge it")
        let c = a.check()
        XCTAssertEqual(c.kind, .warn)
        XCTAssertEqual(c.title, OrganicBareVines.title)
        XCTAssertEqual(c.detail, OrganicBareVines.checkDetail)
        XCTAssertEqual(c.places, [Self.place], "★ the place lit on the part")
        XCTAssertEqual(c.info, Self.coreSentence, "★ the sentence behind the (i)")
        XCTAssertEqual(c.tab, .strength)
        let rows = a.rows(loadKg: 5, unit: .kg, infillPercent: 50, plastic: nil)
        XCTAssertFalse(rows.contains { $0.label == "Holds" }, "★ no margin claimed: \(rows.map(\.label))")
        let row = try XCTUnwrap(rows.first { $0.label == OrganicBareVines.rowLabel }, "★ what lands where")
        XCTAssertEqual(row.value, OrganicBareVines.rowValue)
        XCTAssertEqual(row.info, Self.coreSentence)
        // the checks list Results draws
        let tab = try XCTUnwrap(ResultsChecks.checks(tab: try XCTUnwrap(Self.tab()), margin: 2.0, required: 1.5, safetyMargin: 1.5,
                                                     scenarios: [], thinJoints: 0, bridged: false, answer: a).first)
        XCTAssertEqual(tab.title, OrganicBareVines.title, "★ the Checks panel's first line")
        // RED CONTROL: read as before notes30, the same numbers said the part is strong enough
        OrganicBareVines.controlUnread = true
        let old = try XCTUnwrap(LatticeStrengthAnswer.decode(report: Self.report()))
        XCTAssertEqual(old.check().title, "Strong enough", "RED CONTROL: the misleading line this replaces")
        XCTAssertTrue(old.rows(loadKg: 5, unit: .kg, infillPercent: 50, plastic: nil).contains { $0.label == "Holds" })
    }

    /// The print file's result as Results holds it (one variant, the report riding with it).
    static func outcome(depth: Double? = nil) throws -> OptimizeOutcome {
        let v = OptimizeVariant(requestedVolumeFraction: 0.6, achievedVolumeFraction: 0.6, massGrams: 20, supportVolumeVoxels: 0,
                                meshTriangleCount: 1, worstCaseMargin: 2.0, accepted: true, v3Passes: false,
                                meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        return OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
                               gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1, computedRemotely: true,
                               reportJSON: try JSONSerialization.data(withJSONObject: report(depth: depth)))
    }

    static func tab() throws -> ResultVariantVM? { ResultsModel(projectName: "Stand", outcome: try outcome()).selected }

    // MARK: no margin anywhere (362's review, 11-26)

    /// ★ A bare-vines result has no valid margin: everywhere a number like "2.00×" would show, its words do — Results' list row
    /// (and Compare, which reads the row), Details › Strength (no weakest spot, struts short or solid margin), the Library's
    /// card, row and Compare (the summary), the orientation check's columns. RED CONTROL: read as before, the number is back.
    func testNoMarginShowsForABareVinesResult() throws {
        let w = OrganicBareVines.title
        let o = try Self.outcome()
        func assertWords(_ s: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(s.contains(w), "★ \(what) says the words: \(s)", file: file, line: line)
            XCTAssertFalse(s.contains("\u{00D7}"), "★ \(what) shows no margin: \(s)", file: file, line: line)
            XCTAssertFalse(s.contains("\u{2713}"), "★ \(what) shows no tick: \(s)", file: file, line: line)
        }
        XCTAssertEqual(OrganicBareVines.marginWords(reportJSON: o.reportJSON), w)
        XCTAssertNil(OrganicBareVines.marginWords(report: Self.report(bare: false)), "another reason: its margin shows")
        // Results: the list row (its line, its sub-line) and what Compare reads from it
        let m = ResultsModel(projectName: "Stand", outcome: o)
        let tab = try XCTUnwrap(m.selected)
        XCTAssertEqual(tab.marginWords, w)
        let row = try XCTUnwrap(ResultsVersions.rows(tabs: m.tabs, blocks: m.reportBlocks,
                                                     requestedVF: { m.requestedVolumeFraction(of: $0) }).first)
        assertWords(row.value, "the list row")
        assertWords(row.subtitle, "the row's sub-line")
        XCTAssertNil(row.margin, "★ Compare's number: none")
        XCTAssertEqual(row.marginWords, w, "★ Compare's words")
        // Details › Strength: no number but what it needs
        let details = m.detailRows(.strength, version: row)
        for label in ["Holds", "Weakest spot", "Struts short", "Solid part", "Verified margin"] {
            XCTAssertFalse(details.contains { $0.label == label }, "★ no \(label): \(details.map(\.label))")
        }
        // the Library: its summary, card and row words, the verdict's mark, Compare's rows
        let s = ResultSummary(massGrams: 20, worstCaseMargin: 2.0, accepted: true, achievedVolumeFraction: 0.6, marginWords: w)
        XCTAssertEqual(LibraryStyle.margin(s), w, "★ the card's and the row's words")
        XCTAssertEqual(LibraryStyle.verdictSymbol(s).name, "exclamationmark.triangle.fill", "★ a warning, never a tick")
        let saved = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ResultSummary.self, from: saved).marginWords, w, "kept in library.json")
        var plain = s; plain.marginWords = nil
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("marginWords"),
                       "older summaries are the bytes they were")
        // the orientation check's columns
        let before = PrintBenefitRow.measured(latticeReport: Self.report())
        XCTAssertEqual(before.strengthWords, w)
        XCTAssertNil(before.strength)
        let rows = PrintBenefitRow.rows(before: before, after: PrintMeasured(strength: 2.4, layerStrength: 3.0), required: 1.5)
        XCTAssertEqual(rows.first { $0.label == "Strength" }?.old, w, "★ the strength column's words")
        XCTAssertEqual(rows.first { $0.label == "Layer strength" }?.old, w)

        // RED CONTROL: the read before notes30 brings the numbers back
        OrganicBareVines.controlUnread = true
        XCTAssertNil(OrganicBareVines.marginWords(reportJSON: o.reportJSON))
        let old = ResultsModel(projectName: "Stand", outcome: o)
        let oldRow = try XCTUnwrap(ResultsVersions.rows(tabs: old.tabs, blocks: old.reportBlocks,
                                                        requestedVF: { old.requestedVolumeFraction(of: $0) }).first)
        XCTAssertTrue(oldRow.value.contains("2.00\u{00D7}"), "RED CONTROL: the number is back: \(oldRow.value)")
        XCTAssertEqual(oldRow.margin, 2.0)
        XCTAssertEqual(PrintBenefitRow.measured(latticeReport: Self.report()).strength, 2.0, "RED CONTROL")
    }

    // MARK: the certify wizard

    /// ★ ONE pinned pop-up (his design: Next/Skip/Solve, one per issue), first, in the lattice settings' stage: its title, core's
    /// sentence, its line to where the load lands, Solve to cover the face; no "struts still short" (thicker struts never cure
    /// it). RED CONTROL: read as before, the walk opened on the struts card and sent him to thicken struts.
    func testTheWizardsIssue() throws {
        let issues = OrganicCertify.issues(report: Self.report(), infillNow: 50)
        let first = try XCTUnwrap(issues.first)
        XCTAssertEqual(first.id, OrganicBareVines.reason)
        XCTAssertEqual(first.stage, .lattice, "★ his order: lattice settings first")
        XCTAssertEqual(first.title, OrganicBareVines.title)
        XCTAssertEqual(first.text, Self.coreSentence)
        XCTAssertEqual(first.at, Self.place, "★ its line goes to where the load lands")
        XCTAssertEqual(first.solve, .coverLoadedFace)
        XCTAssertFalse(issues.contains { $0.id == "struts_short" }, "★ no thicker-struts card: \(issues.map(\.id))")
        XCTAssertEqual(issues.filter { $0.id == OrganicBareVines.reason }.count, 1, "one pop-up per issue")
        let card = OrganicCertifyCard(issue: first, step: "1 of 1", grid: nil, solvedLines: nil, next: {}, skip: {}, solve: {})
        XCTAssertEqual(card.buttons, [OrganicCertifyCard.skipTitle, OrganicCertifyCard.solveTitle], "★ Skip and Solve")
        let advice = try XCTUnwrap(OrganicCertifyAdvice.advice(first, .init(strut: nil, stepMM: 0.45, infillNow: 50)))
        XCTAssertEqual(advice.line, OrganicBareVines.advice, "★ the face now, and the two to try")
        // ★ LatticeReview 11-26: Protect skin first, wherever the app names the two (the RED control is the pop-up's, hosted)
        for words in [advice.line, OrganicBareVines.line, OrganicBareVines.checkDetail] {
            let skin = try XCTUnwrap(words.range(of: "Protect skin"), words), solid = try XCTUnwrap(words.range(of: "Solid"), words)
            XCTAssertLessThan(skin.lowerBound, solid.lowerBound, "★ Protect skin first: \(words)")
        }
        XCTAssertNil(advice.settingToChange(group: nil), "Solve offers the two itself (the centred pop-up)")
        let d = try JSONSerialization.data(withJSONObject: Self.report())
        XCTAssertTrue(OrganicCertify.opensResults(organic: true, reportJSON: d), "★ the result opens on Results, the walk there")
        // RED CONTROL: the read before notes30
        OrganicBareVines.controlUnread = true
        let old = OrganicCertify.issues(report: Self.report(), infillNow: 50)
        XCTAssertFalse(old.contains { $0.id == OrganicBareVines.reason }, "RED CONTROL: no such pop-up")
        XCTAssertEqual(old.first?.id, "struts_short", "RED CONTROL: it sent him to thicken struts")
    }

    /// ★ The certify wizard's Solve goes to the centred pop-up, its two offers the part's own changes (SOURCE PIN: the one place
    /// the workspace wires it; no new @State, no .alert / .confirmationDialog).
    func testSolveIsWiredToTheCentredPopUp() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let start = try XCTUnwrap(ws.range(of: "func certifySolve(_ issue: OrganicCertify.Issue) {"))
        let body = String(ws[start.upperBound...].prefix(900))
        XCTAssertTrue(body.contains("if solve == .coverLoadedFace {"), body)
        // ★ notes30 depth: LatticeReview's rule decides the offers (the skin's depth; Solid only when its wall clears it)
        XCTAssertTrue(body.contains("let o = OrganicBareVines.offers(depthNeededMM: issue.depthNeededMM, wallMM: project.printParams.wallRingMM)"),
                      body)
        XCTAssertTrue(body.contains("let solid: (() -> Void)? = o.solid ? { certifyCover { _ = $0.giveLoadedFaceSolidFinish(near: issue.at) } } : nil"))
        XCTAssertTrue(body.contains(
            "OrganicBareVines.offer(skin: { certifyCover { _ = $0.giveLoadedFaceProtectSkin(near: issue.at, depthMM: o.skinDepthMM) } },"))
        XCTAssertTrue(body.contains("solid: solid)"))
        let cover = try XCTUnwrap(ws.range(of: "func certifyCover(_ change: (ProjectModel) -> Void) {"))
        let cb = String(ws[cover.upperBound...].prefix(200))
        XCTAssertTrue(cb.contains("model.persistCurrentProject()") && cb.contains("certifyAdvance()"), cb)
        // the wizard's extension (an extension holds no stored @State): no .alert / .confirmationDialog — the centred pop-up only
        let ext = try XCTUnwrap(ws.range(of: "func startCertifyWalk() {"))
        let end = try XCTUnwrap(ws.range(of: "func organicMacInputsWhenReady", range: ext.upperBound..<ws.endIndex))
        let wizard = String(ws[ext.lowerBound..<end.lowerBound])
        XCTAssertTrue(wizard.contains("var certifyRecheck: some View {"), "premise: the wizard's whole extension")
        XCTAssertFalse(wizard.contains(".alert(") || wizard.contains(".confirmationDialog("), "his rule: centred pop-ups only")
    }

    // MARK: the strengthening

    /// ★ strengthen.json's stop (code load_on_bare_lattice, rounds_fixed 0, nothing strengthened): its line is core's sentence,
    /// and the Checks panel shows no "Strengthened" row (no round added anything). RED CONTROL: a code limit says its rounds.
    func testTheStrengtheningsStopIsSaid() throws {
        let doc: [String: Any] = ["ok": true, "code": "load_on_bare_lattice", "why": Self.coreSentence, "detail": "", "mode": "additive",
                                  "passing": false, "rounds_fixed": 0, "rounds_limit": 6, "strengthened": NSNull(),
                                  "rounds": [["check": "r0/strength.json"] as [String: Any]], "seconds": 4.2]
        let read = try XCTUnwrap(LatticeFileRun.Strengthened.parse(try JSONSerialization.data(withJSONObject: doc)))
        XCTAssertEqual(read.summary.code, OrganicBareVines.reason)
        XCTAssertEqual(read.summary.line, Self.coreSentence, "★ core's words, never 'Strengthened 1 round'")
        XCTAssertNil(read.lastRound, "nothing strengthened: the file is made from the lattice as laid")
        let g = try XCTUnwrap(LatticeFileFacts.strengthening(doc))
        XCTAssertEqual(g.rounds, 0, "★ rounds_fixed 0")
        var r = Self.report()
        r[LatticeFileButton.strengthenKey] = doc
        let facts = try XCTUnwrap(LatticeFileFacts.decode(r))
        XCTAssertFalse(facts.checks.contains { $0.title.hasPrefix("Strengthened") }, "★ no Strengthened row")
        // RED CONTROL: a strengthening that used its rounds says so
        var limit = doc; limit["code"] = "limit"; limit["why"] = ""
        let lim = try XCTUnwrap(LatticeFileRun.Strengthened.parse(try JSONSerialization.data(withJSONObject: limit)))
        XCTAssertTrue(lim.summary.line.hasPrefix("Strengthened"), "RED CONTROL: \(lim.summary.line)")
    }

    // MARK: his rules for the words

    /// ★ The sentence is core's own (run_job.cpp's kLoadOnBareLatticeText, letter for letter); the offers are the app's own
    /// names (the Finish row's Solid, the Role row's Protect skin — never the plain "Skin"); captions five words at most; positive
    /// words. RED CONTROL: one word changed is not core's sentence.
    func testTheWordsAreCoresAndKeepHisRules() throws {
        XCTAssertEqual(OrganicBareVines.text, Self.coreSentence)
        let core = try String(contentsOf: Self.repoRoot.appendingPathComponent("core/src/cli/run_job.cpp"), encoding: .utf8)
        XCTAssertTrue(core.contains("\"" + OrganicBareVines.text + "\""), "★ the app's sentence is core's own")
        XCTAssertFalse(core.contains("\"" + OrganicBareVines.text.replacingOccurrences(of: "bare vines", with: "open vines") + "\""),
                       "RED CONTROL: one word changed is not core's")
        XCTAssertEqual(OrganicBareVines.protectSkin, "Protect skin")
        XCTAssertEqual(OrganicBareVines.protectSkin, LatticeSetupCopy.protectSkin, "★ the Role row's own name")
        XCTAssertTrue(OrganicBareVines.solidFinish.hasPrefix(LatticeOrganicLook.Finish.solid.title), "★ the Finish row's Solid")
        XCTAssertNotEqual(OrganicBareVines.protectSkin, LatticeOrganicLook.Finish.skin.title, "never the plain Skin")
        for caption in [OrganicBareVines.title, OrganicBareVines.checkDetail, OrganicBareVines.solidFinish, OrganicBareVines.protectSkin,
                        OrganicBareVines.notNow, OrganicBareVines.rowLabel, OrganicBareVines.rowValue] {
            XCTAssertLessThanOrEqual(LatticeCaptions.words(caption), LatticeCaptions.maxWords, "★ five words at most: \(caption)")
        }
        for words in [OrganicBareVines.text, OrganicBareVines.title, OrganicBareVines.advice, OrganicBareVines.line,
                      OrganicBareVines.checkDetail, OrganicBareVines.checkMore, OrganicBareVines.solidFinish, OrganicBareVines.protectSkin] {
            let l = words.lowercased()
            XCTAssertFalse(l.contains("n't") || l.contains("cannot") || l.contains("unable"), "★ positive words: \(words)")
        }
    }

    // MARK: the two offers, on the part (his A1 pad, frozen; its "Group C" the load, as ParityTopologyShots sets it)

    func pad() throws -> ProjectModel {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.enabled = true
        p.lattice.wholePart = true
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" }, "his pad's Group C")
        p.force.makeLoad(c.id)
        for a in p.selection.groups.filter({ $0.name != "Group C" }).prefix(1) { p.force.makeAnchor(a.id) }
        p.force.sync(groups: p.selection.groups)
        XCTAssertTrue(LatticeLayoutPreview.organic(p.lattice), "premise: Organic")
        return p
    }

    /// ★ Protect skin: a lattice group holding exactly the loaded face — of the pad's two loads, the one nearest where core says
    /// the load lands (Group C's face, its middle) — its role Protect skin at the page's depth; the job sends it as a skin over
    /// that face (the vines kept off it). With no place known, every loaded face. RED CONTROL: before the offer, no skin
    /// holds it.
    func testProtectSkinCoversTheLoadedFace() throws {
        let p = try pad()
        let loads = p.selection.groups.filter { p.force.kind(for: $0.id).isLoad }
        XCTAssertGreaterThanOrEqual(loads.count, 2, "premise: his pad's own load and Group C")
        let load = try XCTUnwrap(loads.first { $0.name == "Group C" })
        let faces = Set(load.faces.map { Int32($0) })
        XCTAssertFalse(faces.isEmpty, "premise: the load has faces")
        let at = try XCTUnwrap(p.viewerMesh?.faceCentroid(try XCTUnwrap(load.faces.first)), "Group C's face, its middle")
        let before = LatticeLayoutPreview.settings(p)
        XCTAssertFalse(before.protect.contains { !Set($0.faces).isDisjoint(with: faces) }, "RED CONTROL: no skin over it yet")
        let id = try XCTUnwrap(p.giveLoadedFaceProtectSkin(near: SIMD3<Double>(at)), "★ the Protect skin group")
        let g = try XCTUnwrap(p.latticeGroups.first { $0.id == id }, "★ in the Lattice stage's own groups")
        XCTAssertEqual(Set(g.faces.map { Int32($0) }), faces, "★ exactly the loaded face the place names")
        // no place known: every loaded face (a fresh copy of the pad)
        let q = try pad()
        let all = Set(q.selection.groups.filter { q.force.kind(for: $0.id).isLoad }.flatMap(\.faces).map { Int32($0) })
        let every = try XCTUnwrap(q.giveLoadedFaceProtectSkin(near: nil))
        XCTAssertEqual(Set(try XCTUnwrap(q.latticeGroups.first { $0.id == every }).faces.map { Int32($0) }), all,
                       "★ with no place: every loaded face")
        XCTAssertTrue(p.lattice.skinGroups.contains(id), "★ its role: Protect skin")
        XCTAssertEqual(p.lattice.groupRoles[id], .exclude)
        XCTAssertNil(p.latticeList.activeGroupID, "the next tap starts its own group")
        XCTAssertFalse(p.selection.groups.contains { $0.id == id }, "Topology's groups untouched")
        XCTAssertNotNil(p.selection.groups.first { $0.id == load.id }, "the load keeps its group")
        let after = LatticeLayoutPreview.settings(p)
        let skin = try XCTUnwrap(after.protect.first { Set($0.faces).isSuperset(of: faces) }, "★ the job's skin over the loaded face")
        XCTAssertGreaterThanOrEqual(skin.depthMM, 1.0, "★ a real depth (the page's), never a two-line skin")
    }

    // MARK: the depth key (LatticeReview, organic-engine 9850d951)

    /// ★ LatticeReview's wizard rule with core's `solid_depth_needed_mm`: Solid finish offered ONLY when its wall (the printer's
    /// wall ring) is at least the depth needed; Protect skin at max(4 mm, the depth rounded UP to 0.5 mm), still first; no key
    /// (an older worker): today's two offers at the page's depth. Read from the strength block, else strengthen.json. RED
    /// CONTROL (controlNoDepth: the key ignored): today's offers even with the key.
    func testTheDepthKeyDecidesTheOffers() throws {
        // read: the strength block, the wizard's issue, strengthen.json
        let block = try XCTUnwrap(Self.report(depth: 1.2)["strength"] as? [String: Any])
        XCTAssertEqual(OrganicBareVines.found(strength: block)?.depthNeededMM, 1.2)
        XCTAssertEqual(LatticeFileStrength(block: block).bareVines?.depthNeededMM, 1.2, "the print file's strength")
        let issue = try XCTUnwrap(OrganicCertify.issues(report: Self.report(depth: 1.2), infillNow: 50).first)
        XCTAssertEqual(issue.depthNeededMM, 1.2, "★ the wizard's issue carries it")
        var viaStrengthen = Self.report()
        viaStrengthen[LatticeFileButton.strengthenKey] = ["code": "load_on_bare_lattice", "solid_depth_needed_mm": 2.0] as [String: Any]
        XCTAssertEqual(OrganicCertify.issues(report: viaStrengthen, infillNow: 50).first?.depthNeededMM, 2.0,
                       "★ else strengthen.json's, when it carries the key")
        let sj = try JSONSerialization.data(withJSONObject: ["ok": true, "code": "load_on_bare_lattice", "rounds_fixed": 0,
                                                             "solid_depth_needed_mm": 1.35, "rounds": [] as [Any]])
        XCTAssertEqual(LatticeFileRun.Strengthened.parse(sj)?.summary.depthNeededMM, 1.35)
        XCTAssertNil(OrganicCertify.issues(report: Self.report(), infillNow: 50).first?.depthNeededMM, "no key: nil")

        // key present + a thin Solid (a 0.9 mm wall under 1.2 mm needed): Solid NOT offered; the skin at the 4 mm floor
        let thin = OrganicBareVines.offers(depthNeededMM: 1.2, wallMM: 0.9)
        XCTAssertEqual(thin, .init(solid: false, skinDepthMM: 4.0), "★ Solid not offered")
        XCTAssertEqual(OrganicBareVines.adviceLine(thin), "The loaded face is bare vines now. Try a Protect skin 4 mm deep.",
                       "★ the card names the skin's depth and no Solid")
        // a wall deep enough: both, Protect skin first
        let deep = OrganicBareVines.offers(depthNeededMM: 1.2, wallMM: 1.32)
        XCTAssertTrue(deep.solid, "★ the wall clears it: Solid offered")
        XCTAssertEqual(OrganicBareVines.adviceLine(deep), "The loaded face is bare vines now. Try a Protect skin 4 mm deep or a Solid finish.")
        XCTAssertTrue(OrganicBareVines.offers(depthNeededMM: 1.2, wallMM: 1.2).solid, "a wall exactly the depth needed clears it")
        // key present + 6 mm needed: Protect skin at 6.0 mm; 4.2 → 4.5; 6.01 → 6.5
        XCTAssertEqual(OrganicBareVines.offers(depthNeededMM: 6.0, wallMM: 1.32).skinDepthMM, 6.0, "★ 6 mm needed: 6.0 mm")
        XCTAssertEqual(OrganicBareVines.offers(depthNeededMM: 6.0, wallMM: 1.32).solid, false)
        XCTAssertEqual(OrganicBareVines.offers(depthNeededMM: 4.2, wallMM: 1.32).skinDepthMM, 4.5, "★ 4.2 → 4.5 (up to 0.5 mm)")
        XCTAssertEqual(OrganicBareVines.offers(depthNeededMM: 6.01, wallMM: 1.32).skinDepthMM, 6.5, "up, never down")
        XCTAssertEqual(OrganicBareVines.offers(depthNeededMM: 0.9, wallMM: 1.32).skinDepthMM, 4.0, "never under the 4 mm floor")
        // key absent (an older worker): today's two offers at the page's depth, today's advice
        let older = OrganicBareVines.offers(depthNeededMM: nil, wallMM: 0.9)
        XCTAssertEqual(older, .init(solid: true, skinDepthMM: nil), "★ no key: today's two offers")
        XCTAssertEqual(OrganicBareVines.adviceLine(older), OrganicBareVines.advice)
        // the card's advice through the wizard's context (the printer's wall)
        let c = OrganicCertifyAdvice.Context(strut: nil, stepMM: 0.45, infillNow: 50, wallMM: 0.9)
        XCTAssertEqual(OrganicCertifyAdvice.advice(issue, c)?.line, OrganicBareVines.adviceLine(thin))

        // RED CONTROL: the key ignored — Solid offered again under a thin wall, the page's depth
        OrganicBareVines.controlNoDepth = true
        XCTAssertEqual(OrganicBareVines.offers(depthNeededMM: 1.2, wallMM: 0.9), .init(solid: true, skinDepthMM: nil),
                       "RED CONTROL: today's offers")
        XCTAssertEqual(OrganicBareVines.offers(depthNeededMM: 6.0, wallMM: 1.32).skinDepthMM, nil, "RED CONTROL: no 6 mm skin")
    }

    /// ★ The Protect skin offer lays its skin at the depth the rule names (6 mm here), never the page's 4 mm. RED CONTROL: with
    /// no depth (no key), the page's 4 mm.
    func testTheProtectSkinIsLaidAtTheDepthNeeded() throws {
        let p = try pad()
        let id = try XCTUnwrap(p.giveLoadedFaceProtectSkin(near: nil, depthMM: 6.0))
        XCTAssertEqual(p.lattice.groupDepthMM[id], 6.0, "★ the group's depth")
        let faces = Set(try XCTUnwrap(p.latticeGroups.first { $0.id == id }).faces.map { Int32($0) })
        let skin = try XCTUnwrap(LatticeLayoutPreview.settings(p).protect.first { Set($0.faces).isSuperset(of: faces) })
        XCTAssertEqual(skin.depthMM, 6.0, accuracy: 1e-9, "★ the job's skin, 6 mm deep")
        // RED CONTROL: no depth named — the page's own
        let q = try pad()
        let old = try XCTUnwrap(q.giveLoadedFaceProtectSkin(near: nil))
        XCTAssertEqual(q.lattice.groupDepthMM[old], LatticeSlabDepth.clamp(q.lattice.paintDepthMM), "RED CONTROL: the page's depth")
        XCTAssertNotEqual(q.lattice.groupDepthMM[old], 6.0)
    }

    /// The nearest point of a triangle (the load nearest the place): over its face, beyond a corner, beyond an edge.
    func testTheNearestPointOfATriangle() {
        let a = SIMD3<Double>(0, 0, 0), b = SIMD3<Double>(4, 0, 0), c = SIMD3<Double>(0, 4, 0)
        XCTAssertEqual(OrganicBareVines.closest(SIMD3(1, 1, 3), a, b, c), SIMD3(1, 1, 0), "over the face: straight down")
        XCTAssertEqual(OrganicBareVines.closest(SIMD3(-2, -3, 1), a, b, c), a, "beyond a corner: the corner")
        XCTAssertEqual(OrganicBareVines.closest(SIMD3(2, -5, 0), a, b, c), SIMD3(2, 0, 0), "beyond an edge: on the edge")
        XCTAssertEqual(OrganicBareVines.closest(SIMD3(3, 3, 0), a, b, c), SIMD3(2, 2, 0), "beyond the long edge: its middle")
        XCTAssertNotEqual(OrganicBareVines.closest(SIMD3(1, 1, 3), a, b, c), a, "RED CONTROL: never simply a corner")
    }

    /// ★ Solid finish: the loaded face's area takes the Finish row's Solid (the whole part here: it is latticed whole); the job's
    /// woven region goes with the printer's wall as its cover. RED CONTROL: before the offer, no cover.
    func testSolidFinishCoversTheLoadedFacesArea() throws {
        let p = try pad()
        p.lattice.setOrganicLook({ var l = p.lattice.organicLook(group: nil); l.finish = LatticeOrganicLook.Finish.none; return l }(),
                                 group: nil)
        let woven = { (s: LatticeLayoutSession.Settings) in s.regions.filter(\.weave) }
        XCTAssertFalse(woven(LatticeLayoutPreview.settings(p)).isEmpty, "premise: a woven region")
        XCTAssertTrue(woven(LatticeLayoutPreview.settings(p)).allSatisfy { ($0.finish.coverMM ?? 0) <= 0 }, "RED CONTROL: no cover yet")
        XCTAssertNil(p.giveLoadedFaceSolidFinish(near: Self.place), "★ the whole part's own finish (latticed whole)")
        XCTAssertEqual(p.lattice.organicLook(group: nil).finish, .solid, "★ the Finish row reads Solid")
        XCTAssertTrue(woven(LatticeLayoutPreview.settings(p)).allSatisfy { ($0.finish.coverMM ?? 0) > 0 },
                      "★ the job covers the weave with the printer's wall")
    }
}
