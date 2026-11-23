// OrganicCertifyAdviceTests — ★ his notes 11-23 (notes25 B4, B5, B7) on the certify wizard's pop-ups: every pop-up that asks for a
// change names the setting, its value now and a value to try ("the fix pop-up only said to use thicker struts, but it didn't say
// what thickness to try"); Skip goes to the next pop-up, never off Results; the struts' sentence counts the rounds that added
// material (6 on his stand, never the 7 checks), margins with two decimals. Each kind's rule is pinned on its formula and its
// rendered words. RED CONTROLS: a result that certifies asks nothing; nothing carries the load: no number is made up.
import XCTest
import simd
@testable import TopOptFlows

final class OrganicCertifyAdviceTests: XCTestCase {
    typealias A = OrganicCertifyAdvice

    func issue(_ id: String, worst: Double, needs: Double = 1.5, solve: OrganicCertify.Solve? = nil) -> OrganicCertify.Issue {
        OrganicCertify.Issue(id: id, stage: .lattice, title: id, text: "", spotIDs: [], at: nil, solve: solve, worst: worst, needs: needs)
    }

    /// ★ B4: thicker struts — the setting scaled by √(needed ÷ holds), each end, up to the field's step (one printed line).
    func testStrutsNameTheThicknessNowAndAThicknessToTry() {
        let struts = issue("struts_short", worst: 1.34, solve: .strutThickness)
        // his stand's back-wall group, a Manual Sweep, the 0.45 mm line: 1.35 to 2.7 mm
        let sweep = A.StrutNow(light: 1.35, heavy: 2.7, single: false, auto: false)
        let a = A.advice(struts, A.Context(strut: sweep, stepMM: 0.45, infillNow: 50))
        XCTAssertEqual(a?.setting, "Strut thickness")
        XCTAssertEqual(a?.line, "Strut thickness is 1.35 to 2.7 mm. Try 1.8 to 3.15 mm.",
                       "★ both ends × √(1.5 ÷ 1.34) = 1.058, rounded up to the 0.45 mm line the field snaps to")
        // the coordinator's example: one number, a 0.1 mm step
        let one = A.StrutNow(light: 2.2, heavy: 2.2, single: true, auto: false)
        XCTAssertEqual(A.advice(struts, A.Context(strut: one, stepMM: 0.1, infillNow: 50))?.line,
                       "Strut thickness is 2.2 mm. Try 2.4 mm.", "★ 2.2 × 1.058 = 2.33, up to 2.4")
        // Auto's numbers: the line says which mode to type them in; with several groups, whose
        let auto = A.StrutNow(light: 1.35, heavy: 2.7, single: false, auto: true)
        XCTAssertEqual(A.advice(struts, A.Context(strut: auto, group: "Back wall", stepMM: 0.45, infillNow: 50))?.line,
                       "Back wall: strut thickness is Auto, 1.35 to 2.7 mm. Set Manual Sweep: 1.8 to 3.15 mm.")
        // past the field's 50 mm: said plainly, the next step instead
        let big = A.StrutNow(light: 40, heavy: 49, single: false, auto: false)
        let past = A.advice(issue("struts_short", worst: 1.0, solve: .strutThickness), A.Context(strut: big, stepMM: 0.45, infillNow: 50))
        XCTAssertEqual(past?.setting, "Cell size", "★ beyond the field: smaller cells")
        XCTAssertEqual(past?.line, "Struts would need 60.01 mm, past the 50 mm the field takes. Use smaller cells instead.")
        // not measured yet: the factor, never an invented number
        XCTAssertEqual(A.advice(struts, A.Context(strut: nil, stepMM: 0.45, infillNow: 50))?.line,
                       "Strut thickness is Auto, not measured yet. Set Manual Sweep about 6% thicker at both ends.")
    }

    func testTheStrutRuleItself() {
        XCTAssertEqual(A.strutFactor(holds: 1.34, needs: 1.5), (1.5 / 1.34).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(A.strutFactor(holds: 1.6, needs: 1.5), 1, "RED CONTROL: it holds: nothing thicker")
        XCTAssertEqual(A.thicker(2.2, factor: 1.0001, stepMM: 0.1), 2.3, accuracy: 1e-9, "★ at least 0.1 mm more")
        XCTAssertEqual(A.thicker(1.35, factor: 1, stepMM: 0.45), 1.8, accuracy: 1e-9, "★ on the field's step, one step up")
        XCTAssertEqual(A.thicker(0.9, factor: 1.06, stepMM: 0.05), 1.0, accuracy: 1e-9, "a step under 0.1 mm counts as 0.1")
        // ★ SOURCE PIN: the formula (area scaling) and the rounding (up)
        let src = try! FlexibleSource.code("OrganicCertifyAdvice.swift")
        XCTAssertTrue(src.contains("return (needs / holds).squareRoot()"), "★ d_new = d_now × √(needed ÷ holds)")
        XCTAssertTrue(src.contains("func up(_ v: Double) -> Double { ((v / s) - 1e-9).rounded(.up) * s }"), "★ rounded UP to the step")
        XCTAssertTrue(src.contains("if v < d + 0.1 - 1e-9 { v = up(d + 0.1) }"), "★ at least 0.1 mm more")
        XCTAssertTrue(src.contains("let s = Swift.max(stepMM, 0.1)"), "★ the step is at least 0.1 mm")
    }

    /// ★ B4: every other kind, its own rule and words.
    func testEveryOtherKindIsSpecificToo() {
        let c = A.Context(strut: nil, stepMM: 0.45, infillNow: 50)
        // a weak area of the solid: its thickness × √(needed ÷ holds), up to the next 0.1×
        XCTAssertEqual(A.solidFactor(holds: 0.58, needs: 1.5), 1.7, accuracy: 1e-9, "√(1.5 ÷ 0.58) = 1.61 → 1.7")
        XCTAssertEqual(A.advice(issue("beside_the_lattice", worst: 0.58, solve: .keepLatticeAway), c)?.line,
                       "This area holds 0.58× of the 1.5× it needs. Make the solid between the lattice and the surface about 1.7× as thick.")
        XCTAssertEqual(A.advice(issue("beside_a_fixing", worst: 0.9), c)?.line,
                       "This area holds 0.90× of the 1.5× it needs. Make the solid around the fixing about 1.3× as thick.")
        XCTAssertEqual(A.advice(issue("beside_the_load", worst: 1.2), c)?.line,
                       "This area holds 1.20× of the 1.5× it needs. Make the solid where the load presses about 1.2× as thick.")
        XCTAssertEqual(A.advice(issue("inside_the_solid", worst: 1.1), c)?.line,
                       "This area holds 1.10× of the 1.5× it needs. Make the solid here about 1.2× as thick.")
        // infill: core's lowest passing infill against the infill now
        XCTAssertEqual(A.advice(issue("infill", worst: 0.58, solve: .infill(percent: 81)), c)?.line, "Infill is 50% now. 81% passes.")
        // the load on open lattice: the loaded face's Protect
        XCTAssertEqual(A.advice(issue("load_on_open_lattice", worst: 0, solve: .protectLoadedFace), c)?.line,
                       "The loaded face is open lattice now. Set it to Protect.")
        // RED CONTROL: nothing carries the load — no setting, no number made up
        XCTAssertNil(A.advice(issue("not_certified", worst: 0), c))
        // ★ SOURCE PIN: the solid's rule
        let src = try! FlexibleSource.code("OrganicCertifyAdvice.swift")
        XCTAssertTrue(src.contains("return Swift.max(1.1, (((needs / holds).squareRoot() * 10) - 1e-9).rounded(.up) / 10)"))
    }

    /// ★ B4: the settings as they stand — Auto's numbers as the field shows them (Look applied), a typed range, one number.
    func testTheStrutNowIsWhatTheFieldShows() {
        let limits = LatticeOrganicLook.Limits(strutLowerMM: 0.9, strutUpperMM: 2.25, strutAutoMM: 1.6, cellLowerMM: 4, cellUpperMM: 9,
                                               cellAutoMM: 6)
        var look = LatticeOrganicLook()
        XCTAssertEqual(A.strutNow(look, limits: limits), A.StrutNow(light: 0.9, heavy: 2.25, single: false, auto: true), "Auto Sweep")
        XCTAssertNil(A.strutNow(look, limits: nil), "not measured: no number")
        look.strut = .init(mode: .manualSweep, light: 1.35, heavy: 2.7)
        XCTAssertEqual(A.strutNow(look, limits: nil), A.StrutNow(light: 1.35, heavy: 2.7, single: false, auto: false))
        look.strut = .init(mode: .manual, single: 2.2)
        XCTAssertEqual(A.strutNow(look, limits: limits), A.StrutNow(light: 2.2, heavy: 2.2, single: true, auto: false))
    }

    /// ★ B7: "after 6 rounds" (the rounds that added material), never the 7 checks; two decimals; "needs 1.5×".
    func testTheStrutsSentenceCountsTheRoundsThatAdded() throws {
        var r = OrganicCertifyTests.report()
        let issues = OrganicCertify.issues(report: r, infillNow: 50)
        let struts = try XCTUnwrap(issues.first { $0.id == "struts_short" })
        XCTAssertEqual(struts.text, "The weakest strut holds 1.38× your load after 6 rounds of strengthening; it needs 1.5×.")
        XCTAssertFalse(struts.text.contains("7 rounds"), "★ RED CONTROL: the 7 checks are not rounds")
        XCTAssertEqual(struts.needs, 1.5)
        // an older summary with no rounds_fixed: the rounds that added
        let added: [String: Any] = ["added": [String: Any]()], check: [String: Any] = ["struts": [String: Any]()]
        r[LatticeFileButton.strengthenKey] = ["code": "limit", "rounds": [added, added, check]] as [String: Any]
        XCTAssertTrue(try XCTUnwrap(OrganicCertify.issues(report: r, infillNow: 50).first).text.contains("after 2 rounds"))
        XCTAssertEqual(OrganicCertifyCopy.margin(1.3399), "1.34×", "★ two decimals")
        XCTAssertEqual(OrganicCertifyCopy.needs(1.5), "1.5×")
    }

    /// ★ B5: Skip closes this pop-up and the next is up; after the last, none (the wizard ends).
    func testSkipGoesToTheNextAndEnds() throws {
        let d = try JSONSerialization.data(withJSONObject: OrganicCertifyTests.report())
        var w = try XCTUnwrap(OrganicCertify.walk(version: UUID(), reportJSON: d, infillNow: 50))
        XCTAssertEqual(w.current?.id, "struts_short")
        w.skip()
        XCTAssertEqual(w.current?.id, "beside_the_lattice", "★ the next pop-up")
        for _ in 0..<4 { w.skip() }
        XCTAssertNil(w.current, "★ none after the last")
        XCTAssertTrue(w.done)
        // ★ SOURCE PIN: Skip is its own (the next pop-up, or none), never Next's end (which opens the Lattice stage)
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("skip: { OrganicCertifyCard.controlSkipLeaves ? certifyAdvance() : certifySkip() }"))
        let body = try XCTUnwrap(ws.range(of: "func certifySkip() {").map { String(ws[$0.upperBound...].prefix(80)) })
        XCTAssertTrue(body.contains("model.certifyWalk?.skip()") && !body.contains("viewOriginal") && !body.contains("goToStage"),
                      "★ Skip never leaves Results: \(body)")
    }
}
