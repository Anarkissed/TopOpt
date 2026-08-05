// VariantIdentityTravelsTests.swift — bars A3 / L2 of task
// 2026-08-04-variant-volume-fraction-mismatch.
//
// THE DEFECT. "Lattice this variant" attached `variant.volume_fraction: 1.1` to
// the job — the LADDER RUNG. Core validates that key as a fraction in (0, 1], so
// every re-lattice of a GROWTH-ladder variant (production_growth_ladder() is
// {1.55, 1.25, 1.10}) died at schema validation in ~48 ms:
//
//     topopt-cli: job.json: "variant.volume_fraction" must be in (0, 1]
//
// The bound was doing its job. What was wrong is that a POSITION IN A LADDER was
// being carried in a field shaped like a FRACTION, and nothing anywhere asserted
// that the number travelling with a variant was that variant's own number.
//
// So these tests drive the SHIPPING PATH — a finished `OptimizeVariant` plus the
// run's retained `design.bin`, through `LatticeVariantContext.from` and
// `RelatticeJobBuilder.build`, exactly as the lattice page does — and assert the
// emitted job describes THAT variant. Not "non-zero and in range": the SAME
// number, for a reduction variant AND a growth variant.
//
// The numbers are the maintainer's own, read out of his worker directories:
//   reduction — worker job 193b605fb69d4eee, rung 0.52, achieved 0.508231173380035
//   growth    — worker job efa7cfd3b4e344c6, rung 1.10, achieved 1.0866043075327818
// The growth case is the one that could not be expressed at all before.

import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class VariantIdentityTravelsTests: XCTestCase {

    // MARK: a real design container

    /// One block of a `design.bin` v1 container (design_store.hpp). Written here
    /// rather than mocked out, because the fingerprint the job carries is read
    /// out of these very bytes — a mocked index would test the mock.
    private struct Block {
        let requested: Double
        let achieved: Double
        let fingerprint: UInt64
    }

    private func container(_ blocks: [Block], voxels: Int = 8) -> Data {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(UInt8(1))                                  // version
        d.append(contentsOf: [0, 0, 0])                // reserved
        put(Int32(2)); put(Int32(2)); put(Int32(2))    // nx, ny, nz
        put(0.0); put(0.0); put(0.0)                   // origin
        put(1.0)                                       // spacing
        put(Int32(blocks.count))
        put(Int32(0))                                  // reserved
        for b in blocks {
            put(b.requested)
            put(b.achieved)
            put(0.0); put(0.0); put(0.0)               // margins + peak stress
            put(Int32(1)); put(Int32(7))               // accepted, iterations
            put(0.0); put(1.0); put(0.0)               // applied build dir
            put(Int32(0)); put(Int32(0))               // auto-applied, baked
            put(b.fingerprint)
            put(Int64(voxels))
            for i in 0..<voxels { put(Double(i) / Double(voxels)) }
        }
        return d
    }

    private func variant(requested: Double, achieved: Double) -> OptimizeVariant {
        OptimizeVariant(
            requestedVolumeFraction: requested,
            achievedVolumeFraction: achieved,
            massGrams: 41.2, supportVolumeVoxels: 0, meshTriangleCount: 1,
            worstCaseMargin: 2.31, accepted: true, v3Passes: true,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
            vonMisesField: [1, 2, 3, 4, 5, 6, 7, 8])
    }

    private func demandField() -> LatticeDemandField {
        LatticeDemandField(vonMises: [1, 2, 3, 4, 5, 6, 7, 8],
                           nx: 2, ny: 2, nz: 2, origin: .zero, spacingMM: 1,
                           provenance: .variant(runName: "WallMount",
                                                variantIndex: 0, date: nil))
    }

    /// The maintainer's OWN retained job document, reduced to the keys core
    /// requires — same model, resolution, material and growth load case as worker
    /// job `0cc8e495de084e5d`. Complete enough that `topopt-cli` parses the bytes
    /// this builder emits from it, which is what makes the evidence below a real
    /// app→core chain rather than a shape assertion.
    private func originalJob() -> Data {
        let job: [String: Any] = [
            "mode": "minimize_plastic", "model": "WallMount_ShelfBracket.stl",
            "material": "PLA", "resolution": 128,
            "output": ["report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant"],
            // His box, verbatim — a growth ladder needs one, and the stored
            // design is indexed to the grid it expands to.
            "design_box": [
                "min": [-99.92500305175781, -196.7901153564453, -21.721759796142578],
                "max": [101.2750015258789, 10.574999809265137, 41.72175979614258],
            ],
            "loads": [
                "anchor_face_ids": [8, 14, 12],
                "groups": [["face_ids": [0], "force": [0.0, -244.65248107910156, 0.0]]],
                "build_dir": [0.0, 1.0, 0.0],
                "minimize_plastic": false,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
    }

    private func spec() -> LatticeSpec {
        LatticeSpec(topologyID: "octet", cellMM: 8, strutRadiusMM: 0.8,
                    generateRelativeDensity: 0.3, minRelativeDensity: 0.05,
                    maxRelativeDensity: 0.9, emitSTL: true, emit3MF: false,
                    regionScoped: false, skin: "diagrid",
                    minExtrudableWidthMM: 0.42, graded: false, regions: [])
    }

    /// The whole shipping path, from a finished variant to the job bytes.
    private func emittedVariantBlock(requested: Double, achieved: Double,
                                     store: Data) throws -> [String: Any] {
        let ctx = LatticeVariantContext.from(
            variant: variant(requested: requested, achieved: achieved),
            runName: "WallMount", variantIndex: 0, field: demandField(),
            artifacts: RelatticeArtifacts(jobJSON: originalJob(), designBin: store),
            unavailable: nil)
        let job = try RelatticeJobBuilder.build(original: originalJob(),
                                                variant: ctx, lattice: spec())
        let doc = try XCTUnwrap(
            JSONSerialization.jsonObject(with: job) as? [String: Any])
        return try XCTUnwrap(doc["variant"] as? [String: Any])
    }

    // MARK: A3 — the variant carries its OWN number, on both ladders

    func testAReductionVariantCarriesItsOwnAchievedFraction() throws {
        let store = container([
            Block(requested: 0.68, achieved: 0.6686514886164624, fingerprint: 1586082085246160982),
            Block(requested: 0.52, achieved: 0.508231173380035, fingerprint: 6423110329214419348),
            Block(requested: 0.38, achieved: 0.3646234676007005, fingerprint: 14798614388688252289),
        ])
        let v = try emittedVariantBlock(requested: 0.52, achieved: 0.508231173380035,
                                        store: store)
        XCTAssertEqual(v["achieved_volume_fraction"] as? Double, 0.508231173380035,
                       "A3: the SAME number, not merely one in range — this is the "
                       + "variant's own achieved fraction")
        XCTAssertEqual(v["fingerprint"] as? String, "6423110329214419348",
                       "A3: and the design named is the one that achieved it — the "
                       + "0.52 rung's block, not its neighbour's")
    }

    func testAGrowthVariantCarriesItsOwnAchievedFraction() throws {
        // The exact case that could not be submitted at all: every value here is
        // > 1, and the old job key was bounded to (0, 1].
        let store = container([
            Block(requested: 1.55, achieved: 1.5376855112224839, fingerprint: 14561760059330257218),
            Block(requested: 1.25, achieved: 1.2368710980536173, fingerprint: 9817955135575584118),
            Block(requested: 1.10, achieved: 1.0866043075327818, fingerprint: 2898949975693851963),
        ])
        let v = try emittedVariantBlock(requested: 1.10, achieved: 1.0866043075327818,
                                        store: store)
        XCTAssertEqual(v["achieved_volume_fraction"] as? Double, 1.0866043075327818,
                       "A3: a growth variant's achieved fraction is part-relative and "
                       + "exceeds 1 — it is carried as MEASURED, not clamped or "
                       + "rounded into a range it does not live in")
        XCTAssertEqual(v["fingerprint"] as? String, "2898949975693851963",
                       "A3: the 1.10 rung's design, by identity")
        XCTAssertNil(v["volume_fraction"],
                     "A2: nothing widened the (0, 1] bound — the rung simply stopped "
                     + "travelling in a key that is validated as a fraction")
    }

    /// THE APP'S ACTUAL BYTES, ON DISK, FOR CORE TO PARSE (bar L2). The two
    /// assertions above are about the dictionary; this writes the exact `Data` the
    /// lattice page submits, so the `variant` block core validates is the one this
    /// app produced and not a hand-written stand-in. `topopt-cli` is then run on
    /// it outside the test — that half is recorded in the handoff.
    func testTheEmittedJobIsWrittenForCoreToParse() throws {
        guard let dir = ProcessInfo.processInfo.environment["TOPOPT_EVIDENCE_DIR"],
              !dir.isEmpty else { return }
        let store = container([
            Block(requested: 1.55, achieved: 1.5376855112224839, fingerprint: 14561760059330257218),
            Block(requested: 1.25, achieved: 1.2368710980536173, fingerprint: 9817955135575584118),
            Block(requested: 1.10, achieved: 1.0866043075327818, fingerprint: 2898949975693851963),
        ])
        let ctx = LatticeVariantContext.from(
            variant: variant(requested: 1.10, achieved: 1.0866043075327818),
            runName: "WallMount", variantIndex: 0, field: demandField(),
            artifacts: RelatticeArtifacts(jobJSON: originalJob(), designBin: store),
            unavailable: nil)
        let job = try RelatticeJobBuilder.build(original: originalJob(),
                                                variant: ctx, lattice: spec())
        let url = URL(fileURLWithPath: dir)
            .appendingPathComponent("L2_growth_variant_job_as_the_app_emits_it.json")
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        try job.write(to: url)
        print("VARIANT-IDENTITY-EVIDENCE wrote \(url.path)")
    }

    /// The regression itself, stated as the thing that must never come back.
    func testTheLadderRungNeverTravelsAsAVolumeFraction() throws {
        let store = container([
            Block(requested: 1.10, achieved: 1.0866043075327818, fingerprint: 2898949975693851963),
        ])
        let v = try emittedVariantBlock(requested: 1.10, achieved: 1.0866043075327818,
                                        store: store)
        XCTAssertNotEqual(v["achieved_volume_fraction"] as? Double, 1.10,
                          "the RUNG (1.10) is not the FRACTION (1.0866) — attaching "
                          + "the former is exactly the defect this task fixed")
    }

    // MARK: the missing half is refused, not guessed

    func testAContainerWithoutThisRungRefusesRatherThanFallingBackToTheRung() {
        // A container whose fetch dropped this rung: there is no fingerprint to
        // name the design with, and the old code would happily have sent the rung.
        let store = container([
            Block(requested: 1.55, achieved: 1.5376855112224839, fingerprint: 14561760059330257218),
        ])
        XCTAssertThrowsError(try emittedVariantBlock(requested: 1.10,
                                                     achieved: 1.0866043075327818,
                                                     store: store),
                             "no identity for this rung ⇒ refuse; a fall-back to the "
                             + "rung is the bug, not the remedy")
    }
}
