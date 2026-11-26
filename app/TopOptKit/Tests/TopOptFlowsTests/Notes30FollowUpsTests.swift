// Notes30FollowUpsTests — release 21's two follow-ups (builder F1, notes30), the source and settings parts. The pages:
// Notes30FollowUpsHostedTests.
//   (1) His rule (notes29): ONE (i) app-wide, opening the centred card. After notes29 the Flexible face's (i) kept its own
//       card by handing the one (i) a tap of its own; no (i) the app draws does that now.
//   (2) Save keeps the Part tab's grade (Stress + shape unless he picked another there) and each group its own.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class Notes30FollowUpsTests: XCTestCase {

    // MARK: (1) the one (i)

    /// The `AppInfoButton(` calls in `code` that hand it a tap of their own (a `tap:` argument or a trailing closure) — an (i)
    /// that opens something other than the centred card.
    static func ownTaps(_ code: String) -> [String] {
        var out: [String] = []
        var rest = code[...]
        while let r = rest.range(of: "AppInfoButton(") {
            var depth = 1, i = r.upperBound
            while i < rest.endIndex, depth > 0 {
                if rest[i] == "(" { depth += 1 } else if rest[i] == ")" { depth -= 1 }
                i = rest.index(after: i)
            }
            let args = rest[r.upperBound..<i]
            let trailing = rest[i...].drop(while: { $0 == " " }).first == "{"
            if args.contains("tap:") || trailing { out.append(String(rest[r.lowerBound..<i].prefix(90))) }
            rest = rest[i...]
        }
        return out
    }

    /// ★ (1) No (i) the app draws opens a card of its own: no source but SelectionsList's `InfoButton` hands the one (i) a tap
    /// of its own, and nothing calls that one (were it called, this fails: move it to the centred card). RED CONTROL: release
    /// 21's Flexible face (i) is caught.
    func testNoInfoOpensACardOfItsOwn() throws {
        var files = 0
        var own: [String: [String]] = [:]
        var infoButtonCalls = 0
        for module in ["TopOptFlows", "TopOptDesign"] {
            let dir = FlexibleSource.url("", module: module)
            for n in try FileManager.default.contentsOfDirectory(atPath: dir.path).filter({ $0.hasSuffix(".swift") }).sorted() {
                let code = try FlexibleSource.code(n, module: module)
                files += 1
                infoButtonCalls += code.components(separatedBy: "InfoButton(ui:").count - 1
                guard n != "AppInfo.swift" else { continue }   // the one (i) itself
                let taps = Self.ownTaps(code)
                if !taps.isEmpty { own[module + "/" + n] = taps }
            }
        }
        XCTAssertGreaterThan(files, 400, "premise: the walk reads the app's sources")
        XCTAssertEqual(own.keys.sorted(), ["TopOptFlows/SelectionsList.swift"], "★ an (i) opens a card of its own: \(own)")
        XCTAssertEqual(own["TopOptFlows/SelectionsList.swift"]?.count, 1, "only its InfoButton")
        XCTAssertEqual(infoButtonCalls, 0, "★ SelectionsList's InfoButton is called nowhere (move it to the centred card first)")
        XCTAssertTrue(Self.ownTaps("AppInfoButton(title: t, text: x, label: \"About \\(t)\", id: \"a-(i)\") .padding()").isEmpty,
                      "premise: a plain (i), interpolations and brackets in its words, is not counted")

        // RED CONTROL: release 21's FlexibleInfoButton (its tap opened the face's card beside it)
        let release21 = """
                AppInfoButton(title: "Its lattice numbers", text: "", lit: on) {
                    ui.roleOpen = nil
                    ui.info = on ? nil : FlexibleFaceChipState.Info(key: key, group: group, ref: ref, anchor: frame)
                }
        """
        XCTAssertEqual(Self.ownTaps(release21).count, 1, "RED CONTROL: release 21's face (i) is caught")
        XCTAssertEqual(Self.ownTaps("AppInfoButton(title: t, text: \"\", tap: { open() })").count, 1, "RED CONTROL: a tap: argument too")
    }

    // MARK: (2) Save keeps Stress + shape

    /// ★ (2) Save never moves a group's grade, band or Strength onto the part: the part keeps the Part tab's (Stress + shape on
    /// a new part), a group keeps its own whole (its Manual controls with it), a group that grades as the part stores nothing
    /// (it follows the Part tab), and a saved part reads back the same. RED CONTROL: the old Save (B7: the first area leads)
    /// moved all three onto the part.
    func testSaveKeepsThePartsGradeBandAndStrength() throws {
        let a = UUID(), b = UUID()
        var s = LatticeSettings(enabled: true)
        XCTAssertEqual(s.gradingMode, .full, "★ a new part: Stress + shape")
        XCTAssertEqual(LatticeWizardModel(settings: s).gradingMode, .full, "★ and the page opens on it")
        let band = s.shapeFitBandMM, strength = s.shapeFitGradeStrength
        var mine = LatticeAreaGrading(gradingMode: .fitShape, shapeFitBandMM: band + 4, shapeGradeStrength: strength + 0.5)
        mine.cellsAcrossMin = 3
        s.saveAreaGrading([a: mine, b: LatticeAreaGrading(gradingMode: .full, shapeFitBandMM: band)], areas: [a, b])
        XCTAssertEqual(s.gradingMode, .full, "★ the part keeps Stress + shape")
        XCTAssertEqual(s.shapeFitBandMM, band, "★ and its band")
        XCTAssertEqual(s.shapeFitGradeStrength, strength, "★ and its Strength")
        XCTAssertEqual(s.areaGrading[a], mine, "★ Group 1 keeps its own, whole")
        XCTAssertNil(s.areaGrading[b], "★ a group that grades as the part stores nothing: it follows the Part tab")

        // saved and reopened (a version is the same snapshot)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back.gradingMode, .full, "★ reopened: Stress + shape")
        XCTAssertEqual(back.areaGrading, s.areaGrading, "★ reopened: Group 1's own")

        // his own pick on the Part tab stays his
        var picked = LatticeSettings(enabled: true)
        picked.gradingMode = .stressOnly
        picked.saveAreaGrading([a: mine], areas: [a, b])
        XCTAssertEqual(picked.gradingMode, .stressOnly, "★ a grade he picked on the Part tab is kept")

        // RED CONTROL: the old Save
        var old = LatticeSettings(enabled: true)
        old.saveAreaGrading([a: mine], areas: [a, b], firstAreaLeads: true)
        XCTAssertEqual(old.gradingMode, .fitShape, "RED CONTROL: Group 1's grade became the part's")
        XCTAssertEqual(old.shapeFitBandMM, band + 4, "RED CONTROL: and its band")
        XCTAssertEqual(old.shapeFitGradeStrength, strength + 0.5, "RED CONTROL: and its Strength")
    }

    // MARK: (3) the group tab's note (notes30, follow-ups 2)

    /// ★ (3) 362's words: on a group's tab, "Preview shows this group's grade." (five words, it said "the part's"), shown only
    /// where it is so: the group's grade lays apart from the Part tab's. RED CONTROL: release 21's rule (the grade differs)
    /// showed it where the two lay alike, and its words were untrue.
    @MainActor func testTheGroupGradeNoteOnlyWhereThePreviewDrawsTheGroupsGrade() {
        XCTAssertEqual(LatticeSetupWizard.latticeAreaPreviewBrief, "Preview shows this group's grade.")
        XCTAssertLessThanOrEqual(LatticeCaptions.words(LatticeSetupWizard.latticeAreaPreviewBrief), LatticeCaptions.maxWords)
        XCTAssertFalse(LatticeSetupWizard.latticeAreaPreviewLine.contains("one grade for the whole part"), "★ its (i) says so too")
        var byStress = LatticeSettings(enabled: true)
        byStress.setSimulateStresses(true)
        byStress.densityMode = .sim
        let part = LatticeAreaGrading(gradingMode: .full, shapeFitBandMM: byStress.shapeFitBandMM,
                                      shapeGradeStrength: byStress.shapeFitGradeStrength)
        func shows(_ group: LatticeGradingMode, _ l: LatticeSettings) -> Bool {
            var page = l
            page.gradingMode = group
            return LatticeSetupWizard.groupGradeShows(page, partGrade: part, lineWidthMM: 0.45, wallRingMM: 0.9)
        }
        XCTAssertTrue(LatticeLayoutPreview.settings(byStress).byStress, "premise: the part grades by stress")
        XCTAssertTrue(shows(.fitShape, byStress), "★ by stress: the group's Shape lays without the Part tab's stress grade")
        XCTAssertTrue(shows(LatticeGradingMode.none, byStress), "★ the group's No grade lays one cell, one density")
        XCTAssertFalse(shows(.full, byStress), "★ the Part tab's own grade: nothing to say")
        var still = byStress
        still.setSimulateStresses(false)
        XCTAssertFalse(LatticeLayoutPreview.settings(still).byStress, "premise: no stress to follow")
        XCTAssertFalse(shows(.fitShape, still), "★ no stress to follow: Shape and Stress + shape lay alike here")
        // RED CONTROL: release 21's rule said it there anyway
        func old(_ group: LatticeGradingMode, _ l: LatticeSettings) -> Bool {
            part.gradingMode != group || (group.fitsShape && part.shapeFitBandMM != l.shapeFitBandMM)
        }
        XCTAssertTrue(old(.fitShape, still), "RED CONTROL: the old rule showed it where nothing drawn differs")
    }
}
