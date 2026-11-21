import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE "LATTICE DEPTH" SECTION IS REMOVED (his decision, 2026-10-11): "I want the entire section
/// removed." … "The lattice *always* goes the entire depth of the prism. The *GRADE* can only be modified
/// by that setting ... the actual lattice depth NEVER changes." A project saved with a wall setting must
/// still open, and its preview must fill the whole prism, 0 to depthMM.
@MainActor
final class LatticeWallDepthRemovedTests: XCTestCase {

    /// The old setting, written by hand the way a 2026-09-21 build saved it: the switch off, half the
    /// wall, one wall with its own range and a drawn profile.
    static let oldWallKey: [String: Any] = [
        "depthBySim": false, "density": "manualSingle", "pct": 50, "seedBoost": 2,
        "faces": ["f:g:4": ["startMM": 0, "endMM": 20, "profile": ["ends": [0.5, 0.25]]]],
    ]

    private func project() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "wall", material: "ABS", process: .fdm,
                     importedFile: ImportedFile(name: "part.step", path: NSTemporaryDirectory() + "part.step",
                                                triangleCount: 12, faceCount: 6, watertight: true),
                     importedMesh: nil)
        p.lattice.enabled = true
        return p
    }

    /// The bottom face (z = 0) of the 40 mm box, looking up into the part, 20 mm deep.
    private func bottomWall() -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(20, 20, 0); r.normal = SIMD3(0, 0, 1); r.depthMM = 20
        r.halfUMM = 15; r.halfWMM = 15
        r.outlineLoops = [[SIMD2(-15, -15), SIMD2(15, -15), SIMD2(15, 15), SIMD2(-15, 15)]]
        r.selectableKey = "f:g:4"; r.faceID = 4
        return r
    }

    func testAProjectSavedWithAWallSettingOpensAndItsPreviewFillsTheWholePrism() throws {
        let p = project()
        let untouched = try XCTUnwrap(p.snapshot(savedAt: Date(timeIntervalSince1970: 0)))
        let untouchedData = try JSONEncoder().encode(untouched)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: untouchedData) as? [String: Any])
        var lat = try XCTUnwrap(obj["lattice"] as? [String: Any])
        XCTAssertNil(lat["wallThickness"], "an untouched project writes no wall key")
        lat["wallThickness"] = Self.oldWallKey
        obj["lattice"] = lat
        let saved = try JSONSerialization.data(withJSONObject: obj)

        // ★ it opens
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: saved)
        let lattice = try XCTUnwrap(back.lattice)
        // ★ and the old key is ignored: the lattice re-encodes exactly as the untouched one
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try e.encode(lattice), as: UTF8.self),
                       String(decoding: try e.encode(try XCTUnwrap(untouched.lattice)), as: UTF8.self),
                       "★ the old wall key is read and dropped")

        // ★ its preview: the regions the stage bakes, through the scene every reader reads
        _ = lattice
        let region = bottomWall()
        let scene = LatticeSDFScene(mesh: LatticeBandChipsTests.boxMesh(), field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        let r = try XCTUnwrap(scene.regions.first)
        let deep = SIMD3<Double>(20, 20, 0.9 * r.depthMM)
        XCTAssertTrue(LatticeRegionMask.contains(deep, region: r), "★ the lattice reaches 0.9 · depth (18 mm)")
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(20, 20, 0.6 * r.depthMM), region: r), "past the old 50 % slab")
        XCTAssertLessThan(LatticeRegionMask.signedDistance(deep, region: r), 0, "inside by the region distance too")
        // the occupancy the bake reads: latticed voxels in the prism's last tenth
        let g = scene.occupancy
        var deepVoxels = 0
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx where g.values[(k * g.ny + j) * g.nx + i] > 0.5 {
            let z = Double(g.origin.z + Float(k) * g.spacing.z)
            let x = Double(g.origin.x + Float(i) * g.spacing.x), y = Double(g.origin.y + Float(j) * g.spacing.y)
            if z > 0.9 * r.depthMM, z < r.depthMM, abs(x - 20) < 14, abs(y - 20) < 14 { deepVoxels += 1 }
        }}}
        print("WALL-REMOVED deep voxels (z in 18…20 mm): \(deepVoxels)")
        XCTAssertGreaterThan(deepVoxels, 0, "★ the occupancy is latticed through the whole depth")
    }
}

/// ★★ THE REVIEWER'S RULING (2026-10-24 07:41, approved by the maintainer): core does not run without a lattice
/// depth — a face region's `depth_mm` absent reads as 0 mm, an empty mask, a refused run. So the section goes but
/// `depth_mm` stays on every face region, and it is the prism's OWN depth. A bolt has no depth: core's bolt schema
/// takes axis_point / axis_dir / radius_mm / half_length_mm only and rejects any other key.
@MainActor
final class LatticeJobDepthOnTheWireTests: XCTestCase {

    /// Every lattice region in a job document: a face carries depth_mm > 0; a bolt carries radius and half-length
    /// > 0 and no depth_mm; a "region" carries depth_mm > 0. Returns what is wrong, by path.
    static func depthFaults(_ doc: Data) throws -> [String] {
        var faults: [String] = []
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func walk(_ v: Any, _ path: String) {
            if let d = v as? [String: Any] {
                if let regs = d["regions"] as? [[String: Any]], path.hasSuffix("lattice") {
                    for (i, r) in regs.enumerated() {
                        let kind = r["kind"] as? String ?? "?"
                        let g = r["geometry"] as? [String: Any] ?? [:]
                        let at = "\(path).regions[\(i)] (\(kind))"
                        switch kind {
                        case "bolt":
                            if g["depth_mm"] != nil { faults.append("\(at): a bolt with depth_mm") }
                            if !((num(g["radius_mm"]) ?? 0) > 0 && (num(g["half_length_mm"]) ?? 0) > 0) { faults.append("\(at): no extent") }
                        default:
                            guard let dm = num(g["depth_mm"]) else { faults.append("\(at): depth_mm absent"); continue }
                            if !(dm > 0) { faults.append("\(at): depth_mm \(dm) ≤ 0") }
                        }
                    }
                }
                for (k, x) in d { walk(x, path + "." + k) }
            } else if let a = v as? [Any] {
                for (i, x) in a.enumerated() { walk(x, path + "[\(i)]") }
            }
        }
        walk(try JSONSerialization.jsonObject(with: doc), "$")
        return faults
    }

    private func laticeRegions(_ doc: Data) throws -> [[String: Any]] {
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: doc) as? [String: Any])
        return try XCTUnwrap((o["lattice"] as? [String: Any])?["regions"] as? [[String: Any]])
    }

    /// (b) no lattice region in any job — the stage's emission, the variant run, forecast and probe, octet and
    /// organic — has depth_mm absent or ≤ 0; and the checker sees a fault where there is one (positive control).
    func testNoLatticeRegionInAnyJobHasNoDepth() throws {
        var docsChecked = 0, facesSeen = 0, boltsSeen = 0
        for organic in [false, true] {
            let (p, _, _) = VariantFacePrismFixture.project(organic: organic)
            let stage = try JSONSerialization.data(withJSONObject: ["lattice": ["regions": p.latticeJobRegions().regions.map { $0.wireDictionary }]])
            for (label, d) in try [("stage", stage)] + VariantFacePrismFixture.variantDocuments(p) {
                XCTAssertEqual(try Self.depthFaults(d), [], "★ \(organic ? "organic" : "octet") \(label)")
                docsChecked += 1
                if let regs = try? laticeRegions(d) {
                    facesSeen += regs.filter { $0["kind"] as? String == "face" }.count
                    boltsSeen += regs.filter { $0["kind"] as? String == "bolt" }.count
                }
            }
            // positive control: the same run document with one face's depth_mm dropped, and one set to 0
            let run = try XCTUnwrap(try VariantFacePrismFixture.variantDocuments(p).first { $0.0 == "run" }?.1)
            var o = try XCTUnwrap(try JSONSerialization.jsonObject(with: run) as? [String: Any])
            var lat = try XCTUnwrap(o["lattice"] as? [String: Any])
            var regs = try XCTUnwrap(lat["regions"] as? [[String: Any]])
            let fi = try XCTUnwrap(regs.firstIndex { $0["kind"] as? String == "face" })
            var g = try XCTUnwrap(regs[fi]["geometry"] as? [String: Any])
            for broken in [nil, 0.0] as [Double?] {
                g["depth_mm"] = broken; regs[fi]["geometry"] = g; lat["regions"] = regs; o["lattice"] = lat
                XCTAssertEqual(try Self.depthFaults(JSONSerialization.data(withJSONObject: o)).count, 1,
                               "positive control: depth_mm \(broken.map { "\($0)" } ?? "absent") is seen")
            }
        }
        print("WIRE-DEPTH \(docsChecked) documents · \(facesSeen) face regions · \(boltsSeen) bolt regions · 0 faults")
        XCTAssertGreaterThan(facesSeen, 0); XCTAssertGreaterThan(boltsSeen, 0, "the fixture's bolt is checked too")
    }

    /// (a) an old saved project with a non-default wall setting opens, draws the full prism, AND its job carries
    /// depth_mm = the prism's own depth (20 mm here — never the old 50 % slab's 10 mm).
    func testAnOldWallSettingsJobCarriesThePrismsOwnDepth() throws {
        let (p, _, _) = VariantFacePrismFixture.project()
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(p.lattice)) as? [String: Any])
        obj["wallThickness"] = LatticeWallDepthRemovedTests.oldWallKey
        p.lattice = try JSONDecoder().decode(LatticeSettings.self, from: JSONSerialization.data(withJSONObject: obj))
        let regions = p.latticeJobRegions().regions
        let wall = try XCTUnwrap(regions.first { $0.kind == .face && $0.role == .include })
        XCTAssertEqual(wall.depthMM, 20, accuracy: 1e-9, "the prism's own depth (paintDepthMM)")
        // the job: every face region's depth_mm is its prism's depth
        let faces = p.variantLatticeJobRegions().regions.filter { $0.kind == .face }
        XCTAssertFalse(faces.isEmpty)
        for (label, d) in try VariantFacePrismFixture.variantDocuments(p) {
            let wired = try laticeRegions(d).filter { $0["kind"] as? String == "face" }
            XCTAssertEqual(wired.count, faces.count, label)
            for (w, r) in zip(wired, faces) {
                let dm = try XCTUnwrap(((w["geometry"] as? [String: Any])?["depth_mm"] as? NSNumber)?.doubleValue, label)
                XCTAssertEqual(dm, r.depthMM, accuracy: 1e-12, "★ \(label): depth_mm is the prism's depth")
                XCTAssertNotEqual(dm, 0.5 * r.depthMM, "never the old slab")
            }
        }
        // and the preview draws the whole prism
        let scene = LatticeSDFScene(mesh: try XCTUnwrap(p.viewerMesh), field: nil, latticeID: "octet",
                                    regions: regions, whenEmpty: .latticeNothing)
        let r = try XCTUnwrap(scene.regions.first { $0.kind == .face && $0.role == .include })
        let n = r.normal / simd_length(r.normal)
        // a point on the outline's interior, 0.9 · depth in
        let loop = try XCTUnwrap(r.outlinePolygon.first)
        let uv = loop.reduce(SIMD2<Double>.zero, +) / Double(loop.count)
        let (bu, bv) = LatticeRegionMask.basisForTests(n)
        let deep = r.origin + bu * uv.x + bv * uv.y + n * (0.9 * r.depthMM)
        XCTAssertTrue(LatticeRegionMask.contains(deep, region: r), "★ the preview's region reaches 0.9 · depth")
    }
}
