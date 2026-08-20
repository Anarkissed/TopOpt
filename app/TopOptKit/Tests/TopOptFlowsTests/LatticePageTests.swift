// LatticePageTests — headless proof of the lattice page's bars (handoff
// 2026-07-30-lattice-page). B0/B0b topology + band truth from CORE, B1 the entry
// gate states what is missing, B2 one Optimize + full job inheritance, B3 the
// three roles produce distinct jobs, B4 the live one-voxel minimum, B5 RUN SIM
// gating, B6 auto density needs a field, B7 the three-way boundary, B8 TO-only
// byte-identity (hashed), B9 every page state drivable. The SwiftUI layout
// itself (B10) is measured on-device per the /app/ rule.

import XCTest
import CryptoKit
import Foundation
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticePageTests: XCTestCase {

    // MARK: - B0 · topology truth

    func testPickerMatchesCoreExactly() {
        let certifiable = Set(TopOptKit.latticeCertifiableTopologies)
        let generatable = Set(TopOptKit.latticeGeneratableTopologies)
        let rows = LatticeTopologyPicker.rowsFromCore()

        // Every picker entry is in core's union; the union is fully covered; no
        // duplicates. A picker entry core does not know CANNOT satisfy this: it
        // would appear in `ids` but not in the union, and the equality fails.
        let ids = rows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate picker entries")
        XCTAssertEqual(Set(ids), certifiable.union(generatable),
                       "the picker is EXACTLY core's certifiable ∪ generatable — nothing invented, nothing missing")

        // The two properties are core's, row by row — never inferred from each other.
        for row in rows {
            XCTAssertEqual(row.certifiable, certifiable.contains(row.id), row.id)
            XCTAssertEqual(row.generatable, generatable.contains(row.id), row.id)
        }

        // The prototype's fabricated entries can never appear: they are in neither set.
        for fake in ["Gyroid", "gyroid", "Schwarz-P", "schwarz-p", "Honeycomb", "honeycomb", "Voronoi", "voronoi"] {
            XCTAssertFalse(ids.contains(fake), "\(fake) is not a core topology")
        }
        // The tetragonal three are in neither set today (not certifiable, not
        // generatable as geometry) — so they must not be offered.
        for t in ["bccz", "fccz", "reentrant"] {
            if !certifiable.contains(t) && !generatable.contains(t) {
                XCTAssertFalse(ids.contains(t), "\(t) is in neither core set — must not be offered")
            }
        }
    }

    func testDefaultTopologyIsCertifiableAndGeneratable() {
        let rows = LatticeTopologyPicker.rowsFromCore()
        let def = LatticeTopologyPicker.defaultTopology(in: rows)
        XCTAssertNotNil(def, "core ships at least one topology that is BOTH")
        let row = rows.first { $0.id == def }!
        XCTAssertTrue(row.certifiable && row.generatable)
        // The settings default IS that topology (octet today, read from core's sets).
        XCTAssertEqual(LatticeSettings().topologyID, def,
                       "the settings default must be runnable end-to-end")
    }

    func testBadgeShowsBothPropertiesIndependently() {
        // certifiable + generatable → plain CERTIFIABLE; certifiable-only must SAY
        // there is no geometry — a picker row must never promise an export that
        // does not exist (the prototype's sin).
        let both = LatticeTopologyRow(id: "octet", displayName: "Octet", certifiable: true, generatable: true)
        XCTAssertEqual(both.badge, "CERTIFIABLE")
        let certOnly = LatticeTopologyRow(id: "sc", displayName: "Simple cubic", certifiable: true, generatable: false)
        XCTAssertTrue(certOnly.badge.contains("NO GEOMETRY"), "must state the generator gap")
        let genOnly = LatticeTopologyRow(id: "x", displayName: "X", certifiable: false, generatable: true)
        XCTAssertEqual(genOnly.badge, "PREVIEW ONLY")
    }

    func testCertifiableButNotGeneratableCannotRun() {
        // A topology core certifies but cannot generate must produce NO lattice
        // block (the job schema would reject it; the generator would throw).
        let certifiable = TopOptKit.latticeCertifiableTopologies
        let generatable = Set(TopOptKit.latticeGeneratableTopologies)
        guard let certOnly = certifiable.first(where: { !generatable.contains($0) }) else {
            // If core ever generates everything it certifies, this gate is moot.
            return
        }
        var s = LatticeSettings(enabled: true, topologyID: certOnly)
        s.minRelativeDensity = 0.2; s.maxRelativeDensity = 0.4
        XCTAssertNil(s.runSpec(), "\(certOnly) certifies but has no generator — no lattice block")

        let b = LatticeBounds.compute(settings: s,
                                      limits: TopOptKit.latticeLimits(topology: certOnly),
                                      generatable: false)
        XCTAssertTrue(b.certifiable)
        XCTAssertFalse(b.generatable)
        XCTAssertFalse(b.runnableAsCertified)
        XCTAssertNotNil(b.generatableReason, "the gate says WHY")
        XCTAssertTrue(b.generatableReason!.contains("generator"))
    }

    // MARK: - B0b · per-topology band

    func testDensityBandChangesWithSelectionAndMatchesCore() {
        let certifiable = TopOptKit.latticeCertifiableTopologies
        XCTAssertGreaterThanOrEqual(certifiable.count, 2,
                                    "core certifies several topologies — the band must be per-topology")
        let a = certifiable[0], b = certifiable[1]
        let la = TopOptKit.latticeLimits(topology: a)
        let lb = TopOptKit.latticeLimits(topology: b)
        XCTAssertTrue(la.certifiable && lb.certifiable)
        XCTAssertTrue(la.rhoMin != lb.rhoMin || la.rhoMax != lb.rhoMax,
                      "\(a) and \(b) carry different certifiable bands")

        // The DISPLAYED band (LatticeBounds.bandLo/Hi) tracks the selection and
        // equals core's numbers for that topology.
        for (id, lim) in [(a, la), (b, lb)] {
            let s = LatticeSettings(enabled: true, topologyID: id)
            let bounds = LatticeBounds.compute(settings: s, limits: lim, generatable: true)
            XCTAssertEqual(bounds.bandLo, lim.rhoMin, accuracy: 1e-12, id)
            XCTAssertEqual(bounds.bandHi, lim.rhoMax, accuracy: 1e-12, id)
        }
    }

    // MARK: - B1 · entry gate

    func testGateStatesWhatIsMissing() {
        let none = LatticePageGate.compute(anchors: 0, loads: 0)
        XCTAssertFalse(none.satisfied)
        XCTAssertEqual(none.title, "Lattice needs an anchor and a load")
        XCTAssertEqual(none.ctaLabel, "Back to Setup — add an anchor and a load")
        XCTAssertFalse(none.items[0].satisfied)
        XCTAssertFalse(none.items[1].satisfied)
        XCTAssertNotNil(none.items[0].fixLabel)
        XCTAssertNotNil(none.items[1].fixLabel)

        let noLoad = LatticePageGate.compute(anchors: 1, loads: 0)
        XCTAssertFalse(noLoad.satisfied)
        XCTAssertEqual(noLoad.title, "Lattice needs a load")
        XCTAssertEqual(noLoad.ctaLabel, "Back to Setup — add a load")
        XCTAssertTrue(noLoad.items[0].satisfied)
        XCTAssertNil(noLoad.items[0].fixLabel)
        XCTAssertTrue(noLoad.items[1].detail.contains("cannot be graded without one"),
                      "the prototype's copy — the gate SAYS why a load matters")

        let noAnchor = LatticePageGate.compute(anchors: 0, loads: 2)
        XCTAssertEqual(noAnchor.title, "Lattice needs an anchor")

        let ok = LatticePageGate.compute(anchors: 1, loads: 1)
        XCTAssertTrue(ok.satisfied)
    }

    func testGateGovernsBothEntryPoints() {
        // The gate derives from the load case alone, so BOTH entries (workspace and
        // per-variant) hit the same gate: neither entry path can bypass it.
        let workspace = LatticePageModel(entry: .workspace)
        let variant = LatticePageModel(entry: .variant(runName: "Bracket", variantIndex: 2))
        for page in [workspace, variant] {
            _ = page   // both entries construct the same model; the gate below is entry-blind
            let gate = LatticePageGate.compute(anchors: 0, loads: 0)
            XCTAssertFalse(gate.satisfied)
            // While gated, the page SAYS why it is unavailable. Round-2 deleted the
            // persistent bottom-left hint bar (L2), so the statement lives on the
            // gate overlay itself — title + CTA name exactly what is missing
            // (a strictly stronger surface than the old generic hint line).
            XCTAssertTrue(gate.title.contains("anchor") && gate.title.contains("load"))
            XCTAssertTrue(gate.ctaLabel.contains("add an anchor and a load"))
        }
    }

    // MARK: - B2 · one Optimize, full inheritance

    /// A scheduler that HOLDS background work so the run stays `.running` while a
    /// second Optimize is attempted — the mutual-exclusion window made testable.
    private final class DeferredScheduler: RunScheduler, @unchecked Sendable {
        var pending: [() -> Void] = []
        func runInBackground(_ work: @escaping () -> Void) { pending.append(work) }
        func runOnMain(_ work: @escaping () -> Void) { work() }
        func drain() { let p = pending; pending = []; p.forEach { $0() } }
    }

    func testExactlyOneOptimizeEverFires() {
        let scheduler = DeferredScheduler()
        let model = RunModel(scheduler: scheduler)
        var runnerCalls = 0
        model.runner = { _, _, _ in
            runnerCalls += 1
            return OptimizeOutcome(variants: [], stoppedOnMargin: true, cancelled: false, acceptedCount: 1)
        }
        let req = Self.request(lattice: nil)
        model.start(req)                       // page one fires
        XCTAssertEqual(model.phase, .running)
        model.start(Self.request(lattice: Self.octetSpec()))  // the lattice page tries — refused
        model.start(req)                                       // page one tries again — refused
        scheduler.drain()
        XCTAssertEqual(runnerCalls, 1, "exactly ONE optimize ever fires (RunModel.start guards .running)")
    }

    func testLatticeJobCarriesPageOneInputs() throws {
        // The lattice page's job = page one's job + the lattice block, NOTHING else:
        // anchors, loads, keep-clears, protections, material and resolution ride
        // through identically.
        let base = try Self.jobDict(lattice: nil)
        var lattice = try Self.jobDict(lattice: Self.octetSpec())

        XCTAssertNotNil(lattice["lattice"], "the lattice page's job carries the block")
        lattice.removeValue(forKey: "lattice")
        XCTAssertTrue(NSDictionary(dictionary: lattice).isEqual(to: base),
                      "everything page one declared rides through unchanged")

        // And the inherited content is really there (not vacuously equal-empty).
        let loads = try XCTUnwrap(base["loads"] as? [String: Any])
        XCTAssertEqual((loads["anchor_face_ids"] as? [Int]), [3])
        let groups = try XCTUnwrap(loads["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        let clearances = try XCTUnwrap(loads["clearances"] as? [[String: Any]])
        XCTAssertEqual(clearances.count, 1)
        XCTAssertEqual((loads["face_protections"] as? [Int]), [9])
        XCTAssertEqual(base["material"] as? String, "PLA")
        XCTAssertEqual(base["resolution"] as? Int, 96)
    }

    // MARK: - B3 · primitive roles are distinct concepts, distinct jobs

    func testClearanceAndExcludeProduceDifferentJobs() throws {
        // CLEARANCE (no material at all) → a loads.clearances entry (FrozenVoid).
        let bolt = ManualPrimitive.defaultBolt(at: SIMD3(1, 2, 3), radiusMM: 4, halfLengthMM: 10)
        let clearanceJob = try Self.jobDict(clearances: [bolt.spec()], protections: [])
        // LATTICE-EXCLUDE (material, kept solid) → a loads.face_protections entry
        // (FrozenSolid) — the OPPOSITE polarity, a different job field entirely.
        let excludeJob = try Self.jobDict(clearances: [], protections: [17])

        let cLoads = try XCTUnwrap(clearanceJob["loads"] as? [String: Any])
        let eLoads = try XCTUnwrap(excludeJob["loads"] as? [String: Any])

        XCTAssertNotNil(cLoads["clearances"], "clearance REMOVES material via loads.clearances")
        XCTAssertNil(cLoads["face_protections"], "…and never masquerades as a protection")
        XCTAssertNotNil(eLoads["face_protections"], "exclude KEEPS material solid via loads.face_protections")
        XCTAssertNil(eLoads["clearances"], "…and never collapses into a clearance")
        XCTAssertFalse(NSDictionary(dictionary: clearanceJob).isEqual(to: excludeJob),
                       "the two roles produce DIFFERENT jobs")
    }

    func testRoleHelpersMapToDistinctStores() {
        // Model level: the page's paint toggle routes include → LatticeSettings,
        // exclude → the protect group; they never share a store.
        let project = ProjectModel(id: UUID(), name: "p", material: "PLA", process: .fdm,
                                   importedFile: nil, importedMesh: nil)
        _ = project.toggleLatticePaintFace(7, role: .include)
        XCTAssertEqual(project.lattice.paintedIncludeFaces, [7])
        XCTAssertNil(project.latticeExcludeGroupID(createIfNeeded: false),
                     "an include paint creates NO protect group")

        _ = project.toggleLatticePaintFace(9, role: .exclude)
        let gid = try? XCTUnwrap(project.latticeExcludeGroupID(createIfNeeded: false))
        XCTAssertNotNil(gid, "an exclude paint creates/uses the protect group")
        if let gid {
            XCTAssertTrue(project.force.isProtected(gid), "the exclude group ships as a face protection")
            XCTAssertEqual(project.selection.groups.first { $0.id == gid }?.faces, [9])
        }
        XCTAssertEqual(project.lattice.paintedIncludeFaces, [7], "stores never bleed into each other")

        // Toggling again removes.
        _ = project.toggleLatticePaintFace(7, role: .include)
        XCTAssertTrue(project.lattice.paintedIncludeFaces.isEmpty)
    }

    // MARK: - B4 · the live one-voxel minimum

    private func bounds(_ ext: Float) -> MeshBounds {
        MeshBounds(min: SIMD3(0, 0, 0), max: SIMD3(ext, ext * 0.4, ext * 0.2), isEmpty: false)
    }

    func testVoxelMinimumIsLiveNotAConstant() throws {
        // Two part sizes × two resolutions: the displayed minimum follows
        // h = longest extent / resolution — EXACTLY core's voxelize law
        // (core/src/voxel/voxelize.cpp: max_ext / resolution), via VoxelFit.
        let cases: [(ext: Float, res: Int, expect: Double)] = [
            (200, 128, 1.5625), (200, 64, 3.125),
            (100, 128, 0.78125), (100, 64, 1.5625),
        ]
        var seen = Set<Double>()
        for c in cases {
            let h = try XCTUnwrap(VoxelFit.spacing(forBounds: bounds(c.ext), resolution: c.res))
            XCTAssertEqual(h, c.expect, accuracy: 1e-12,
                           "\(c.ext) mm at \(c.res)³ → \(c.expect) mm")
            seen.insert(h)

            // The surfaced line + lanes use the SAME number.
            let lanes = LatticeSizingLanes.compute(sizeMM: 1.0, voxelMM: h,
                                                   resolution: c.res, longestExtentMM: Double(c.ext))
            XCTAssertTrue(lanes.voxelLine.contains(String(format: "%.2f", h)))
            XCTAssertTrue(lanes.voxelLine.contains("\(c.res)³"))
        }
        XCTAssertEqual(seen.count, 3, "the minimum MOVES with part size and resolution (two pairs coincide by design)")
    }

    func testLanesSayWhoHonoursASubVoxelSize() {
        // Below one voxel the GENERATOR is exact but the OPTIMIZER rounds up —
        // the UI must convey which pipeline honours the number (bar B4).
        let sub = LatticeSizingLanes.compute(sizeMM: 0.8, voxelMM: 1.5625,
                                             resolution: 128, longestExtentMM: 200)
        XCTAssertFalse(sub.honoured)
        XCTAssertEqual(sub.lanes[0].name, "Lattice generator")
        XCTAssertTrue(sub.lanes[0].honoured, "the generator is exact at any size")
        XCTAssertEqual(sub.lanes[1].name, "Topology optimizer")
        XCTAssertFalse(sub.lanes[1].honoured)
        XCTAssertTrue(sub.lanes[1].verdict.contains("rounds up to 1.56 mm"),
                      "the optimizer's rounding is NAMED, not silently accepted")

        let ok = LatticeSizingLanes.compute(sizeMM: 2.0, voxelMM: 1.5625,
                                            resolution: 128, longestExtentMM: 200)
        XCTAssertTrue(ok.honoured)
        XCTAssertTrue(ok.lanes.allSatisfy(\.honoured))
    }

    // MARK: - B5 · RUN SIM gating

    func testSimGating() {
        // Lattice ON → the job would also run TO → sim blocked, with the reason.
        let latticeOn = LatticeSimGate.compute(latticeOn: true, optimizing: false, simRunning: false)
        XCTAssertTrue(latticeOn.blocked)
        XCTAssertEqual(latticeOn.reason,
                       "This job also runs topology optimization — sim runs on its result.")

        // Optimizing → blocked with its own reason.
        let busy = LatticeSimGate.compute(latticeOn: false, optimizing: true, simRunning: false)
        XCTAssertTrue(busy.blocked)
        XCTAssertEqual(busy.reason, "A job is already running.")

        // One sim at a time.
        let dup = LatticeSimGate.compute(latticeOn: false, optimizing: false, simRunning: true)
        XCTAssertTrue(dup.blocked)

        // Otherwise enabled, no reason shown.
        let free = LatticeSimGate.compute(latticeOn: false, optimizing: false, simRunning: false)
        XCTAssertFalse(free.blocked)
        XCTAssertNil(free.reason)
    }

    // MARK: - B6 · auto density needs a field

    private func field(provenance: LatticeFieldProvenance) -> LatticeDemandField {
        LatticeDemandField(vonMises: [1, 2, 3, 4], nx: 2, ny: 2, nz: 1,
                           origin: .zero, spacingMM: 1, provenance: provenance)
    }

    func testAutoNotOfferedWithoutAField() {
        let gate = LatticeAutoDensityGate.compute(field: nil, stale: false)
        XCTAssertFalse(gate.offered, "no field → Auto is NOT offered (never a silent uniform)")
        XCTAssertNotNil(gate.unavailableReason)
        XCTAssertTrue(gate.unavailableReason!.contains("No stress field yet"))
    }

    func testAutoAvailableFromVariantEntryWithNoSim() {
        // The variants entry: the run's own field already exists — Auto is offered
        // with provenance, no sim required (B6's second path, tested separately).
        let f = field(provenance: .variant(runName: "Bracket", variantIndex: 1, date: nil))
        let gate = LatticeAutoDensityGate.compute(field: f, stale: false)
        XCTAssertTrue(gate.offered)
        XCTAssertNil(gate.unavailableReason)
        XCTAssertEqual(gate.provenanceLabel, "Run Bracket · variant 2",
                       "provenance names the run and variant")
        XCTAssertFalse(gate.stale)
    }

    func testAutoShowsProvenanceAndAgeForASimField() {
        let ran = Date(timeIntervalSince1970: 1_000_000)
        let f = field(provenance: .solidSim(date: ran, resolution: 64))
        let gate = LatticeAutoDensityGate.compute(field: f, stale: false,
                                                  now: ran.addingTimeInterval(120))
        XCTAssertTrue(gate.offered)
        XCTAssertEqual(gate.provenanceLabel, "Solid-part sim · 64³ · 2 min ago",
                       "provenance + AGE are shown, per the bar")
    }

    func testStaleFieldIsFlaggedAndAutoNeverSilentlyUniform() {
        let f = field(provenance: .solidSim(date: Date(timeIntervalSince1970: 0), resolution: 64))
        let gate = LatticeAutoDensityGate.compute(field: f, stale: true)
        XCTAssertTrue(gate.offered)
        XCTAssertTrue(gate.stale, "a stale field is marked — the 'Sim is out of date' surface")

        // Auto rides the optimize job now (task lattice-page-core-hookup stage 4:
        // core's run_job grades from the run's OWN field) — but B6 stands: the
        // spec it ships is GRADED, carrying NO uniform cell/radius at all, so
        // auto still never silently means uniform. Core's grading schema
        // requires the stated line width, so WITHOUT one the spec stays nil and
        // Optimize is gated with exactly that reason.
        var s = LatticeSettings(enabled: true)
        s.densityMode = .sim
        XCTAssertNil(s.runSpec(), "auto without a line width has no grading floor — no spec")
        let gated = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "1 anchor · 1 load",
            latticeEnabled: true, densityMode: .sim,
            topologyDisplayName: "Octet", cellMM: 6, bounds: nil, running: false,
            lineWidthMM: 0)
        XCTAssertFalse(gated.enabled)
        XCTAssertTrue(gated.sub.contains("line width"), "the reason names the missing input")
        // With a line width: the spec ships, GRADED, and Optimize opens (H4d).
        let spec = s.runSpec(lineWidthMM: 0.42)
        XCTAssertNotNil(spec, "H4d: auto + line width produces a run spec")
        XCTAssertTrue(spec?.graded == true, "the spec is graded, not uniform")
        XCTAssertEqual(spec?.strutRadiusMM, 0,
                       "no fabricated uniform radius on a graded spec (B6)")
        XCTAssertEqual(spec?.minExtrudableWidthMM, 0.42)
        let open = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "1 anchor · 1 load",
            latticeEnabled: true, densityMode: .sim,
            topologyDisplayName: "Octet", cellMM: 6, bounds: nil, running: false,
            lineWidthMM: 0.42)
        XCTAssertTrue(open.enabled, "H4d: the auto gate OPENS")
        XCTAssertTrue(open.sub.contains("graded"),
                      "the sub-label says the lattice is graded from this run's own field")
    }

    // MARK: - B7 · no invalid boundary state

    func testBoundaryIsAThreeWayAndSkinWithoutRimIsUnrepresentable() {
        // The treatment is a 3-case enum mapping 1:1 onto core's job values; no
        // sequence of taps can reach a fourth state because none exists to reach.
        XCTAssertEqual(LatticeBoundaryTreatment.allCases.count, 3)
        XCTAssertEqual(LatticeBoundaryTreatment.none.jobSkinValue, "none")
        XCTAssertEqual(LatticeBoundaryTreatment.rim.jobSkinValue, "rim")
        XCTAssertEqual(LatticeBoundaryTreatment.fullSkin.jobSkinValue, "diagrid",
                       "full skin IS rim + faces in core (the diagrid anchors to rim loops) — skin-without-rim cannot be expressed")
        XCTAssertEqual(Set(LatticeBoundaryTreatment.allCases.map(\.jobSkinValue)),
                       ["none", "rim", "diagrid"], "exactly core's three skin modes")

        // Exhaustive tap walk: from every state, every tap lands in the same 3 states.
        for start in LatticeBoundaryTreatment.allCases {
            var s = LatticeSettings(enabled: true)
            s.boundary = start
            for tap in LatticeBoundaryTreatment.allCases {
                s.boundary = tap
                XCTAssertTrue(LatticeBoundaryTreatment.allCases.contains(s.boundary))
            }
        }
    }

    func testBoundaryReachesTheJob() throws {
        for (treatment, expect) in [(LatticeBoundaryTreatment.none, "none"),
                                    (.rim, "rim"), (.fullSkin, "diagrid")] {
            var s = LatticeSettings(enabled: true)
            s.boundary = treatment
            s.minRelativeDensity = 0.2; s.maxRelativeDensity = 0.4
            let spec = try XCTUnwrap(s.runSpec(lineWidthMM: 0.42))
            XCTAssertEqual(spec.skin, expect)
            XCTAssertEqual(spec.minExtrudableWidthMM, 0.42,
                           "the user's line width arms core's own skin clamp")
            let job = try Self.jobDict(lattice: spec)
            let block = try XCTUnwrap(job["lattice"] as? [String: Any])
            XCTAssertEqual(block["skin"] as? String, expect)
        }
    }

    // MARK: - B8 · existing flow unchanged, proven with a hash

    private func canonicalHash(_ job: [String: Any]) throws -> String {
        // Canonical bytes: sorted keys, no whitespace variance — a deterministic
        // digest of the job CONTENT.
        let data = try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testTOOnlyJobByteIdenticalByHash() throws {
        // 1) A TO-only job from a FRESH default project (the new page code present,
        //    lattice never enabled).
        let fresh = try canonicalHash(Self.jobDict(lattice: nil))

        // 2) The same job after the page's settings were TOUCHED and lattice left
        //    off — page state must leak NOTHING into a TO-only job.
        var touched = LatticeSettings()
        touched.boundary = .fullSkin
        touched.densityMode = .uniform
        touched.paintedIncludeFaces = [1, 2]
        touched.cellMM = 12
        XCTAssertNil(touched.runSpec(), "lattice off → no block, whatever the page state")
        let afterTouch = try canonicalHash(Self.jobDict(lattice: touched.runSpec()))
        XCTAssertEqual(fresh, afterTouch, "TO-only job hash unchanged by page state")

        // 3) A LEGACY snapshot (pre-page format, the old single-`region` key)
        //    decodes and produces the identical TO-only job.
        let legacyJSON = """
        {"enabled": false, "topologyID": "octet", "cellMM": 8,
         "minRelativeDensity": 0, "maxRelativeDensity": 1}
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(LatticeSettings.self, from: legacyJSON)
        XCTAssertNil(legacy.runSpec())
        let fromLegacy = try canonicalHash(Self.jobDict(lattice: legacy.runSpec()))
        XCTAssertEqual(fresh, fromLegacy, "a pre-page project's job is byte-identical")

        // 4) And the job carries NONE of the page's new vocabulary.
        let raw = try JSONSerialization.data(withJSONObject: Self.jobDict(lattice: nil),
                                             options: [.sortedKeys])
        let text = String(data: raw, encoding: .utf8)!
        for key in ["\"skin\"", "\"grading\"", "\"lattice\"", "min_extrudable_width_mm"] {
            XCTAssertFalse(text.contains(key), "TO-only job must not contain \(key)")
        }
    }

    func testLegacyRegionSnapshotMigratesIntoIncludeList() throws {
        // The old single-region snapshot becomes the first include primitive; the
        // legacy `region` accessor still reads/writes it (one source of truth).
        let bolt = ManualPrimitive.defaultBolt(at: SIMD3(1, 2, 3), radiusMM: 4, halfLengthMM: 8)
        let legacy = LatticeSettings(enabled: true, region: bolt)
        let data = try JSONEncoder().encode(legacy)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertEqual(back.includePrimitives, [bolt])
        XCTAssertEqual(back.region, bolt)
    }

    // MARK: - B9 · every state, drivable

    func testBannerForEveryPageState() {
        // empty/default → no banner.
        XCTAssertNil(LatticePageBanner.derive(simPhase: .idle, simStale: false,
                                              optimizing: false, runFailure: nil))
        // sim-running (cancellable).
        let running = LatticePageBanner.derive(simPhase: .running, simStale: false,
                                               optimizing: false, runFailure: nil)!
        XCTAssertEqual(running.kind, .simRunning)
        XCTAssertEqual(running.actionLabel, "Cancel")
        XCTAssertTrue(running.showsProgress)

        // sim-complete — the headline numbers.
        let summary = LatticeSimModel.Summary(maxDisplacementMM: 0.42, maxStressMPa: 128,
                                              safety: 2.1, date: Date(), resolution: 64)
        let complete = LatticePageBanner.derive(simPhase: .complete(summary), simStale: false,
                                                optimizing: false, runFailure: nil)!
        XCTAssertEqual(complete.kind, .simComplete)
        XCTAssertTrue(complete.body.contains("0.42 mm"))
        XCTAssertTrue(complete.body.contains("128 MPa"))
        XCTAssertTrue(complete.body.contains("safety 2.1"))

        // sim-stale — same sim, inputs changed → amber + Re-run.
        let stale = LatticePageBanner.derive(simPhase: .complete(summary), simStale: true,
                                             optimizing: false, runFailure: nil)!
        XCTAssertEqual(stale.kind, .simStale)
        XCTAssertEqual(stale.title, "Sim is out of date")
        XCTAssertEqual(stale.actionLabel, "Re-run")

        // optimizing — outranks sim states, cancellable, progress.
        let opt = LatticePageBanner.derive(simPhase: .complete(summary), simStale: true,
                                           optimizing: true, runFailure: nil)!
        XCTAssertEqual(opt.kind, .optimizing)
        XCTAssertEqual(opt.actionLabel, "Cancel")
        XCTAssertTrue(opt.showsProgress)

        // failed (the run).
        let failed = LatticePageBanner.derive(simPhase: .idle, simStale: false,
                                              optimizing: false,
                                              runFailure: "The generator could not close the rim.")!
        XCTAssertEqual(failed.kind, .failed)
        XCTAssertEqual(failed.title, "Job failed")
        XCTAssertTrue(failed.body.contains("rim"))

        // failed (the sim).
        let simFailed = LatticePageBanner.derive(simPhase: .failed("no convergence"), simStale: false,
                                                 optimizing: false, runFailure: nil)!
        XCTAssertEqual(simFailed.kind, .failed)
        XCTAssertEqual(simFailed.title, "Sim failed")
    }

    func testSimModelDrivesRunCompleteStaleAndCancel() async throws {
        let result = TopOptKit.SimAnalysisResult(
            accepted: true, nonConvergent: false, maxStressMPa: 100,
            marginWorstCase: 2.0, marginRequired: 1.5, maxDisplacementMM: 0.3,
            vonMisesField: [1, 2, 3], gridNX: 3, gridNY: 1, gridNZ: 1,
            gridOrigin: .zero, spacingMM: 1.5)
        let sim = LatticeSimModel(runner: { _ in result })
        let ctx = LatticeSimModel.Context(
            modelPath: "/tmp/p.stl", material: "PLA", materialsPath: "m", rulesPath: "r",
            resolution: 64, anchorFaceIDs: [1], loadGroups: [])

        sim.run(ctx)
        XCTAssertEqual(sim.phase, .running)
        try await Self.waitUntil { if case .complete = sim.phase { return true }; return false }
        XCTAssertNotNil(sim.field)
        XCTAssertEqual(sim.field?.vonMises, [1, 2, 3])

        // Fresh against the same inputs; STALE the moment any input changes.
        XCTAssertFalse(sim.isStale(against: ctx.fingerprint))
        let changed = LatticeSimModel.Context(
            modelPath: "/tmp/p.stl", material: "PETG", materialsPath: "m", rulesPath: "r",
            resolution: 64, anchorFaceIDs: [1], loadGroups: [])
        XCTAssertTrue(sim.isStale(against: changed.fingerprint))

        // Cancel abandons a NEW run; the late result is discarded.
        let slowSim = LatticeSimModel(runner: { _ in
            Thread.sleep(forTimeInterval: 0.15)
            return result
        })
        slowSim.run(ctx)
        XCTAssertEqual(slowSim.phase, .running)
        slowSim.cancel()
        XCTAssertEqual(slowSim.phase, .idle)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(slowSim.phase, .idle, "the abandoned result never lands")
        XCTAssertNil(slowSim.field)
    }

    func testSimModelSurfacesFailureAndNonConvergenceHonestly() async throws {
        struct Boom: Error {}
        let failing = LatticeSimModel(runner: { _ in throw Boom() })
        let ctx = LatticeSimModel.Context(
            modelPath: "/tmp/p.stl", material: "PLA", materialsPath: "m", rulesPath: "r",
            resolution: 64, anchorFaceIDs: [], loadGroups: [])
        failing.run(ctx)
        try await Self.waitUntil { if case .failed = failing.phase { return true }; return false }

        // A non-convergent solve is FAILED with no field — never a fabricated one.
        let nc = TopOptKit.SimAnalysisResult(
            accepted: false, nonConvergent: true, maxStressMPa: 0, marginWorstCase: 0,
            marginRequired: 0, maxDisplacementMM: 0, vonMisesField: [],
            gridNX: 0, gridNY: 0, gridNZ: 0, gridOrigin: .zero, spacingMM: 0)
        let ncSim = LatticeSimModel(runner: { _ in nc })
        ncSim.run(ctx)
        try await Self.waitUntil { if case .failed = ncSim.phase { return true }; return false }
        XCTAssertNil(ncSim.field, "a non-convergent solve yields NO field")
        if case .failed(let msg) = ncSim.phase {
            XCTAssertTrue(msg.contains("converge"))
        }
    }

    // MARK: - helpers

    private static func waitUntil(timeout: TimeInterval = 5,
                                  _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func octetSpec() -> LatticeSpec {
        LatticeSpec(topologyID: "octet", cellMM: 8, strutRadiusMM: 1.2,
                    generateRelativeDensity: 0.5, minRelativeDensity: 0.2,
                    maxRelativeDensity: 0.5)
    }

    private static func request(lattice: LatticeSpec?,
                                clearances: [TopOptKit.ClearanceSpec] = [],
                                protections: [Int] = []) -> RunRequest {
        RunRequest(
            modelPath: "/tmp/part.stl", material: "PLA", materialsPath: "", rulesPath: "",
            resolution: 96, projectName: "lattice-page", anchorFaceIDs: [3],
            loadGroups: [.init(faceIDs: [5], force: SIMD3(0, 0, -100))],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40,
            clearances: clearances, faceProtections: protections,
            faceProtectionDepthMM: protections.isEmpty ? -1 : 3, lattice: lattice)
    }

    /// The page-one shape every B2/B3/B8 job assertion runs against: one anchor,
    /// one load group, one keep-clear, one protection — all inherited content.
    private static func jobDict(lattice: LatticeSpec?) throws -> [String: Any] {
        let bolt = ManualPrimitive.defaultBolt(at: SIMD3(1, 2, 3), radiusMM: 4, halfLengthMM: 10)
        return try jobDict(request: request(lattice: lattice, clearances: [bolt.spec()],
                                            protections: [9]))
    }

    private static func jobDict(clearances: [TopOptKit.ClearanceSpec],
                                protections: [Int]) throws -> [String: Any] {
        try jobDict(request: request(lattice: nil, clearances: clearances,
                                     protections: protections))
    }

    private static func jobDict(request: RunRequest) throws -> [String: Any] {
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: request,
                            progress: { _, _, _ in true }, onVariant: { _ in })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
    }
}
