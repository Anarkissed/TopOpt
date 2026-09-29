// FlexibleLatticeExportTests — the Flexible lattice's STL exporter (task
// 2026-09-29-flexible-screens, exporter round).
//
// What must hold, on a 30 × 30 × 12 mm box built by hand (the part's exact SDF on a
// 1 mm grid, the whole box latticed at ρ 0.25, every face skinned):
//   (a) the C++ copy of the field IS the Swift definition, lattice and solid, both
//       topologies, to 1e-4 mm — and a copy 1 % off FAILS that bound (positive control);
//   (b) the streamed file is a binary STL whose header count matches its length, that
//       welds CLOSED (every edge on exactly two facets), winds OUTWARD, and holds the
//       volume the field defines (Monte-Carlo over `FlexibleLatticeField.solid`);
//   (c) a cancelled export leaves no file behind;
//   (d) the exporter REPORTS holding no more than two sample layers (self-reported).
// Plus the solid's own semantics (skin and body are SOLID — the `min` the spec first
// shipped made both air) and determinism (same inputs ⇒ byte-identical file).
import XCTest
import simd
@testable import TopOptFlows

final class FlexibleLatticeExportTests: XCTestCase {

    // MARK: - the box

    static let wallMM: Float = 0.84                       // two 0.42 mm beads
    static let boxMax = SIMD3<Float>(30, 30, 12)          // the part is [0, boxMax]

    /// The exact signed distance to the box (− inside).
    static func boxSDF(_ p: SIMD3<Float>) -> Float {
        let half = boxMax * 0.5
        let q = simd_abs(p - half) - half
        let outside = simd_length(simd_max(q, .zero))
        let inside = Swift.min(Swift.max(q.x, Swift.max(q.y, q.z)), 0)
        return outside + inside
    }

    /// FlexibleLatticeInputs for the box: every grid 1 mm, voxel centres from −3 mm, so
    /// the SDF reaches past the export's 2h pad. `latticeBelowX` limits the lattice
    /// region (mask 1) to x < that value.
    static func box(_ topology: FlexibleLatticeInputs.Topology,
                    latticeBelowX: Float = .infinity,
                    rhoAt: (SIMD3<Float>) -> Float = { _ in 0.25 },
                    buildDir: SIMD3<Float> = SIMD3(0, 0, 1)) -> FlexibleLatticeInputs {
        let c0 = SIMD3<Float>(-3, -3, -3)
        let nx = 37, ny = 37, nz = 19
        var sdf = [Float](), dist = [Float](), mask = [Float](), rho = [Float]()
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    let p = c0 + SIMD3<Float>(Float(i), Float(j), Float(k))
                    let d = boxSDF(p)
                    sdf.append(d)
                    dist.append(abs(d))          // skinDist: distance to the box surface
                    mask.append(p.x < latticeBelowX ? 1 : 0)
                    rho.append(rhoAt(p))
                }
            }
        }
        func grid(_ v: [Float]) -> FlexGrid { FlexGrid(nx: nx, ny: ny, nz: nz, c0: c0, spacing: 1, values: v) }
        let t = wallMM
        return FlexibleLatticeInputs(
            topology: topology, wallMM: t, lMinMM: 3.0915 * t / 0.9, lMaxMM: 3.0915 * t / 0.05,
            honeycombCellMM: 2 * t / 0.25, buildDir: simd_normalize(buildDir),
            skinMM: FlexibleLatticeField.defaultSkinMM,
            rho: grid(rho), mask: grid(mask), partSDF: grid(sdf), skinDist: grid(dist),
            boundsMin: .zero, boundsMax: boxMax)
    }

    /// A deterministic generator (SplitMix64), so every run samples the same points.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flex-lattice-\(name)-\(UUID().uuidString).stl")
    }

    // MARK: - (a) the C++ copy is the Swift definition

    func testCppFieldAgreesWithTheSwiftDefinition() throws {
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            let f = Self.box(topo)
            var rng = SplitMix(state: 0x5EED_0000 + UInt64(topo.rawValue))
            // Past the SDF grid on every side (−4 … 34 / 16), so the clamps are exercised.
            let pts = (0..<400).map { _ in
                SIMD3<Float>(Float.random(in: -4...34, using: &rng), Float.random(in: -4...34, using: &rng),
                             Float.random(in: -4...16, using: &rng))
            }
            let cppLattice = FlexibleLatticeExport.values(f, at: pts, field: .lattice)
            let cppSolid = FlexibleLatticeExport.values(f, at: pts, field: .solid)
            XCTAssertEqual(cppLattice.count, pts.count)
            XCTAssertEqual(cppSolid.count, pts.count)
            guard cppLattice.count == pts.count, cppSolid.count == pts.count else { continue }
            var dLattice: Float = 0, dSolid: Float = 0, inside = 0, outside = 0
            var swiftLattice = [Float]()
            for (n, p) in pts.enumerated() {
                let l = FlexibleLatticeField.lattice(at: p, f), s = FlexibleLatticeField.solid(at: p, f)
                swiftLattice.append(l)
                dLattice = max(dLattice, abs(l - cppLattice[n]))
                dSolid = max(dSolid, abs(s - cppSolid[n]))
                if s < 0 { inside += 1 } else { outside += 1 }
            }
            // ★ POSITIVE CONTROL: a C++ copy whose wall is 1 % thicker must break the bound,
            // or the bound could not see a real drift.
            var drifted = f
            drifted.wallMM *= 1.01
            let cppDrifted = FlexibleLatticeExport.values(drifted, at: pts, field: .lattice)
            let dDrifted = zip(swiftLattice, cppDrifted).map { abs($0 - $1) }.max() ?? 0
            print("[FlexExport] agreement \(topo): \(pts.count) points, max |Δ| lattice \(dLattice) solid \(dSolid); "
                  + "solid inside \(inside) / outside \(outside); control (wall +1 %) max |Δ| \(dDrifted)")
            XCTAssertLessThanOrEqual(dLattice, 1e-4, "\(topo): C++ lattice drifted from the Swift definition")
            XCTAssertLessThanOrEqual(dSolid, 1e-4, "\(topo): C++ solid drifted from the Swift definition")
            XCTAssertGreaterThan(inside, 40, "\(topo): the points must reach the solid")
            XCTAssertGreaterThan(outside, 40)
            XCTAssertGreaterThan(dDrifted, 1e-3, "\(topo): the control must go RED")
        }
    }

    /// ★ BIT-EXACT on a field that exercises every branch (exporter verifier, 2026-09-29):
    /// the test above used ONE ρ (so one k, where both roundings of π happened to agree),
    /// an axis build direction (where 1/sqrt and simd_normalize agree) and a full mask.
    /// Here ρ is graded from 0.01 to 1.0 (past both clamps), the region has an edge, and
    /// the build direction is tilted both ways about the |b.x| < 0.9 switch.
    func testCppFieldIsBitIdenticalOnAGradedTiltedField() {
        let dirs: [SIMD3<Float>] = [SIMD3(0, 0, 1), SIMD3(0.95, 0.1, 0.2), SIMD3(0.3, -0.5, 0.8), SIMD3(-0.2, 0.9, 0.4)]
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            for dir in (topo == .gyroid ? [dirs[0]] : dirs) {
                let f = Self.box(topo, latticeBelowX: 17.5, rhoAt: { p in 0.01 + 0.99 * Swift.min(Swift.max(p.x / 30, 0), 1) },
                                 buildDir: dir)
                var rng = SplitMix(state: 0xB17E + UInt64(topo.rawValue) * 31 + UInt64(abs(dir.x * 100)))
                let pts = (0..<4000).map { _ in
                    SIMD3<Float>(Float.random(in: -4...34, using: &rng), Float.random(in: -4...34, using: &rng),
                                 Float.random(in: -4...16, using: &rng))
                }
                let cppL = FlexibleLatticeExport.values(f, at: pts, field: .lattice)
                let cppS = FlexibleLatticeExport.values(f, at: pts, field: .solid)
                guard cppL.count == pts.count, cppS.count == pts.count else { XCTFail("no C++ values"); continue }
                var diffL = 0, diffS = 0
                for (n, p) in pts.enumerated() {
                    if FlexibleLatticeField.lattice(at: p, f).bitPattern != cppL[n].bitPattern { diffL += 1 }
                    if FlexibleLatticeField.solid(at: p, f).bitPattern != cppS[n].bitPattern { diffS += 1 }
                }
                // ★ CONTROL: a wall ONE ULP thicker changes values at these points — the
                // bitwise comparison can see a one-ulp change in the field's inputs.
                var ulp = f
                ulp.wallMM = f.wallMM.nextUp
                let cppU = FlexibleLatticeExport.values(ulp, at: pts, field: .lattice)
                let moved = zip(cppU, cppL).filter { $0.bitPattern != $1.bitPattern }.count
                print("[FlexExport] bit-exact \(topo) dir \(dir): \(pts.count) points, lattice differs at \(diffL), "
                      + "solid at \(diffS); control (wall +1 ulp) moved \(moved)")
                XCTAssertEqual(diffL, 0, "\(topo) \(dir): the C++ lattice must be the Swift definition, bit for bit")
                XCTAssertEqual(diffS, 0, "\(topo) \(dir): the C++ solid must be the Swift definition, bit for bit")
                XCTAssertGreaterThan(moved, 100, "control: a one-ulp wall must show")
            }
        }
    }

    /// ★ The skin and the body outside the lattice region are SOLID. The spec first
    /// wrote `open = min(dRegion, dSkin)`: every one of these points was air.
    func testSolidKeepsTheSkinAndTheBodyOutsideTheRegion() {
        let f = Self.box(.gyroid, latticeBelowX: 15)
        let skin = SIMD3<Float>(7, 15, 0.4)       // 0.4 mm under the bottom face, in the region
        let body = SIMD3<Float>(25, 15, 6)        // 5 mm deep, outside the region
        let air = SIMD3<Float>(7, 15, -0.3)       // just outside the part
        func oldSolid(_ p: SIMD3<Float>) -> Float {
            let open = min(FlexibleLatticeField.dRegion(p, f), FlexibleLatticeField.dSkin(p, f))
            return min(max(f.partSDF.sample(p), -open), FlexibleLatticeField.lattice(at: p, f))
        }
        for (name, p) in [("skin", skin), ("body", body)] {
            let s = FlexibleLatticeField.solid(at: p, f)
            let c = FlexibleLatticeExport.values(f, at: [p], field: .solid).first ?? .nan
            print("[FlexExport] \(name) \(p): solid \(s) (C++ \(c)); the min() spec gave \(oldSolid(p))")
            XCTAssertLessThan(s, 0, "\(name) must be solid")
            XCTAssertLessThan(c, 0, "\(name) must be solid in the C++ copy too")
            XCTAssertGreaterThan(oldSolid(p), 0, "control: the min() spec made the \(name) air")
        }
        XCTAssertGreaterThan(FlexibleLatticeField.solid(at: air, f), 0)
        // Deep in the region the solid is the lattice's sign (walls and pores both occur).
        var rng = SplitMix(state: 42)
        var walls = 0, pores = 0
        for _ in 0..<200 {
            let p = SIMD3<Float>(Float.random(in: 2...13, using: &rng), Float.random(in: 2...28, using: &rng),
                                 Float.random(in: 2...10, using: &rng))
            let s = FlexibleLatticeField.solid(at: p, f), l = FlexibleLatticeField.lattice(at: p, f)
            XCTAssertEqual(s < 0, l < 0, "at \(p) the solid must be the lattice")
            if l < 0 { walls += 1 } else { pores += 1 }
        }
        XCTAssertGreaterThan(walls, 10)
        XCTAssertGreaterThan(pores, 10)
    }

    // MARK: - (b) the file

    func testExportIsClosedOutwardAndHoldsTheFieldsVolume() throws {
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            let f = Self.box(topo)
            let h = FlexibleLatticeExport.defaultPitch(wallMM: Double(f.wallMM))
            XCTAssertEqual(h, Double(f.wallMM) / 2.5, accuracy: 1e-12)
            let url = Self.tempURL("box-\(topo)")
            defer { try? FileManager.default.removeItem(at: url) }

            let est = try FlexibleLatticeExport.estimate(f, hMM: h)
            var fractions: [Double] = []
            let clock = ContinuousClock.now
            let r = try FlexibleLatticeExport.export(f, hMM: h, to: url) { fractions.append($0); return true }
            let took = ContinuousClock.now - clock

            // The header and the count.
            let data = try Data(contentsOf: url)
            let header = String(decoding: data.prefix(80).prefix { $0 != 0 }, as: UTF8.self)
            XCTAssertEqual(header, "TopOpt Flexible lattice (app preview geometry)")
            XCTAssertTrue(data.prefix(80).dropFirst(header.utf8.count).allSatisfy { $0 == 0 }, "header zero-padded")
            let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
            XCTAssertGreaterThan(count, 0)
            XCTAssertEqual(Int(count), r.triangles)
            XCTAssertEqual(data.count, 84 + 50 * Int(count), "the header count must match the file length")
            XCTAssertEqual(r.bytes, data.count)

            // Closed: weld identical vertices, then every edge on exactly two facets.
            let (verts, idx) = MeshExport.parseBinarySTL(data)
            XCTAssertEqual(idx.count, 3 * Int(count))
            let (wv, wi) = Self.weld(verts, idx)
            let watertight = MeshExport.isWatertight(vertices: wv, indices: wi)
            XCTAssertTrue(watertight, "\(topo): the export must weld closed")
            // ★ CONTROL: one facet fewer is NOT closed — the check can see a hole.
            XCTAssertFalse(MeshExport.isWatertight(vertices: wv, indices: Array(wi.dropLast(3))))
            // Consistently wound: every directed edge (a→b) is matched by exactly one (b→a).
            // (isWatertight counts undirected edges; one flipped facet passes it — verifier.)
            XCTAssertEqual(Self.unpairedDirectedEdges(wi), 0, "\(topo): every edge must be wound once each way")
            var flipped = wi
            flipped.swapAt(1, 2)
            XCTAssertTrue(MeshExport.isWatertight(vertices: wv, indices: flipped), "control: undirected check is blind to it")
            XCTAssertGreaterThan(Self.unpairedDirectedEdges(flipped), 0, "control: one flipped facet must show")

            // Outward: the signed volume is positive, and the stored normals are the winding's.
            let signed = Self.signedVolume(verts, idx)
            XCTAssertGreaterThan(signed, 0, "\(topo): facets must wind outward")
            var normalsChecked = 0, normalsAgree = 0
            data.withUnsafeBytes { raw in
                for t in stride(from: 0, to: Int(count), by: max(1, Int(count) / 2000)) {
                    let o = 84 + 50 * t
                    func v3(_ at: Int) -> SIMD3<Float> {
                        SIMD3(raw.loadUnaligned(fromByteOffset: at, as: Float.self),
                              raw.loadUnaligned(fromByteOffset: at + 4, as: Float.self),
                              raw.loadUnaligned(fromByteOffset: at + 8, as: Float.self))
                    }
                    let stored = v3(o), wound = MeshExport.facetNormal(v3(o + 12), v3(o + 24), v3(o + 36))
                    normalsChecked += 1
                    if simd_length(stored - wound) < 1e-5 { normalsAgree += 1 }
                }
            }
            XCTAssertEqual(normalsAgree, normalsChecked, "stored normals must be (b−a)×(c−a), normalised")

            // The volume the field defines. solid ≥ dPart, so the solid lies in the box.
            let volume = MeshExport.meshVolume(vertices: verts, indices: idx)
            let mc = Self.monteCarloVolume(f, samples: 40_000)
            XCTAssertEqual(volume, mc, accuracy: 0.15 * mc, "\(topo): mesh volume vs the field's")

            // Progress: from 0, never backwards, to 1 — in steps a bar can show.
            XCTAssertEqual(fractions.first, 0)
            XCTAssertEqual(fractions.last, 1)
            XCTAssertEqual(fractions, fractions.sorted())
            XCTAssertGreaterThan(fractions.count, 10, "a small part must still report progress between slabs")

            print("[FlexExport] \(topo) h \(String(format: "%.3f", h)) mm: grid \(est.nx)×\(est.ny)×\(est.nz), "
                  + "\(r.triangles) triangles (estimate \(est.triangles), crossing \(String(format: "%.4f", est.crossingFraction))), "
                  + "\(r.bytes) bytes, welded \(wv.count / 3) vertices, watertight \(watertight), "
                  + "signed volume \(String(format: "%.1f", signed)) mm³, mesh \(String(format: "%.1f", volume)) "
                  + "vs Monte-Carlo \(String(format: "%.1f", mc)) mm³ (\(String(format: "%+.2f", 100 * (volume / mc - 1))) %), "
                  + "\(fractions.count) progress calls, \(took)")
            XCTAssertEqual(Double(est.triangles), Double(r.triangles), accuracy: 0.25 * Double(r.triangles),
                           "the estimate is rough, not wrong")
        }
    }

    /// 03-generators §8: the same inputs give a byte-identical file.
    func testExportIsDeterministic() throws {
        let f = Self.box(.gyroid)
        let h = FlexibleLatticeExport.defaultPitch(wallMM: Double(f.wallMM))
        let a = Self.tempURL("det-a"), b = Self.tempURL("det-b")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try FlexibleLatticeExport.export(f, hMM: h, to: a) { _ in true }
        try FlexibleLatticeExport.export(f, hMM: h, to: b) { _ in true }
        let da = try Data(contentsOf: a), db = try Data(contentsOf: b)
        print("[FlexExport] determinism: \(da.count) and \(db.count) bytes, identical \(da == db)")
        XCTAssertEqual(da, db)
    }

    // MARK: - (c) cancel

    func testCancelDeletesThePartialFile() throws {
        let f = Self.box(.gyroid)
        let h = FlexibleLatticeExport.defaultPitch(wallMM: Double(f.wallMM))

        // Through `export`: false from progress cancels.
        let url = Self.tempURL("cancel")
        var calls = 0
        XCTAssertThrowsError(try FlexibleLatticeExport.export(f, hMM: h, to: url) { _ in
            calls += 1
            return calls < 3
        }) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(calls, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a cancelled export must leave no file")

        // Through a session: the partial file exists mid-export, and cancel removes it.
        let url2 = Self.tempURL("cancel-session")
        let s = try FlexibleLatticeExport.Session(f, hMM: h, to: url2)
        let left = try s.step(slabs: 3)
        XCTAssertGreaterThan(left, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path), "control: the partial file is there")
        s.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url2.path))
        s.cancel()   // twice is harmless
        XCTAssertThrowsError(try s.step(slabs: 1), "a cancelled session is closed")

        // A session dropped without finish cancels too.
        let url3 = Self.tempURL("cancel-dropped")
        do {
            let d = try FlexibleLatticeExport.Session(f, hMM: h, to: url3)
            _ = try d.step(slabs: 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url3.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url3.path), "a dropped session must delete its file")
        print("[FlexExport] cancel: export stopped after \(calls) progress calls; session and dropped session left no file")
    }

    // MARK: - (d) memory
    // ★ SELF-REPORTED (verifier, 2026-09-29): this reads the exporter's own count of its two
    // sample layers (now re-noted after every slab). It cannot see a copy of the grid held
    // anywhere else; a 370 k-sample grid (1.5 MB) is below what a process-footprint read
    // resolves in a test, so no such check is claimed.

    func testExporterHoldsTwoSampleLayersNeverTheGrid() throws {
        let f = Self.box(.honeycomb)
        let h = FlexibleLatticeExport.defaultPitch(wallMM: Double(f.wallMM))
        let url = Self.tempURL("memory")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try FlexibleLatticeExport.Session(f, hMM: h, to: url)
        let begun = try s.status()
        XCTAssertEqual(begun.slabFloats, begun.nx * begun.ny)
        XCTAssertEqual(begun.slabsTotal, begun.nz - 1)
        XCTAssertGreaterThan(begun.nz, 20, "the grid must be many layers deep for two layers to mean anything")
        XCTAssertLessThanOrEqual(begun.sampleFloatsPeak, 2 * begun.slabFloats)
        var steps = 0
        while try s.step(slabs: 4) > 0 {
            steps += 1
            let st = try s.status()
            XCTAssertLessThanOrEqual(st.sampleFloatsAllocated, 2 * st.slabFloats)
            XCTAssertLessThanOrEqual(st.sampleFloatsPeak, 2 * st.slabFloats)
        }
        let end = try s.status()
        XCTAssertEqual(end.slabsDone, end.slabsTotal)
        XCTAssertLessThanOrEqual(end.sampleFloatsPeak, 2 * end.slabFloats)
        let grid = end.nx * end.ny * end.nz
        let r = try s.finish()
        XCTAssertEqual(r.triangles, end.triangles)
        print("[FlexExport] memory: grid \(end.nx)×\(end.ny)×\(end.nz) = \(grid) samples; peak held "
              + "\(end.sampleFloatsPeak) floats = \(String(format: "%.2f", Double(end.sampleFloatsPeak) / Double(end.slabFloats))) layers "
              + "(\(String(format: "%.1f", 100 * Double(end.sampleFloatsPeak) / Double(grid))) % of the grid); "
              + "write buffer \(end.writeBufferBytes) bytes; \(steps + 1) steps")
    }

    func testRefusesAnUnusablePitchOrGrid() {
        let f = Self.box(.gyroid)
        XCTAssertThrowsError(try FlexibleLatticeExport.estimate(f, hMM: 0))
        XCTAssertThrowsError(try FlexibleLatticeExport.Session(f, hMM: -1, to: Self.tempURL("bad")))
        var broken = f
        broken.partSDF.values.removeLast()
        XCTAssertThrowsError(try FlexibleLatticeExport.Session(broken, hMM: 0.5, to: Self.tempURL("bad"))) {
            print("[FlexExport] refusal: \($0)")
        }
        XCTAssertTrue(FlexibleLatticeExport.values(broken, at: [.zero], field: .solid).isEmpty)
    }

    // MARK: - helpers

    /// Weld a triangle soup by EXACT coordinates (bit patterns): the exporter promises a
    /// shared edge's vertex is bit-identical in every cube, so no tolerance is allowed.
    static func weld(_ v: [Float], _ idx: [Int32]) -> ([Float], [Int32]) {
        struct Key: Hashable { let x: UInt32, y: UInt32, z: UInt32 }
        var map: [Key: Int32] = [:]
        map.reserveCapacity(idx.count / 4)
        var out = [Float](), oi = [Int32]()
        oi.reserveCapacity(idx.count)
        for i in idx {
            let b = Int(i) * 3
            let k = Key(x: v[b].bitPattern, y: v[b + 1].bitPattern, z: v[b + 2].bitPattern)
            if let w = map[k] {
                oi.append(w)
            } else {
                let w = Int32(out.count / 3)
                map[k] = w
                out += [v[b], v[b + 1], v[b + 2]]
                oi.append(w)
            }
        }
        return (out, oi)
    }

    /// Directed edges with no exactly-one opposite partner (0 on a consistently wound
    /// closed mesh).
    static func unpairedDirectedEdges(_ idx: [Int32]) -> Int {
        var count: [UInt64: Int] = [:]
        count.reserveCapacity(idx.count)
        func key(_ a: Int32, _ b: Int32) -> UInt64 {
            (UInt64(UInt32(bitPattern: a)) << 32) | UInt64(UInt32(bitPattern: b))
        }
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = idx[t], b = idx[t + 1], c = idx[t + 2]
            count[key(a, b), default: 0] += 1
            count[key(b, c), default: 0] += 1
            count[key(c, a), default: 0] += 1
        }
        var bad = 0
        for (k, n) in count {
            let a = Int32(bitPattern: UInt32(k >> 32)), b = Int32(bitPattern: UInt32(k & 0xFFFF_FFFF))
            if n != 1 || count[key(b, a)] != 1 { bad += 1 }
        }
        return bad
    }

    static func signedVolume(_ v: [Float], _ idx: [Int32]) -> Double {
        var six = 0.0
        for t in stride(from: 0, to: idx.count, by: 3) {
            func p(_ i: Int32) -> SIMD3<Double> {
                SIMD3(Double(v[Int(i) * 3]), Double(v[Int(i) * 3 + 1]), Double(v[Int(i) * 3 + 2]))
            }
            six += simd_dot(p(idx[t]), simd_cross(p(idx[t + 1]), p(idx[t + 2])))
        }
        return six / 6
    }

    /// The solid's volume from the Swift definition: the box's volume × the share of
    /// uniform samples inside. solid ≥ dPart, so nothing solid lies outside the box.
    static func monteCarloVolume(_ f: FlexibleLatticeInputs, samples: Int) -> Double {
        var rng = SplitMix(state: 0xB0C5)
        var inside = 0
        for _ in 0..<samples {
            let p = SIMD3<Float>(Float.random(in: 0..<boxMax.x, using: &rng), Float.random(in: 0..<boxMax.y, using: &rng),
                                 Float.random(in: 0..<boxMax.z, using: &rng))
            if FlexibleLatticeField.solid(at: p, f) < 0 { inside += 1 }
        }
        return Double(boxMax.x * boxMax.y * boxMax.z) * Double(inside) / Double(samples)
    }
}
