// FlexiblePinchTests — a pinch ALWAYS builds (task 2026-09-29-flexible-screens, round 4 batch
// D2; his img 3: "When I attempted to squish the two sides simultaneously, it makes the lattice
// not generate … you would absolutely squeeze the two sides together. One side wouldn't rest.
// That needs to change.").
// On HIS project 0004 (faces 3 and 5: the two ends of every 100 mm column of his pad):
//   * CORE REFUSES the pinch ("one profile per stack") — the control that says why the app
//     assembles it;
//   * the segment design with NOTHING pinched is core's own design, column for column (the
//     positive control for FlexiblePinch.design) — RED: halving the height changes it;
//   * every column of face 3 is pinched by face 5 (its midpoint lies in 5's stack) — RED: no
//     partner, none;
//   * the app's assembler IS core's field on a set core can assemble (top A, top B, face 3) —
//     RED: without the sectors' cuts, or with the farthest face, it is not;
//   * his project as saved (3 and 5 pressed, one group) is READY and Exit builds a lattice whose
//     squish moves both — RED: the old rule blocked;
//   * the pinched field is two segments: near face 3 face 3's half, near face 5 face 5's.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexiblePinchTests: XCTestCase {

    @MainActor
    private func his(_ prepare: (FlexibleStageModel) -> Void = { _ in }) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        prepare(m)
        try await settle(m)
        return (r, m)
    }

    @MainActor
    private func settle(_ m: FlexibleStageModel) async throws {
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "the designs") { !m.readiness.designing && !m.designsInFlight && !m.latticeBuilding }
        await m.waitForIdle()
    }

    @MainActor
    private func law(_ m: FlexibleStageModel) throws -> FlexiblePinch.Law {
        try FlexiblePinch.Law.core(materialsPath: FlexibleHisProject.materialsPath, materialID: try XCTUnwrap(m.settings.materialID),
                                   tempC: try XCTUnwrap(m.designTempC), build: m.build)
    }

    private static let k3 = FlexFaceKey(region: 3, rotation: 0), k5 = FlexFaceKey(region: 5, rotation: 0)

    // MARK: core cannot — the control

    @MainActor
    func testCoreRefusesThePinch() async throws {
        let (_, m) = try await his()
        XCTAssertEqual(m.conflicts.map { "\($0.faceA)|\($0.faceB)" }, ["3|5"], "premise: his faces 3 and 5 share every column")
        let build = m.build
        var refusal: String?
        do {
            _ = try await m.workerForTests.withScene { try $0.densityField(faces: [3, 5], rotations: [0, 0], build: build) }
        } catch {
            refusal = "\(error)"
        }
        print("FLEX-PINCH core on 3 + 5: \(refusal ?? "assembled")")
        XCTAssertTrue(refusal?.contains("one profile per stack") == true, "core assembles one profile per stack: \(refusal ?? "nil")")
    }

    // MARK: the two-segment design

    @MainActor
    func testNothingPinchedIsCoresOwnDesignAndAHalfIsNot() async throws {
        let (_, m) = try await his()
        let law = try law(m)
        var worst = 0.0, worstDepth = 0.0, columns = 0
        for k in m.loadedKeys {
            let d = try XCTUnwrap(m.designs[k]), st = try XCTUnwrap(m.stacks[k])
            let s = try FlexiblePinch.design(d, stack: st, pinched: [], law: law)
            let core = FlexiblePinch.core(d, stack: st)
            for c in st.columns.indices {
                worst = max(worst, abs(s.buildableDensity[c] - core.buildableDensity[c]))
                if let a = s.buildableDepthMM[c], let b = core.buildableDepthMM[c] { worstDepth = max(worstDepth, abs(a - b)) }
                else { XCTAssertEqual(s.buildableDepthMM[c] == nil, core.buildableDepthMM[c] == nil, "face \(k.region) column \(c)") }
                XCTAssertEqual(s.status[c], d.columns[c].status)
                columns += 1
            }
        }
        print("FLEX-PINCH nothing pinched vs core's design: \(columns) columns · |Δρ| ≤ \(worst) · |Δdepth| ≤ \(worstDepth) mm")
        XCTAssertLessThan(worst, 1e-9, "the segment design with nothing pinched IS core's")
        XCTAssertLessThan(worstDepth, 1e-9)
        // ★ RED CONTROL: halving every column of face 3 changes it
        let d3 = try XCTUnwrap(m.designs[Self.k3]), st3 = try XCTUnwrap(m.stacks[Self.k3])
        let half = try FlexiblePinch.design(d3, stack: st3, pinched: [Bool](repeating: true, count: st3.columns.count), law: law)
        let moved = zip(half.buildableDensity, d3.columns.map(\.buildableDensity)).filter { abs($0 - $1) > 1e-6 }.count
        print("FLEX-PINCH face 3 halved: \(moved) of \(st3.columns.count) columns change density")
        XCTAssertGreaterThan(moved, 0, "control: a half column is designed differently")
    }

    @MainActor
    func testEveryColumnOfFace3IsPinchedByFace5() async throws {
        let (_, m) = try await his()
        let st3 = try XCTUnwrap(m.stacks[Self.k3]), st5 = try XCTUnwrap(m.stacks[Self.k5])
        let p = FlexiblePinch.pinchedColumns(st3, partners: [(stack: st5, cuts: [])])
        print("FLEX-PINCH face 3 pinched by face 5: \(p.filter { $0 }.count) of \(p.count)")
        XCTAssertEqual(p.filter { $0 }.count, st3.columns.count, "the two ends of every column")
        // ★ RED CONTROL: no partner, nothing pinched
        XCTAssertEqual(FlexiblePinch.pinchedColumns(st3, partners: []).filter { $0 }.count, 0)
        // the model found the pinch and designed both halves
        XCTAssertEqual(m.pinches.map { "\($0.a)|\($0.b)" }, ["3|5"])
        let s3 = try XCTUnwrap(m.segments[Self.k3], "face 3 has its two-segment design")
        XCTAssertEqual(s3.pinchedCount, st3.columns.count)
        XCTAssertEqual(s3.heightMM.max() ?? 0, 50, accuracy: 1e-9, "half of his 100 mm columns")
        let core3 = try XCTUnwrap(m.designs[Self.k3])
        let target = core3.columns.map(\.targetDepthMM)
        func miss(_ depths: [Double?]) -> Double {
            let pairs = zip(depths, target).compactMap { d, t in d.map { abs($0 - t) } }
            return pairs.reduce(0, +) / Double(max(1, pairs.count))
        }
        let whole = miss(FlexibleSquishFace.buildableDepths(stack: st3, design: core3))
        let halves = miss(s3.buildableDepthMM)
        print("FLEX-PINCH face 3 mean miss of its drawing: one profile over 100 mm \(whole) mm (too soft on \(core3.tooSoft)) · its half \(halves) mm (too soft on \(s3.status.filter { $0 == "too_soft" }.count))")
        XCTAssertNotNil(m.segments[Self.k5])
        XCTAssertNil(m.segments[FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0)], "top A is not pinched: core's design stands")
    }

    // MARK: the app's assembler is core's

    @MainActor
    func testTheAssemblerIsCoresFieldWhereCoreCanAssemble() async throws {
        let (_, m) = try await his()
        let keys = [FlexibleHisProject.topA, FlexibleHisProject.topB, 3].map { FlexFaceKey(region: $0, rotation: 0) }
        let core = try await m.workerForTests.withScene {
            try $0.densityField(faces: keys.map(\.region), rotations: keys.map(\.rotation), build: m.build)
        }
        let mask = try await m.workerForTests.withScene { try $0.latticeMask(build: m.build) }
        func faces(cuts: Bool) throws -> [FlexibleGroupField.Face] {
            try keys.map { k in
                let d = try XCTUnwrap(m.designs[k]), st = try XCTUnwrap(m.stacks[k])
                let c = FlexiblePinch.core(d, stack: st)
                return FlexibleGroupField.Face(region: k.region, stack: st, cuts: cuts ? m.regions.cuts(of: k.region) : [],
                                               density: c.buildableDensity, cellMM: c.cellMM)
            }
        }
        let app = FlexibleGroupField.assemble(mask: mask, faces: try faces(cuts: true))
        func diff(_ a: FlexDensityField) -> (rho: Double, owners: Int, n: Int) {
            var worst = 0.0, owners = 0, n = 0
            for i in core.density.indices where core.density[i] > -0.5 {
                n += 1
                worst = max(worst, Double(abs(a.density[i] - core.density[i])))
                if a.owner[i] != core.owner[i] { owners += 1 }
            }
            return (worst, owners, n)
        }
        let same = diff(app)
        print("FLEX-ASSEMBLE app vs core on top A + top B + face 3: \(same.n) lattice voxels · |Δρ| ≤ \(same.rho) · owners differ on \(same.owners)")
        XCTAssertGreaterThan(same.n, 1000)
        XCTAssertLessThan(same.rho, 1e-5, "the app's assembler is core's rule")
        XCTAssertEqual(same.owners, 0)
        // (his split at x = 50 lies ON a column line — 32 pitches — so the cuts change nothing
        // here: `testMembershipIsCoresInStackWithItsCuts` holds the cut rule on a straddling cell)
        let noCuts = diff(FlexibleGroupField.assemble(mask: mask, faces: try faces(cuts: false)))
        print("FLEX-ASSEMBLE his split without cuts: owners differ on \(noCuts.owners), |Δρ| ≤ \(noCuts.rho)")
        // ★ RED CONTROL 1: without R11's blend (the nearest face alone) the handovers differ
        let hard = try faces(cuts: true).map { f in
            FlexibleGroupField.Face(region: f.region, stack: f.stack, cuts: f.cuts, density: f.density,
                                    cellMM: f.cellMM.map { _ in 1e-9 })
        }
        let noBlend = diff(FlexibleGroupField.assemble(mask: mask, faces: hard))
        print("FLEX-ASSEMBLE control, no blend: |Δρ| ≤ \(noBlend.rho), owners differ on \(noBlend.owners)")
        XCTAssertGreaterThan(noBlend.rho, 1e-3, "control: the blend is core's, and it matters")
        // ★ RED CONTROL 2: the FARTHEST face (a reversed depth order) is not core's field
        let far = try faces(cuts: true).map { f in
            FlexibleGroupField.Face(region: f.region, stack: f.stack, cuts: f.cuts, density: f.density.map { $0 > 0 ? 1 - $0 : $0 }, cellMM: f.cellMM)
        }
        XCTAssertGreaterThan(diff(FlexibleGroupField.assemble(mask: mask, faces: far)).rho, 1e-3, "control: other densities, another field")
    }

    /// Core's in_stack with a sector's cuts, on a cell the cut STRADDLES.
    func testMembershipIsCoresInStackWithItsCuts() {
        func col(_ i: Int) -> FlexColumn {
            FlexColumn(iu: i, iv: 0, uMM: Double(i) + 0.5, vMM: 0.5, areaMM2: 1, entryT: 0, exitT: 10, latticeMM: 10, exitFace: 0)
        }
        // two 1 mm columns under the plane z = 0, pressed along −Z, 10 mm deep
        let st = FlexStackInfo(frameValid: true, frameReason: "", load: SIMD3(0, 0, -1), xAxis: SIMD3(1, 0, 0),
                               yAxis: SIMD3(0, 1, 0), centroid: .zero, rotationDeg: 0, uMin: 0, vMin: 0,
                               uExtentMM: 2, vExtentMM: 1, areaMM2: 2, projectedAreaMM2: 2, normalSpreadDeg: 0,
                               normalSpreadFlag: false, buildAngleDeg: 0, side: false, principalAxisTied: false,
                               pitchMM: 1, nu: 2, nv: 1, cell: [0, 1], columns: [col(0), col(1)], exitFaces: [],
                               exitRegions: [], exitUnresolvedFraction: 0, footprintAreaMM2: 2, latticedColumns: 2,
                               latticeMMMin: 10, latticeMMMean: 10, latticeMMMax: 10, stackMMMax: 10)
        let hit = FlexibleStackMembership.hit(SIMD3(0.8, 0.5, -3), st)
        XCTAssertEqual(hit?.col, 0); XCTAssertEqual(hit?.depth ?? -1, 3, accuracy: 1e-12)
        XCTAssertEqual(FlexibleStackMembership.hit(SIMD3(1.2, 0.5, -9.5), st)?.col, 1)
        XCTAssertNil(FlexibleStackMembership.hit(SIMD3(0.8, 0.5, -10.5), st), "past the exit")
        XCTAssertNil(FlexibleStackMembership.hit(SIMD3(0.8, 0.5, 0.5), st), "in front of the face")
        XCTAssertNil(FlexibleStackMembership.hit(SIMD3(2.5, 0.5, -3), st), "off the columns")
        // a sector cut at x ≥ 0.7 straddles column 0: core keeps only its own side
        let cut = [RegionCut(point: SIMD3(0.7, 0, 0), normal: SIMD3(1, 0, 0))]
        XCTAssertEqual(FlexibleStackMembership.hit(SIMD3(0.8, 0.5, -3), st, cuts: cut)?.col, 0, "on its side")
        XCTAssertNil(FlexibleStackMembership.hit(SIMD3(0.6, 0.5, -3), st, cuts: cut), "across the cut")
        XCTAssertNil(FlexibleStackMembership.hit(SIMD3(0.7, 0.5, -3), st, cuts: [RegionCut(point: SIMD3(0.7, 0, 0), normal: SIMD3(1, 0, 0), strict: true)]),
                     "a strict cut excludes its own plane")
        // ★ RED CONTROL: without the cut the same point is in column 0
        XCTAssertEqual(FlexibleStackMembership.hit(SIMD3(0.6, 0.5, -3), st)?.col, 0, "control: the cut is what excluded it")
        // the column's centre line (core's from_uv + t·load)
        XCTAssertEqual(FlexibleStackMembership.point(st, column: 1, t: 4), SIMD3(1.5, 0.5, -4))
    }

    // MARK: his pinch builds

    @MainActor
    func testHisPinchIsReadyAndExitBuildsALatticeThatSquishesBothEnds() async throws {
        let (_, m) = try await his()
        let r = m.readiness
        print("FLEX-PINCH his project as saved: blocking \(r.blocking.map(\.oneLine)) · line '\(r.oneLine)'")
        XCTAssertTrue(r.isReady, "a pinch inside one group never blocks: \(r.blocking.map(\.oneLine))")
        XCTAssertEqual(FlexibleExitDecision.decide(r), .exit)
        m.generateLattice()
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        let g = try XCTUnwrap(m.lattice, "his pinch builds (img 3)")
        XCTAssertEqual(Set(g.squishedKeys.map(\.region)), Set([FlexibleHisProject.topA, FlexibleHisProject.topB, 3, 5]))
        let faces = Dictionary(uniqueKeysWithValues: zip(g.keys, g.faces).map { ($0.0.region, $0.1) })
        XCTAssertTrue(faces[3]?.moves == true && faces[5]?.moves == true, "both ends of the pinch squish")
        // the dent is the halves' own depths
        let s3 = try XCTUnwrap(m.segments[Self.k3])
        XCTAssertEqual(g.columnDepths[Self.k3]?.compactMap { $0 }.max() ?? 0, s3.buildableDepthMM.compactMap { $0 }.max() ?? -1, accuracy: 1e-9)
        // ★ RED CONTROL: the OLD rule (round 3 batch B) blocked every stack conflict
        XCTAssertFalse(m.conflicts.isEmpty, "control: the conflict the old rule blocked on is still core's")
    }

    @MainActor
    func testThePinchedFieldIsTwoSegments() async throws {
        let (_, m) = try await his { m in
            // only the pinch: the top rests; face 3 soft (4 mm), face 5 firm (1 mm)
            m.rest(FlexibleHisProject.topA); m.rest(FlexibleHisProject.topB)
            m.edit { s in
                for (r, mm) in [(3, 4.0), (5, 1.0)] { var f = s.face(r)!; f.deepestMM = mm; s.setFace(f) }
            }
        }
        XCTAssertEqual(Set(m.settings.loadedFaces.map(\.faceRegionID)), [3, 5])
        m.generateLattice()
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        let g = try XCTUnwrap(m.lattice)
        let s3 = try XCTUnwrap(m.segments[Self.k3]), s5 = try XCTUnwrap(m.segments[Self.k5])
        let st3 = try XCTUnwrap(m.stacks[Self.k3]), st5 = try XCTUnwrap(m.stacks[Self.k5])
        // the field on the builder's grid (the walls' own ρ, read with the one sampling rule)
        let rho = g.inputs.rho
        func at(_ p: SIMD3<Float>) -> Float { rho.sample(p) }
        // a column through the pad's middle (y 50, z 10): near face 3 (x = 95) and near face 5 (x = 5)
        let near3 = SIMD3<Double>(95, 50, 10), near5 = SIMD3<Double>(5, 50, 10)
        let c3 = try XCTUnwrap(FlexibleStackMembership.hit(near3, st3)), c5 = try XCTUnwrap(FlexibleStackMembership.hit(near5, st5))
        let got3 = at(SIMD3<Float>(near3)), got5 = at(SIMD3<Float>(near5))
        print("FLEX-PINCH two segments: near face 3 ρ \(got3) (its half \(s3.buildableDensity[c3.col])) · near face 5 ρ \(got5) (its half \(s5.buildableDensity[c5.col]))")
        XCTAssertEqual(Double(got3), s3.buildableDensity[c3.col], accuracy: 0.02, "face 3's half near face 3")
        XCTAssertEqual(Double(got5), s5.buildableDensity[c5.col], accuracy: 0.02, "face 5's half near face 5")
        // ★ RED CONTROL: the two halves differ — one profile (face 3's everywhere) would put face
        // 3's density beside face 5
        XCTAssertGreaterThan(abs(s3.buildableDensity[c3.col] - s5.buildableDensity[c5.col]), 0.02,
                             "control: a soft face 3 and a firm face 5 are two different halves")
    }
}
