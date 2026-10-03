import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ MAINTAINER, 2026-10-01, ITEM (b): "add a test comparing LatticeRegionMask.basis(n) with
/// core's plane basis through the bridge, over ±x, ±y, ±z, a spread of oblique normals, and both
/// sides of the |n.x| = 0.9 switch. Core only refuses a disagreement after a solve."
///
/// Core's `plane_basis` is file-local; the bridge reaches it through `resolve_clearance_manual`,
/// the run's own route (`TopOptKit.coreFacePlaneBasis`). Every case goes through the app's REAL
/// wire (`LatticeRegionSpec.wireDictionary(frameAxes:)`) and the JSON bytes it becomes, so core
/// is handed exactly the raw normal and the stated frame a stage job carries:
/// - core's derived (u, w) for that raw normal equals the app's stated frame to 1e-12 — far
///   tighter than core's own 1e-6-in-cosine check (≈ 1.4 mrad), which alone proves too little;
/// - core's verdict on the stated frame is "agrees" (no `frame_conflict`).
final class LatticeFrameBasisVsCoreTests: XCTestCase {

    /// The frame the app's wire states for a face region with this RAW normal, read back from
    /// the JSON bytes; and the raw normal as the bytes carry it.
    private func wire(normal raw: SIMD3<Double>) throws -> (n: SIMD3<Double>, u: SIMD3<Double>, w: SIMD3<Double>) {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(1, 2, 3); r.normal = raw
        r.halfUMM = 5; r.halfWMM = 4; r.depthMM = 6
        let bytes = try JSONSerialization.data(withJSONObject: r.wireDictionary(frameAxes: true))
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let g = try XCTUnwrap(back["geometry"] as? [String: Any])
        func v(_ k: String) throws -> SIMD3<Double> {
            let a = try XCTUnwrap(g[k] as? [Double], "the wire must state \(k)")
            return SIMD3(a[0], a[1], a[2])
        }
        return (try v("normal"), try v("frame_u"), try v("frame_w"))
    }

    private func assertAgrees(_ raw: SIMD3<Double>, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let s = try wire(normal: raw)
        let derived = try XCTUnwrap(TopOptKit.coreFacePlaneBasis(normal: s.n), "bridge failed", file: file, line: line)
        XCTAssertTrue(derived.valid && !derived.conflict, "\(label): core could not derive", file: file, line: line)
        XCTAssertLessThanOrEqual(simd_length(derived.u - s.u), 1e-12,
                                 "★ \(label): u — app \(s.u) vs core \(derived.u)", file: file, line: line)
        XCTAssertLessThanOrEqual(simd_length(derived.w - s.w), 1e-12,
                                 "★ \(label): w — app \(s.w) vs core \(derived.w)", file: file, line: line)
        let verdict = try XCTUnwrap(TopOptKit.coreFacePlaneBasis(normal: s.n, frame: (s.u, s.w)))
        XCTAssertFalse(verdict.conflict, "★ \(label): core refuses the stated frame (after a solve)", file: file, line: line)
        XCTAssertTrue(verdict.valid, label, file: file, line: line)
    }

    /// Positive control: core's verdict path is live — a mirrored, swapped or rotated frame
    /// conflicts. Without this a bridge that always said "agrees" would pass everything below.
    func testCoreRefusesAWrongFrame() throws {
        let s = try wire(normal: SIMD3(0, 0, 1))
        XCTAssertEqual(s.u, SIMD3(0, -1, 0)); XCTAssertEqual(s.w, SIMD3(1, 0, 0))   // core's +z pair
        for (name, f) in [("mirrored", (-s.u, s.w)), ("w negated", (s.u, -s.w)), ("swapped", (s.w, s.u)),
                          ("rotated 90°", (s.w, -s.u))] {
            let v = try XCTUnwrap(TopOptKit.coreFacePlaneBasis(normal: s.n, frame: f))
            XCTAssertTrue(v.conflict, "★ the control: a \(name) frame must conflict")
        }
        XCTAssertFalse(try XCTUnwrap(TopOptKit.coreFacePlaneBasis(normal: s.n, frame: (s.u, s.w))).conflict)
    }

    func testTheSixAxes() throws {
        for n in [SIMD3<Double>(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0),
                  SIMD3(0, 0, 1), SIMD3(0, 0, -1)] {
            try assertAgrees(n, "axis \(n)")
            try assertAgrees(2.5 * n, "axis \(n) ×2.5 (raw, not unit)")
        }
    }

    /// A deterministic spread over the sphere (Fibonacci lattice, 400 directions), each also sent
    /// raw at three lengths — the wire carries the raw normal and both sides normalise it.
    func testASpreadOfObliqueNormals() throws {
        let count = 400, golden = Double.pi * (3 - 5.0.squareRoot())
        for i in 0..<count {
            let z = 1 - 2 * (Double(i) + 0.5) / Double(count)
            let r = (1 - z * z).squareRoot(), t = golden * Double(i)
            let n = SIMD3(r * cos(t), r * sin(t), z)
            for scale in [1.0, 0.37, 7.3] { try assertAgrees(scale * n, "oblique #\(i) ×\(scale)") }
        }
    }

    /// Both sides of the switch (`|n.x| < 0.9` picks ref x, else ref y), to the ulp, at both signs
    /// and with the remainder split between y and z — and a raw (non-unit) normal whose UNIT x lands
    /// at the switch, where the app's and core's normalisations must agree on the side. The basis
    /// turns 180° across it, so a one-ulp disagreement would be a refused stage job.
    func testBothSidesOfTheSwitch() throws {
        // (side of the switch the app's UNIT normal lands on) → the stated u, per series
        var sides: [String: [Bool: SIMD3<Double>]] = [:]
        let k = 0.9
        for x0 in [k.nextDown.nextDown, k.nextDown, k, k.nextUp, k.nextUp.nextUp] {
            for sx in [1.0, -1.0] {
                let rest = (1 - x0 * x0).squareRoot()
                for (fy, fz) in [(1.0, 0.0), (0.0, 1.0), (0.6, 0.8), (-0.8, 0.6)] {
                    let n = SIMD3(sx * x0, rest * fy, rest * fz)
                    try assertAgrees(n, "switch x=\(sx * x0) (\(fy),\(fz))")
                    try assertAgrees(3.7 * n, "switch x=\(sx * x0) (\(fy),\(fz)) ×3.7")
                    sides["\(sx) \(fy) \(fz)", default: [:]][abs(LatticeRegionMask.unit(n).x) < 0.9]
                        = try wire(normal: n).u
                }
            }
        }
        // NOT VACUOUS: every series lands on BOTH sides of the switch, and across it the basis
        // CHANGES (by an angle that depends on the normal — 180° in the xy-plane with x·y > 0,
        // 90° in the xz-plane, none at all when x·y < 0 in the xy-plane), so in most series a
        // one-ulp disagreement about the side would change the stated frame.
        XCTAssertEqual(sides.count, 8)
        var changed = 0
        for (series, bySide) in sides {
            let below = try XCTUnwrap(bySide[true], "\(series): no case below the switch")
            let above = try XCTUnwrap(bySide[false], "\(series): no case above the switch")
            if simd_dot(below, above) < 0.99 { changed += 1 }
        }
        XCTAssertGreaterThanOrEqual(changed, 6, "★ the basis must change across the switch in most series")
        // his parts' closest normals to the switch (102117B9 #130, #169, #42; the stand's face 23)
        for n in [SIMD3(-0.90064237207310438, 0.43460, 0.0), SIMD3(-0.89698, 0.44207, 0.0),
                  SIMD3(0.89546, 0.0, 0.44514), SIMD3(0.9521, 0.0001, -0.3058),
                  SIMD3(0.9999, -0.0001, -0.0165), SIMD3(0.9764, 0, 0.216)] {
            try assertAgrees(n, "his normal \(n)")
        }
    }
}
