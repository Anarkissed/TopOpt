import XCTest
@testable import TopOptFlows

/// ★★★ A LOADED "stepped" MUST SURVIVE THE SETTINGS PAGE (2026-08-24).
///
/// `cellTransition` was a stored field that never persisted, so it decoded to
/// `.defaultGrade` on every project load while `algorithm` decoded to what the user
/// chose — and the settings page's save then stamped
/// `algorithm = cellTransition.coreAlgorithm`, quietly turning a stepped project into
/// doubled. Measured live on his own project: project.json said `algorithm = stepped`,
/// the running preview guard said `algo='doubled'`, and the stepped preview silently
/// drew the ladder. The field is now COMPUTED over `algorithm` — one home, no drift.
final class LatticeAlgorithmPersistenceTests: XCTestCase {

    private func decoded(algorithmJSON: String) throws -> LatticeSettings {
        // A minimal snapshot the decoder accepts — every other key takes its default.
        let json = """
        {"enabled": true\(algorithmJSON)}
        """
        return try JSONDecoder().decode(LatticeSettings.self, from: Data(json.utf8))
    }

    /// The picker must read the LOADED algorithm, not a default of its own.
    func testDecodedAlgorithmDrivesThePicker() throws {
        XCTAssertEqual(try decoded(algorithmJSON: ", \"algorithm\": \"stepped\"")
                        .cellTransition, .stepped)
        XCTAssertEqual(try decoded(algorithmJSON: ", \"algorithm\": \"organic\"")
                        .cellTransition, .organicGrade)
        XCTAssertEqual(try decoded(algorithmJSON: ", \"algorithm\": \"doubled\"")
                        .cellTransition, .defaultGrade)
        // Not stated resolves to the default exactly as core resolves it.
        XCTAssertEqual(try decoded(algorithmJSON: "").cellTransition, .defaultGrade)
    }

    /// The full round trip that lost his choice: decode → open the settings page →
    /// save with no edits. The algorithm must come back out unchanged.
    func testAnUntouchedSettingsPageSaveKeepsTheAlgorithm() throws {
        let loaded = try decoded(algorithmJSON: ", \"algorithm\": \"stepped\"")
        let wizard = LatticeWizardModel(settings: loaded)
        let saved = wizard.applied(to: loaded)
        XCTAssertEqual(saved.algorithm, "stepped",
                       "an untouched save must not rewrite the algorithm")
        XCTAssertEqual(saved.cellTransition, .stepped)
    }

    /// And the setter is the picker's write path: choosing a transition IS choosing
    /// the algorithm.
    func testThePickerWritesTheAlgorithm() throws {
        var s = try decoded(algorithmJSON: ", \"algorithm\": \"stepped\"")
        s.cellTransition = .organicGrade
        XCTAssertEqual(s.algorithm, "organic")
        s.cellTransition = .defaultGrade
        XCTAssertEqual(s.algorithm, "doubled")
    }
}
