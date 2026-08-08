// LatticesAreInTheAppGateTests — THE PRECONDITION FOR TOUCHING `out/`
// (task 2026-08-08-lattice-variant-margin-tolerance, S3(a)).
//
// THE MAINTAINER'S CONDITION, IN HIS WORDS: clean up the `out/` folder "as soon
// as we have tests confirming that we have the lattices IN APP".
//
// This file is that confirmation, and it is deliberately ONE test with a name
// that can be cited in a cleanup PR:
//
//     testEveryLatticeAnOptimizeRunProducedIsListedWeighedAndExportable
//
// It drives his own run — worker job ca62f91cba4b422d, four rungs, four
// lattices — through the app's REAL `RemoteRun` against a real HTTP socket, and
// for EVERY rung asserts the three things "in app" has to mean before anything on
// a disk is deleted:
//
//   LISTED     the lattice appears in the variant list as its own selectable
//              object, tied to the rung that produced it;
//   WEIGHED    it carries its OWN mass — core's `lattice_mass_grams` from that
//              rung's certification receipt — and never the solid's;
//   EXPORTABLE tapping Export on it writes THAT rung's latticed file to disk,
//              byte for byte, under a filename that cannot collide with the
//              solid's.
//
// All four, not the selected one and not a sample. A cleanup justified by "the
// lattices are in the app" is only as good as the weakest rung.
//
// It is NOT a claim that the mesh can be DISPLAYED — PR 311 measured that his
// iPad cannot hold any of the four, and export deliberately does not depend on
// display. "Reachable" here means listed, weighed and exportable, which is what
// the cleanup's safety actually rests on.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticesAreInTheAppGateTests: XCTestCase {

    /// *** THE GATE. *** Cite this test by name.
    @MainActor
    func testEveryLatticeAnOptimizeRunProducedIsListedWeighedAndExportable() throws {
        try HisRunReplay.withLiveWorker { model, filesDir in
            // ── LISTED ──────────────────────────────────────────────────────
            let latticed = model.tabs.filter { $0.isLatticed }
            XCTAssertEqual(latticed.count, 4,
                           "his run produced four lattices; all four are in the list")
            let solids = model.tabs.filter { !$0.isLatticed }
            XCTAssertEqual(solids.count, 4, "…beside their four solids")
            for tab in latticed {
                XCTAssertTrue(solids.contains { $0.variantIndex == tab.variantIndex },
                              "each lattice names the rung that produced it")
            }

            // ── WEIGHED, with its OWN mass ──────────────────────────────────
            // From `lattice_mass_grams` in each rung's own certification receipt —
            // core's accounting of the object it certified, never the solid's mass
            // under a different label.
            let expected: [Double: Double] = [0.68: 215.16, 0.52: 239.93,
                                              0.38: 244.78, 0.26: 246.38]
            for tab in latticed {
                let alt = try XCTUnwrap(tab.latticeAlternative)
                let want = try XCTUnwrap(expected[
                    (alt.requestedVolumeFraction * 100).rounded() / 100])
                let solid = try XCTUnwrap(
                    solids.first { $0.variantIndex == tab.variantIndex })
                XCTAssertEqual(tab.massGrams, want, accuracy: 0.01,
                               "rung \(alt.requestedVolumeFraction) weighs its own mass")
                XCTAssertNotEqual(tab.massGrams, solid.massGrams,
                                  "…which is NOT the solid's")
                XCTAssertEqual(tab.massLabel, ResultsModel.massLabel(want),
                               "…and the label is that mass, not \"n/a\" and not 0.0 g")
            }

            // ── EXPORTABLE, every one of them ───────────────────────────────
            // POSITIVE CONTROL FIRST. The four latticed files the worker serves are
            // pairwise DIFFERENT bytes at the same length, so "the export matched
            // its source" below cannot pass by exporting the wrong rung's file —
            // which is the failure mode that cost the maintainer a night in the
            // first place, in its cheapest-to-catch form.
            var served: [Data] = []
            for vf in HisRunReplay.rungs {
                served.append(try Data(contentsOf: filesDir.appendingPathComponent(
                    "variant_\(HisRunReplay.tag(for: vf))_lattice.stl")))
            }
            for i in served.indices {
                for j in served.indices where j > i {
                    XCTAssertNotEqual(served[i], served[j],
                                      "the fixture's rungs are distinguishable by "
                                      + "content, so a wrong-rung export cannot pass")
                }
            }

            var writtenNames: Set<String> = []
            for tab in latticed {
                model.select(tab.index)
                let alt = try XCTUnwrap(model.selectedLattice)
                XCTAssertTrue(model.canExport,
                              "export is offered for a latticed selection even when "
                              + "its geometry was never transferred")
                XCTAssertTrue(model.exportIsStreamed,
                              "…and it streams from the worker rather than "
                              + "re-serialising buffers the app does not hold")
                XCTAssertTrue(model.exportFilename.hasSuffix("-latticed.stl"),
                              "the filename says which object: \(model.exportFilename)")
                XCTAssertTrue(writtenNames.insert(model.exportFilename).inserted,
                              "…and cannot collide with another rung's: "
                              + model.exportFilename)

                let done = expectation(description: "export \(alt.meshName)")
                var url: URL?
                var failure: String?
                model.exportLatticedMesh { _, _ in } completion: { result in
                    switch result {
                    case .success(let u): url = u
                    case .failure(let e): failure = e.localizedDescription
                    }
                    done.fulfill()
                }
                wait(for: [done], timeout: 60)
                XCTAssertNil(failure, "export of \(alt.meshName) failed: \(failure ?? "")")
                let wrote = try XCTUnwrap(url)
                defer { try? FileManager.default.removeItem(at: wrote) }
                let got = try Data(contentsOf: wrote)
                let want = try Data(contentsOf: filesDir.appendingPathComponent(alt.meshName))
                XCTAssertEqual(got, want,
                               "the export is \(alt.meshName), byte for byte — not "
                               + "the solid's mesh and not another rung's")
            }
            XCTAssertEqual(writtenNames.count, 4,
                           "four rungs exported four distinct latticed files")
        }
    }

    /// The other half of the same gate, and the reason a cleanup cannot lean on the
    /// solid's export path: `exportSTLData()` — the in-memory serialiser a caller
    /// might reach for by habit — returns NOTHING for a latticed selection, so a
    /// caller that forgot to branch produces no file rather than the solid's mesh
    /// under the lattice's name.
    @MainActor
    func testTheLatticedExportCannotSilentlyBecomeTheSolids() throws {
        try HisRunReplay.withLiveWorker { model, _ in
            let latticed = try XCTUnwrap(model.tabs.first { $0.isLatticed })
            model.select(latticed.index)
            XCTAssertNil(model.exportSTLData(),
                         "the in-memory path must refuse a latticed selection")
            XCTAssertNil(model.selectedMesh,
                         "and the viewer draws nothing rather than the solid")
        }
    }
}
