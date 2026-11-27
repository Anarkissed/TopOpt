// FlexibleOverlaySeamTests — a SPLIT face's two dented maps stay joined (task
// 2026-09-29-flexible-screens, verifier round).
//
// ★ THE DEFECT THIS PINS. Each quad corner of the dented map is the mean of the columns that
// share it — but only the columns of its OWN region. The two sectors of a split face never
// shared a corner, so under squish the 10 kg and 25 kg maps stepped apart along the cut and
// dark cracks opened onto the part's inside (the first thing he sees after splitting a face
// and pressing Generate). Now a corner that two loaded regions share (same place, same load)
// takes the mean over BOTH regions' columns, and the surfaces meet.
// ★ RED CONTROL: the per-region rule (`joinRegions: false`) tears the seam; and on a face
// with no sector the join changes nothing.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleOverlaySeamTests: XCTestCase {

    struct Split {
        let overlay: FlexibleOverlayMesh
        let keys: [FlexFaceKey]
        let stacks: [FlexFaceKey: FlexStackInfo]
        let depths: [FlexFaceKey: [Double?]]
        let uvt: [FlexFaceKey: [Double]]
    }

    /// C1's pad with its top split at x = 50, halves at 10 kg and 25 kg — the evidence
    /// probe's scene, as the page builds it.
    static func splitPad() throws -> Split {
        let m = try TopOptKit.importMesh(path: FlexibleStageTests.padSTL)
        let part = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, pseudoFaces: true)
        let (model, _) = FlexibleRegionsTests.splitTop(part)
        let regions = FlexibleRegions(model: model, mesh: part)
        let topFace = regions.faces(of: FlexibleRegions.wireID(regions.sectors[0]), mesh: part)[0]
        let left = regions.region(at: SIMD3(20, 50, 20), face: topFace, mesh: part)
        let right = regions.region(at: SIMD3(80, 50, 20), face: topFace, mesh: part)
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", nozzleTempC: 220)
        s.setFace(FlexibleFaceSettings(faceRegionID: left, weightKg: 10, deepestMM: 3))
        s.setFace(FlexibleFaceSettings(faceRegionID: right, weightKg: 25, deepestMM: 3))
        var ji = FlexibleJob.Inputs(modelPath: FlexibleStageTests.padSTL, resolution: 50, beadWidthMM: 0.42,
                                    faceCount: 6, settings: s)
        ji.sectorRegions = regions.wire
        let scene = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(ji, fallbackMaterial: "varioshore_tpu"), jobDir: "/")
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
        let map = FlexMap(mode: "both", x: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                          y: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]), centreEdge: .flat, deepestMM: 3)
        var faces: [FlexibleOverlayFace] = [], keys: [FlexFaceKey] = []
        var stacks: [FlexFaceKey: FlexStackInfo] = [:], depths: [FlexFaceKey: [Double?]] = [:], uvt: [FlexFaceKey: [Double]] = [:]
        for (id, kg) in [(left, 10.0), (right, 25.0)] {
            let d = try scene.design(materialsPath: FlexibleStageTests.materialsPath, materialID: "varioshore_tpu",
                                     tempC: 220, face: id, rotation: 0, map: map, weightN: kg * 9.80665,
                                     stamp: nil, build: build)
            XCTAssertNil(d.refusal)
            let st = try scene.stack(face: id, rotation: 0)
            let key = FlexFaceKey(region: id, rotation: 0)
            let geo = try FlexFaceGeometry.compute(scene: scene, key: key, stack: st, partFlat: part.flat.positions)
            faces.append(FlexibleOverlayFace(key: key, faces: Set(regions.faces(of: id, mesh: part)),
                                             cuts: regions.cuts(of: id), stack: st, centres: geo.centres))
            keys.append(key); stacks[key] = st; uvt[key] = geo.partUVT
            depths[key] = FlexibleSquishFace.buildableDepths(stack: st, design: d)
        }
        return Split(overlay: FlexibleOverlayMesh.build(part: part, faces: faces), keys: keys, stacks: stacks,
                     depths: depths, uvt: uvt)
    }

    /// Flat vertices of region `k`'s quads.
    static func quadVertices(_ o: FlexibleOverlayMesh, _ k: FlexFaceKey, _ st: FlexStackInfo) -> Range<Int> {
        let start = o.flatStart[k]!
        return start..<(start + st.columns.count * 6)
    }

    static func position(_ o: FlexibleOverlayMesh, _ v: Int) -> SIMD3<Float> {
        SIMD3(o.mesh.flat.positions[3 * v], o.mesh.flat.positions[3 * v + 1], o.mesh.flat.positions[3 * v + 2])
    }

    func testSplitSectorsStayJoinedUnderTheDent() throws {
        let s = try Self.splitPad()
        let o = s.overlay
        let a = s.keys[0], b = s.keys[1]
        // the pairs: a vertex of one sector's map and a vertex of the other's at the same place
        var bByPlace: [SIMD3<Int32>: [Int]] = [:]
        for v in Self.quadVertices(o, b, s.stacks[b]!) {
            let p = Self.position(o, v)
            bByPlace[SIMD3<Int32>(p * 100, rounding: .toNearestOrEven), default: []].append(v)
        }
        var pairs: [(Int, Int)] = []
        for v in Self.quadVertices(o, a, s.stacks[a]!) {
            let p = Self.position(o, v)
            for w in bByPlace[SIMD3<Int32>(p * 100, rounding: .toNearestOrEven)] ?? [] where simd_distance(p, Self.position(o, w)) < 0.005 {
                pairs.append((v, w))
            }
        }
        func gap(_ disp: [Float]) -> Float {
            var worst: Float = 0
            for (v, w) in pairs {
                let dv = SIMD3(disp[3 * v], disp[3 * v + 1], disp[3 * v + 2]), dw = SIMD3(disp[3 * w], disp[3 * w + 1], disp[3 * w + 2])
                worst = max(worst, simd_distance(dv, dw))
            }
            return worst
        }
        let joined = o.displacements(depths: s.depths, stacks: s.stacks, partUVT: s.uvt)
        let torn = o.displacements(depths: s.depths, stacks: s.stacks, partUVT: s.uvt, joinRegions: false)
        let ga = gap(joined), gt = gap(torn)
        print("FLEX-SEAM split pad (10 kg | 25 kg): \(pairs.count) map vertices shared across the cut; worst step at full load \(ga) mm joined, \(gt) mm per region (control)")
        // ★ THE PREMISE: the two sectors' column grids meet corner to corner along the cut
        XCTAssertGreaterThan(pairs.count, 40, "premise: the sectors must share corners along the cut, or this measures nothing")
        XCTAssertLessThanOrEqual(ga, 1e-4, "the two maps must meet along the cut")
        XCTAssertGreaterThan(gt, 0.1, "control: the per-region rule must tear the seam")
    }

    /// On a face with no sector (one loaded region) the join finds nothing to join: the dent
    /// is bit-identical to the per-region rule.
    func testTheJoinChangesNothingOnAWholeFace() throws {
        let p = try FlexibleSquishTests.pad()
        let depths = FlexibleSquishFace.buildableDepths(stack: p.stack, design: p.design)
        let joined = p.overlay.displacements(depths: [p.key: depths], stacks: [p.key: p.stack], partUVT: [p.key: p.geometry.partUVT])
        let alone = p.overlay.displacements(depths: [p.key: depths], stacks: [p.key: p.stack], partUVT: [p.key: p.geometry.partUVT],
                                            joinRegions: false)
        XCTAssertEqual(joined, alone)
        XCTAssertGreaterThan(joined.map(abs).max() ?? 0, 0.1, "the pad must dent, or this compares nothing")
    }
}
