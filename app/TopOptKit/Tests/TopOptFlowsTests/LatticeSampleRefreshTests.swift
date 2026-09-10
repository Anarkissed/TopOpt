import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE SAMPLE REFRESHES WHEN HE ASKS (his instruction, 2026-09-07): "we need to
/// have it so there is a 'Refresh Cube' button that brings in the latest modifications
/// since the previous refresh — this way we don't have to do 6 different bakes
/// simultaneously after changing 6 settings … Place it where the 'Save and Exit'
/// button currently is and move *that* to the top left corner", with a refresh icon
/// and an (i). Applies to the organic cube and to the regular lattice sample alike.
final class LatticeSampleRefreshTests: XCTestCase {

    private func wizard() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/LatticeSetupWizard.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNothingRebuildsUntilRefreshIsTapped() throws {
        let w = try wizard()
        // The trace is keyed to the refresh, not to every pick.
        XCTAssertTrue(w.contains(".task(id: sampleRefreshToken) { await loadOrganicSample(organicSamplePicks) }"),
                      "★ the cube re-traces on refresh only")
        XCTAssertFalse(w.contains(".task(id: organicSamplePicks)"),
                       "★ the old per-pick trigger is gone — it left six detached traces running")
        // The regular sample too: rebuild() only does work when forced.
        XCTAssertTrue(w.contains("private func rebuild(force: Bool = false) {"))
        XCTAssertTrue(w.contains("guard force else {\n            sampleIsStale = true\n            return\n        }"),
                      "★ a settings change marks the sample stale and waits")
        // …except the two moments that are not a settings change.
        XCTAssertTrue(w.contains(".onAppear { rebuild(force: true); frameSample() }"))
        XCTAssertTrue(w.contains(".onChange(of: model.stage) { _ in rebuild(force: true); frameSample() }"))
    }

    func testTheButtonsAreWhereHeAskedAndTheRefreshExplainsItself() throws {
        let w = try wizard()
        guard let r = w.range(of: "private var refreshSample: some View {") else {
            return XCTFail("★ there is no Refresh button")
        }
        let body = String(w[r.lowerBound...].prefix(2000))
        XCTAssertTrue(body.contains("Image(systemName: \"arrow.clockwise\")"), "★ a refresh icon")
        XCTAssertTrue(body.contains("Text(organicSampleShown ? \"Refresh cube\" : \"Refresh sample\")"),
                      "★ named for what it refreshes, on both sides")
        XCTAssertTrue(body.contains("infoButton(\"refresh\", Self.infoRefresh)"), "★ with an (i)")
        XCTAssertTrue(body.contains("sampleRefreshToken += 1"), "★ …that actually refreshes")
        XCTAssertTrue(body.contains("rebuild(force: true)"), "★ …the regular sample too")
        // Save & Exit is top-LEADING now; Refresh takes the bottom-right corner.
        guard let s = w.range(of: "private var saveAndExit: some View {") else {
            return XCTFail("Save & Exit moved out of the page")
        }
        let save = String(w[s.lowerBound...].prefix(700))
        XCTAssertTrue(save.contains("VStack {\n            HStack {\n                Button { saveAndClose() }"),
                      "★ Save & Exit is the FIRST thing in its column and row: top left")
        XCTAssertTrue(save.contains("Spacer()\n            }\n            Spacer()"),
                      "★ …with the spacers after it, not before")
        XCTAssertTrue(body.contains("Spacer()\n            HStack {\n                Spacer()"),
                      "★ Refresh is bottom right, where Save & Exit was")
    }

    /// The copy says what the button does, in his words, with no jargon.
    func testTheRefreshCopyIsPlain() throws {
        let t = LatticeSetupWizard.infoRefresh
        XCTAssertTrue(t.hasPrefix("Refresh rebuilds the sample with the settings you have entered"))
        XCTAssertTrue(t.contains("Your settings are saved whether or not you refresh"),
                      "★ nobody should fear losing a setting by not refreshing")
        for jargon in ["bake", "SDF", "march", "detached", "token", "thread"] {
            XCTAssertFalse(t.lowercased().contains(jargon.lowercased()), "no jargon: \(jargon)")
        }
    }

    /// A cube is on the stage before anything is traced.
    func testACubeIsShownBeforeTheFirstTrace() throws {
        let w = try wizard()
        XCTAssertTrue(w.contains("else { mesh = LatticeWizardSample.cube(edgeMM: OrganicSampleCube.edgeMM, at: .zero) }"),
                      "★ the plain block stands in until the traced cube lands")
        let cube = LatticeWizardSample.cube(edgeMM: OrganicSampleCube.edgeMM, at: .zero)
        XCTAssertGreaterThan(cube.vertexCount, 0)
        XCTAssertEqual(Double(cube.bounds.max.x - cube.bounds.min.x), OrganicSampleCube.edgeMM, accuracy: 1e-3)
    }
}
