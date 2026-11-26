// Notes29UITests — his iPad notes on release 20 (2026-11-25), builder N1, the pure and source parts:
//   (2) "I couldn't turn the Skin off. Even though this was 'Structural' and there is NO single-cell available in structural."
//   (3) "You should aim for about 5 words below ANY setting, with an (i)."
//   (4) "The icon should look the same across the ENTIRE app." / every (i) opens the front-and-centre notification.
//   (5) "the 'Allow quilt' was defaulted 'on'. It should *always* be off. Especially in 'Auto'."
//   (6) "'Shape' grade is the only thing selected by default. It should always be 'Stress & Shape'."
//   (7) "Choosing perspective/orthogonal view does nothing to the sample in the Settings tab. It should work everywhere,
//       including the sample part and the cube."
// The page itself: Notes29UIHostedTests.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class Notes29UITests: XCTestCase {

    // MARK: (4) the one (i)

    /// Every Swift source of the app, its code without comments.
    private func sources() throws -> [(name: String, code: String)] {
        var out: [(String, String)] = []
        for module in ["TopOptFlows", "TopOptDesign"] {
            let dir = FlexibleSource.url("", module: module)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
            for n in names { out.append((module + "/" + n, try FlexibleSource.code(n, module: module))) }
        }
        return out
    }

    /// The (i) look a source draws by itself, outside the one component: the glyph's symbol or a hand-drawn "i".
    static func ownInfoLook(_ code: String) -> [String] {
        var found: [String] = []
        for needle in ["\"info.circle", "Text(\"i\")", "systemImage: \"info"] where code.contains(needle) { found.append(needle) }
        return found
    }

    /// ★ (4) One glyph, one size, one colour: only AppInfo.swift draws the (i); every other file uses AppInfoGlyph /
    /// AppInfoButton. No popover shows an (i)'s words: the popovers left are named here, each with why it is not an (i).
    func testEveryInfoIsTheOneComponent() throws {
        let all = try sources()
        XCTAssertGreaterThan(all.count, 400, "premise: the walk reads the app's sources")
        for (name, code) in all where name != "TopOptFlows/AppInfo.swift" {
            XCTAssertEqual(Self.ownInfoLook(code), [], "★ \(name) draws its own (i): use AppInfoGlyph / AppInfoButton")
        }
        // RED CONTROL: the look the Organic and lattice pages drew before this release is caught
        XCTAssertFalse(Self.ownInfoLook("Image(systemName: \"info.circle\").font(.system(size: 13))").isEmpty)
        XCTAssertFalse(Self.ownInfoLook("Text(\"i\").font(.system(size: 13, weight: .bold, design: .serif))").isEmpty)

        // The popovers that remain, each named with why it is not an (i) (nothing allowed silently).
        let popoversAllowed: [String: (count: Int, why: String)] = [
            "TopOptFlows/NumberPadHost.swift": (1, "the number pad, anchored to the number it types"),
            "TopOptFlows/LatticeBandChipViews.swift": (1, "a band chip's two-answer choice card, anchored to the chip"),
            "TopOptFlows/WorkspacePlaceholder.swift": (2, "a group's colour picker; the diagnosis warning glyph's fixes card"),
        ]
        for (name, code) in all {
            let n = code.components(separatedBy: ".popover(").count - 1
            XCTAssertEqual(n, popoversAllowed[name]?.count ?? 0,
                           "★ \(name): \(n) popover(s) — an (i)'s words open the centred notification (AppInfoButton)")
        }
        // Each (i) helper the pages call is a wrapper round the one component.
        let wrappers: [(file: String, decl: String)] = [
            ("SettingRow.swift", "struct InfoTip: View {"), ("FlexibleInfo.swift", "struct FlexInfoButton<Extra: View>: View {"),
            ("AppPopup.swift", "struct OrganicInfoButton: View {"), ("ResultsPanels.swift", "struct ResultsDetailInfo: View {"),
            ("FlexibleSelectionsList.swift", "struct FlexibleInfoButton: View {"), ("SelectionsList.swift", "struct InfoButton: View {"),
            ("WorkspacePlaceholder.swift", "private struct InfoPopoverButton: View {"),
            ("LatticeSetupWizard.swift", "private func infoButton(_ id: String, _ text: String, title: String? = nil) -> some View {"),
        ]
        for w in wrappers {
            let code = try FlexibleSource.code(w.file)
            let r = try XCTUnwrap(code.range(of: w.decl), "\(w.file): \(w.decl)")
            XCTAssertTrue(String(code[r.upperBound...].prefix(1400)).contains("AppInfoButton("), "★ \(w.decl) is the one (i)")
        }
    }

    /// ★ (4) "ensure there is ample room for the text in the notification and that it expands/contracts with the text": the
    /// card widens with its words (before it grows tall) and never leaves the screen's margin.
    func testTheNotificationWidensWithItsWords() {
        let short = AppInfoCard.width(for: "Two cells across a member.", room: 1376)
        let long = AppInfoCard.width(for: String(repeating: "A member one cell wide has its struts cut. ", count: 20), room: 1376)
        XCTAssertEqual(short, AppInfoCard.minWidth, "★ a short sentence: the narrow card")
        XCTAssertEqual(long, AppInfoCard.maxWidth, "★ a long text: the widest card")
        XCTAssertLessThanOrEqual(AppInfoCard.width(for: String(repeating: "x", count: 900), room: 400), 400 - 2 * AppInfoCard.margin + 0.5,
                                 "never past the screen's margin")
        XCTAssertEqual(AppInfoCard.tapAnywhere, "Tap anywhere to continue", "his words")
    }

    /// ★ (4) an (i) raises the centred notification with no OK (no dismiss button), keeping an action it offers.
    @MainActor func testAnInfoRaisesTheNotificationWithoutOK() {
        let p = AppPopups.shared
        p.current = nil
        p.help("Skin density", "Where a vine reaches the face…", action: (title: "Mark as tested", run: {}))
        XCTAssertEqual(p.current?.info, true)
        XCTAssertFalse(p.dismissShown, "★ no OK: any tap closes it")
        XCTAssertEqual(p.action?.title, "Mark as tested", "an action it offers stays")
        p.current = nil
        XCTAssertNil(p.action)
        p.show("That number won’t work", "Use 1–20.")
        XCTAssertTrue(p.dismissShown, "RED CONTROL: an error keeps its OK")
        p.current = nil
    }

    // MARK: (3) five words under a setting

    /// ★ (3) Every line the Lattice settings panel can draw under a setting, as written in its sources, is at most five words
    /// (a literal's interpolations count as one word each). The page walked in its states: Notes29UIHostedTests.
    func testEveryCaptionInTheLatticePanelSourcesIsFiveWords() throws {
        var checked = 0
        for file in ["LatticeSetupWizard.swift", "LatticeOrganicControls.swift", "LatticeCaptions.swift"] {
            let code = try FlexibleSource.code(file)
            for call in ["captionLine(", "shortNote(", "say(", "simDerivedNote(", "refusalNote("] {
                var rest = code[...]
                while let r = rest.range(of: call) {
                    rest = rest[r.upperBound...]
                    let arg = rest.prefix(while: { $0 == " " || $0 == "\n" })
                    let after = rest[arg.endIndex...]
                    guard after.first == "\"", let end = Self.literalEnd(after) else { continue }
                    let lit = Self.flattenInterpolations(String(after[after.index(after: after.startIndex)..<end]))
                    XCTAssertLessThanOrEqual(LatticeCaptions.words(lit), LatticeCaptions.maxWords, "★ \(file): \(call)\"\(lit)\"")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 20, "premise: the walk found the panel's literal lines")
        // the panel's named lines
        let named = [LatticeSetupWizard.gradeOnLine, LatticeSetupWizard.gradeOffLine, LatticeSetupWizard.gradeFullLine,
                     LatticeSetupWizard.gradeShapeLine, LatticeSetupWizard.gradeStressLine, LatticeSetupWizard.simOnLine,
                     LatticeSetupWizard.simOffLine, LatticeSetupWizard.steppedBlockedLine, LatticeSetupWizard.gradeStyleMissingLine,
                     LatticeSetupWizard.steppedLine, LatticeSetupWizard.defaultGradeLine, LatticeSetupWizard.markWallFirstLine,
                     LatticeSetupWizard.sizesRecheckLine, LatticeSetupWizard.cantCheckSizesLine, LatticeSetupWizard.noSizesCheckedLine,
                     LatticeSetupWizard.faceWallsLeftOutLine, LatticeSetupWizard.recheckTapBrief, LatticeSetupWizard.shapeGradeRunBrief,
                     LatticeSetupWizard.bandNoRoomLine, LatticeSetupWizard.subfloorLine, LatticeSetupWizard.typeReasonLine,
                     LatticeSetupWizard.typeCantRunLine, LatticeSetupWizard.thicknessDerivedLine, LatticeSetupWizard.autoCellLine,
                     LatticeSetupWizard.densityByStressLine, LatticeSetupWizard.perRegionLine, LatticeSetupWizard.quiltOnLine,
                     LatticeSetupWizard.quiltOffLine, LatticeSetupWizard.finishLockedLine, LatticeSetupWizard.coveredLine,
                     LatticeSetupWizard.rimGreyedBrief, LatticeSetupWizard.rimStoredBrief, LatticeSetupWizard.openFacesPreviewBrief,
                     LatticeSetupWizard.skinNotCertifiedBrief, LatticeSetupWizard.organicWholePartBrief,
                     LatticeSetupWizard.organicPartBrief, LatticeSetupWizard.latticePerAreaBrief, LatticeSetupWizard.organicAreaBrief,
                     LatticeSetupWizard.organicGroupBrief, LatticeSetupWizard.latticeAreaOwnBrief,
                     LatticeSetupWizard.latticeAreaPreviewBrief, LatticeSetupWizard.zoneRimSkinBrief("Rim"),
                     LatticeSetupWizard.zoneCoveredUnderSkinBrief, LatticeSetupWizard.zoneRimSkinNeedEngineBrief,
                     LatticeSetupWizard.zoneSkinOnSheetBrief, LatticeSetupWizard.zoneFinishPreviewBrief, LatticeSetupWizard.tabsBrief,
                     LatticeSetupWizard.strengthRunBrief, LatticeSetupWizard.strengthExportBrief, LatticeSetupWizard.strengthNotYetBrief,
                     LatticeSetupWizard.sweptLine, LatticeSetupWizard.sweptNarrowLine, LatticeSetupWizard.cellsAcrossWarnBrief,
                     LatticeSetupWizard.cutCellsOnLine, LatticeSetupWizard.cutCellsOffLine, LatticeSetupWizard.smallCellsQuiltLine,
                     LatticeSetupWizard.smallCellsOnLine, LatticeSetupWizard.smallCellsOffLine, LatticeSetupWizard.singleCellOnLine,
                     LatticeSetupWizard.singleCellOffLine, LatticeSetupWizard.typePickLine, LatticeSetupWizard.strengthBrief,
                     LatticeSetupWizard.shapeBand.brief, LatticeSetupWizard.organicBand.brief, LatticeCaptions.numberNotApplied,
                     LatticeCaptions.organicShapeOnlyBrief, LatticeCaptions.organicMeasuringBrief,
                     LatticeCaptions.organicUnmeasuredBrief, LatticeCaptions.organicCrossingNeedsSeedsBrief,
                     LatticeCaptions.organicFociBrief, LatticeTypeChange.caption, PrintParamsSheet.lineWidthCaption,
                     PrintParamsSheet.lockedCaption]
        for line in named {
            XCTAssertLessThanOrEqual(LatticeCaptions.words(line), LatticeCaptions.maxWords, "★ \(line)")
        }
        for label in OrganicSettingsHelp.entries.keys.sorted() {
            if let e = OrganicSettingsHelp.entry(label) {
                XCTAssertLessThanOrEqual(LatticeCaptions.words(e.grey), LatticeCaptions.maxWords, "★ Organic's \(label): \(e.grey)")
            }
        }
        // RED CONTROL: the paragraphs he photographed (img 87, 89, 92) are over five words — the count catches them
        for old in ["The preview shows the part's finish; Front face runs open (see Results).",
                    "Not certified yet: with no solid shell, Results shows this lattice as not accepted.",
                    "The grade, its band and the finish are this area's; the other rows are the whole part's.",
                    "The part is on Skin: its woven finish covers every zone, so a zone can't be Covered."] {
            XCTAssertGreaterThan(LatticeCaptions.words(old), LatticeCaptions.maxWords)
        }
        // the sentences they replaced are behind the (i)s, word for word
        XCTAssertEqual(LatticeSetupWizard.latticeAreaOwnLine,
                       "The grade, its band and the finish are this area's; the other rows are the whole part's.")
        XCTAssertEqual(LatticeSetupWizard.zoneCoveredUnderSkinLine,
                       "The part is on Skin: its woven finish covers every zone, so a zone can't be Covered.")
        XCTAssertEqual(LatticeCaptions.words("Auto · 0.9–3 mm → done"), 4, "the counter skips signs")
    }

    /// The end of a string literal that starts at `s.startIndex` (a `"`), past its escapes and interpolations.
    static func literalEnd(_ s: Substring) -> Substring.Index? {
        var i = s.index(after: s.startIndex)
        var depth = 0
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let n = s.index(after: i)
                if n < s.endIndex, s[n] == "(" { depth += 1; i = s.index(after: n); continue }
                i = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex; continue
            }
            if depth > 0 { if c == "(" { depth += 1 } else if c == ")" { depth -= 1 } }
            else if c == "\"" { return i }
            i = s.index(after: i)
        }
        return nil
    }
    /// An interpolation counts as one word ("\(n) cell sizes available." → "X cell sizes available.").
    static func flattenInterpolations(_ s: String) -> String {
        var out = "", depth = 0
        var chars = Array(s)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            if depth == 0, c == "\\", chars.first == "(" { depth = 1; chars = chars.dropFirst(); out += "X"; continue }
            if depth > 0 { if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }; continue }
            out.append(c)
        }
        return out
    }

    // MARK: (2) Skin on Structural

    /// ★ (2) A Structural lattice that kept single-cell members on (from Aesthetic, by a mode switch that keeps every
    /// setting) no longer locks the Finish to Skin: the page reads it off, Skin turns off, Save writes it off, the job adds no
    /// skin, and a saved project opens unlocked.
    func testSkinTurnsOffOnStructural() throws {
        var s = LatticeSettings(enabled: true)
        s.chooseLatticeType(.aesthetic)
        s.singleCellMembers = true; s.boundary = .fullSkin
        // RED CONTROL: on Aesthetic the rule holds (his 09-18)
        var ae = LatticeWizardModel(settings: s)
        XCTAssertTrue(ae.finishLockedBySingleCell, "RED CONTROL: Aesthetic locks the finish to Skin")
        XCTAssertFalse(ae.setBoundary(.none))
        XCTAssertEqual(s.jobSkinResolved, LatticeBoundaryTreatment.fullSkin.jobSkinValue)

        // the stored "on" carried to Structural (as release 20 left it: set straight, the way the old switch kept it)
        var st = s; st.stageMode = .structural
        XCTAssertTrue(st.singleCellMembers, "premise: the setting rode over to Structural")
        var m = LatticeWizardModel(settings: st)
        XCTAssertFalse(m.finishLockedBySingleCell, "★ Structural: nothing locks the Finish")
        XCTAssertTrue(m.setBoundary(.none), "★ Skin turns off")
        XCTAssertEqual(m.boundary, .none)
        m.setSingleCellMembers(true)
        XCTAssertFalse(m.singleCellMembers, "★ and cannot be turned on there")
        let saved = m.applied(to: st)
        XCTAssertFalse(saved.singleCellMembers, "★ saved off")
        XCTAssertEqual(saved.boundary, .none)
        st.boundary = .none
        XCTAssertFalse(st.singleCellMembersInEffect)
        XCTAssertEqual(st.jobSkinResolved, LatticeBoundaryTreatment.none.jobSkinValue, "★ the job adds no skin on Structural")

        // a saved project: decoding a Structural lattice with it on opens it off
        var raw = s; raw.stageMode = .structural
        let data = try JSONEncoder().encode(raw)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertFalse(back.singleCellMembers, "★ no saved project keeps him stuck")
        let aeBack = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertTrue(aeBack.singleCellMembers, "RED CONTROL: Aesthetic keeps his choice")

        // the two ways a lattice becomes Structural clear it
        var picked = s; picked.chooseLatticeType(.structural)
        XCTAssertFalse(picked.singleCellMembers, "★ the type selector")
        // the page following a mode switch made while it is open
        ae.setStage(aesthetic: false)
        XCTAssertFalse(ae.singleCellMembers); XCTAssertFalse(ae.finishLockedBySingleCell)
        XCTAssertTrue(ae.setBoundary(.covered))
    }

    @MainActor func testTheModeSwitchClearsSingleCellMembers() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.aesthetic)
        p.lattice.singleCellMembers = true
        p.switchLatticeStageMode(to: .structural)
        XCTAssertFalse(p.lattice.singleCellMembers, "★ the capsule's Structural ⇄ Aesthetic switch")
        p.switchLatticeStageMode(to: .aesthetic)
        XCTAssertEqual(p.lattice.stageMode, .aesthetic)
    }

    // MARK: (5) Allow quilt off

    /// ★ (5) Off on every new lattice, every type, Auto and Manual; the page's own setting (so Cancel and Reset all undo it);
    /// absent from an old snapshot ⇒ off.
    func testAllowQuiltIsOffByDefault() throws {
        XCTAssertFalse(LatticeSettings().allowQuilt)
        XCTAssertFalse(LatticeSettings(enabled: true).allowQuilt)
        XCTAssertFalse(LatticeWizardModel().allowQuilt)
        for id in LatticeTypeCatalog.order {
            for mode in [LatticeStageMode.structural, .aesthetic] {
                var s = LatticeSettings(enabled: true); s.chooseLatticeType(mode); s.topologyID = id
                var m = LatticeWizardModel(settings: s)
                XCTAssertFalse(m.allowQuilt, "★ \(id) \(mode)")
                m.setTopology(id == "octet" ? "kelvin" : "octet", lineWidthMM: 0.45)
                XCTAssertFalse(m.applied(to: s).allowQuilt, "★ a type change never turns it on (\(id) \(mode))")
            }
        }
        let decoded = try JSONDecoder().decode(LatticeSettings.self, from: Data("{\"enabled\":true,\"topologyID\":\"octet\"}".utf8))
        XCTAssertFalse(decoded.allowQuilt, "an old snapshot: off")
        // the page's own: on in the page reaches the settings only through Save (applied); Reset all's fresh lattice is off
        var on = LatticeWizardModel(settings: LatticeSettings(enabled: true))
        on.allowQuilt = true
        XCTAssertTrue(on.applied(to: LatticeSettings(enabled: true)).allowQuilt, "Save keeps his Manual choice")
        XCTAssertFalse(LatticeWizardModel(settings: LatticeSettings(enabled: true)).allowQuilt, "★ Reset all: off")
        // the Allow quilt switch writes the page's model, never the part's settings at the tap
        let wiz = try FlexibleSource.code("LatticeSetupWizard.swift")
        XCTAssertFalse(wiz.contains("project.lattice.allowQuilt.toggle()"), "RED CONTROL: release 20 wrote the part at the tap")
        XCTAssertTrue(wiz.contains("model.allowQuilt.toggle(); rebuild()"))
        XCTAssertTrue(wiz.contains("if !latticeManual, project.lattice.allowQuilt { project.lattice.allowQuilt = false }"),
                      "★ Save on Auto saves it off")
    }

    // MARK: (6) Stress + shape

    /// ★ (6) Every place the grade can default reads Stress + shape.
    func testTheGradeDefaultsToStressAndShape() throws {
        XCTAssertEqual(LatticeSettings().gradingMode, .full)
        XCTAssertEqual(LatticeSettings(enabled: true).gradingMode, .full)
        XCTAssertEqual(LatticeWizardModel().gradingMode, .full)
        for mode in [LatticeStageMode.structural, .aesthetic] {
            var s = LatticeSettings(enabled: true); s.chooseLatticeType(mode)
            XCTAssertEqual(LatticeWizardModel(settings: s).gradingMode, .full, "★ \(mode)")
        }
        let decoded = try JSONDecoder().decode(LatticeSettings.self, from: Data("{\"enabled\":true,\"topologyID\":\"octet\"}".utf8))
        XCTAssertEqual(decoded.gradingMode, .full, "an old snapshot")
        XCTAssertNil(LatticeAreaGrading().gradingMode, "a new group's grade is the part's")
        XCTAssertTrue(LatticeOrganicLook().followStressValue, "Organic's Gradient: Stress and shape")
        let wiz = try FlexibleSource.code("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains("model.gradingMode = on ? .full : LatticeGradingMode.none"), "Grade the lattice on: Stress + shape")
        XCTAssertTrue(wiz.contains("ForEach([LatticeGradingMode.full, .fitShape, .stressOnly]"), "Stress + shape first")
    }

    // MARK: (7) projection

    /// ★ (7) Every 3D camera follows the app's one projection; the sample's does; the view cube draws with a telephoto lens
    /// under Orthographic (its near and far faces the same size) and still picks what is under the finger.
    @MainActor func testTheProjectionDrivesTheSampleAndTheCube() throws {
        let vp = ViewProjection.shared
        let was = vp.orthographic
        defer { vp.orthographic = was }
        vp.orthographic = false
        let cam = LatticeSampleView.makeCamera()
        XCTAssertFalse(cam.camera.orthographic)
        vp.orthographic = true
        XCTAssertTrue(cam.camera.orthographic, "★ the Settings sample follows the button")
        XCTAssertTrue(LatticeSampleView.makeCamera().camera.orthographic, "★ a new sample opens in it")
        XCTAssertFalse(OrbitCameraModel().camera.orthographic, "RED CONTROL: a camera of its own stays perspective")
        // every camera the app makes follows it (none allowed out)
        for (name, code) in try sources() {
            var rest = code[...]
            while let r = rest.range(of: "OrbitCameraModel(") {
                let call = String(rest[r.lowerBound...].prefix(220))
                rest = rest[r.upperBound...]
                if call.hasPrefix("OrbitCameraModel(camera: OrbitCamera = OrbitCamera(), followsViewProjection: Bool") { continue }
                XCTAssertTrue(call.contains("followsViewProjection: true"), "★ \(name): \(call.prefix(90))")
            }
        }
        // the cube: under Orthographic a front corner and the far corner behind it draw the same distance from the centre
        func spread(_ c: GizmoConstants, _ z: Float) -> Float {
            let tf = tanf(c.fov * 0.5 * .pi / 180)
            return 1 / ((c.camZ - z) * tf)   // screen size of a unit offset at depth z
        }
        let o = GizmoConstants.projection(orthographic: true), p = GizmoConstants.projection(orthographic: false)
        XCTAssertEqual(spread(o, 1) / spread(o, -1), 1, accuracy: 0.03, "★ orthographic: near and far the same size")
        XCTAssertGreaterThan(spread(p, 1) / spread(p, -1), 1.2, "RED CONTROL: perspective draws the near face larger")
        XCTAssertEqual(spread(o, 0), spread(p, 0), accuracy: 1e-3, "the cube fills the same frame")
        let size = CGSize(width: 120, height: 120)
        for c in [o, p] {
            let hit = OrientationGizmo.pick(point: CGPoint(x: 60, y: 60), in: size, rotation: matrix_identity_float3x3, constants: c)
            XCTAssertNotEqual(hit, .miss, "★ a tap on the cube's middle lands (\(c.fov)°)")
        }
    }
}
