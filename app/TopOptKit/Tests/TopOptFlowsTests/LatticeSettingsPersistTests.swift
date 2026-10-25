// LatticeSettingsPersistTests — ★★★ WHAT HE CONFIGURED MUST SURVIVE THE SAVE.
//
// ★★ THE DEFECT, found on his own device (2026-08-21). `ProjectModel.snapshot` carried
//
//     lattice: lattice.enabled ? lattice : nil,
//
// so a project whose lattice page was fully set up — cell mode, density mode, per-face
// depths and roles, retention, the band — but whose `enabled` flag was still false wrote
// NO `lattice` key at all, and lost every one of those on the next load.
//
// His `M2 verticalStand THICK` had two declared regions on screen and no `lattice` block
// in its project.json, while his two older projects had full blocks. Everything he set
// on that page was being answered from DEFAULTS, which is why changing a setting could
// look like it did nothing at all — the most expensive kind of silent failure, because
// it makes every other diagnosis wrong.
//
// ★ AND THE INVARIANT THE NIL EXISTED FOR IS KEPT. Its stated purpose: "a non-lattice
// project's project.json is byte-identical to a pre-lattice one." That property is about
// a project which never TOUCHED the lattice, which is `== the default` — not about one
// that is merely not armed.

import XCTest
import simd
@testable import TopOptFlows

@MainActor
final class LatticeSettingsPersistTests: XCTestCase {

    /// `snapshot` refuses a project with no imported file, so the fixture carries one —
    /// the extension is all it reads.
    private func project() -> ProjectModel {
        ProjectModel(id: UUID(), name: "persist", material: "ABS", process: .fdm,
                     importedFile: ImportedFile(
                        name: "part.step", path: NSTemporaryDirectory() + "part.step",
                        triangleCount: 12, faceCount: 6, watertight: true),
                     importedMesh: nil)
    }

    /// ★★★ THE REGRESSION. Settings configured but not armed must still be written.
    func testConfiguredButUnarmedLatticeSettingsAreSaved() throws {
        let p = project()
        p.lattice.enabled = false                      // ← he has not armed it
        p.lattice.cellSizeMode = .auto
        p.lattice.densityMode = .sim
        p.lattice.retainSubfloorInUnloadedRegions = true
        let snap = try XCTUnwrap(p.snapshot(savedAt: Date()))
        let lat = try XCTUnwrap(
            snap.lattice,
            "★ HIS BUG: a fully configured lattice page wrote NOTHING because `enabled` "
            + "was false. Every depth, role and mode he set was discarded on save.")
        XCTAssertEqual(lat.cellSizeMode, .auto)
        XCTAssertEqual(lat.densityMode, .sim)
        XCTAssertTrue(lat.retainSubfloorInUnloadedRegions)
        XCTAssertFalse(lat.enabled, "…and `enabled` itself round-trips honestly")
    }

    /// ★ THE INVARIANT THAT LINE WAS PROTECTING, held at full strength: an UNTOUCHED
    /// project still writes no lattice block, so its file is byte-identical to a
    /// pre-lattice one.
    func testAnUntouchedProjectStillWritesNoLatticeBlock() throws {
        let p = project()
        let snap = try XCTUnwrap(p.snapshot(savedAt: Date()))
        XCTAssertNil(snap.lattice,
                     "★ a project that never touched the lattice must be byte-identical "
                     + "to a pre-lattice one — that is what the nil was for")
    }

    /// ★ AND ONE TOUCH IS ENOUGH. The test above must not pass because the default
    /// happens to compare equal to something arbitrary — change a single field and the
    /// block appears.
    func testASingleChangedFieldIsEnoughToPersist() throws {
        for mutate in [{ (s: inout LatticeSettings) in s.cellMM = 3.5 },
                       { (s: inout LatticeSettings) in s.densityMode = .uniform },
                       { (s: inout LatticeSettings) in s.boundary = .rim },
                       { (s: inout LatticeSettings) in s.enabled = true }] {
            let p = project()
            mutate(&p.lattice)
            XCTAssertNotNil(try XCTUnwrap(p.snapshot(savedAt: Date())).lattice,
                            "★ any touch at all must be written")
        }
    }

    /// ★★ AND IT SURVIVES THE ROUND TRIP, not just the snapshot — the encoder is where
    /// the value actually has to land.
    func testTheConfiguredSettingsSurviveEncodingAndDecoding() throws {
        let p = project()
        p.lattice.enabled = false
        p.lattice.cellSizeMode = .auto
        p.lattice.minRelativeDensity = 0.12
        p.lattice.maxRelativeDensity = 0.55
        let snap = try XCTUnwrap(p.snapshot(savedAt: Date()))
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        let lat = try XCTUnwrap(back.lattice, "★ the block must reach the FILE")
        XCTAssertEqual(lat.cellSizeMode, .auto)
        XCTAssertEqual(lat.minRelativeDensity, 0.12, accuracy: 1e-9)
        XCTAssertEqual(lat.maxRelativeDensity, 0.55, accuracy: 1e-9)
    }
}
