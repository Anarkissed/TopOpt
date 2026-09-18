import XCTest
import Metal
@testable import TopOptFlows

/// ★★ ORGANIC OPENS BOTH CAPS OF A DECLARED WALL; THE OCTET KEEPS THE EYE-ONLY RULE
/// (his 2026-09-18: see-through organic walls, "The fix needs to ONLY be for organic!").
final class LatticeShellBothCapsOrganicOnlyTests: XCTestCase {
    func testTheFlagFollowsTheAlgorithmAndTheShaderReadsIt() throws {
        let src = shellClipMSL
        XCTAssertTrue(src.contains("if (c.gate.z < 0.5) {\n            float3 toEye = c.eye.xyz - mpos;\n            if (dot(sn, toEye) <= 0.0) { continue; }\n        }"),
                      "★ the eye test is skipped only when gate.z says organic")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regs = [(15, 12.0), (2, 13.0)].compactMap { f, d in
            LatticeRegionEmission.planeFor(face: FaceID(f), in: mesh).flatMap {
                LatticeRegionEmission.spec(for: $0, role: .include, depthMM: d, faceID: f) }
        }
        try XCTSkipIf(regs.isEmpty)
        for (algo, want) in [("", Float(0)), ("doubled", 0), ("stepped", 0), ("organic", 1)] {
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", algorithm: algo,
                                        maxDim: 32, regions: regs, whenEmpty: .latticeNothing)
            guard let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("renderer") }
            r.setMesh(mesh); r.setLatticeScene(scene, token: 1)
            r.latticeParams = LatticeProxyParams(latticeID: "octet", cellMM: 11, minRelativeDensity: 0.07, maxRelativeDensity: 0.9)
            XCTAssertEqual(r.shellClipForTests.gate.z, want, "algorithm '\(algo)': both-caps flag")
        }
    }
}
