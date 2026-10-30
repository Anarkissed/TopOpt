// FlexibleSquishModulusTests — the squish sim's per-voxel stiffness law, through the bridge
// (task 2026-09-29-flexible-screens, round 5 batch G, §1.2 of the design).
//
// ★ THE LAW. A lattice voxel's modulus is the SECANT of core's own tested curve at its own
// density and operating strain: E = σ(ε*; ρ) / ε*, ε* = clamp(strain, 0.02, the strain limit),
// or ε = 0.05 (below core's first tabulated strain, where the row is linear from (0, 0): the
// INITIAL modulus) where no stack of the group presses it. Solid voxels take the filament's
// solid modulus (varioShore 50 MPa, "printed 210 C / 100 % flow (TDS)"); a skin voxel mixes the
// two by its skin share (Voigt); a shape-only lattice is max(ρ, 0.05)² in relative units.
// Every expected number below is read from core's table through core's own lookup: 220 °C gyroid,
// 10 % nominal = the lowest row (its first point: nominal (0.1, 0.020) → core strain 0.1147).
import XCTest
@testable import TopOptKit

final class FlexibleSquishModulusTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    static var materialsPath: String { repoRoot.appendingPathComponent("core/src/materials/flexible_materials.json").path }
    static var law: FlexSquishLawInfo {
        FlexSquishLawInfo(materialsPath: materialsPath, materialID: "varioshore_tpu", topology: "gyroid", tempC: 220, shapeOnly: false)
    }

    func testTheLawIsTheSecantOfCoresCurve() throws {
        let set = try FlexibleCore.curveSet(path: Self.materialsPath, materialID: "varioshore_tpu", tempC: 220, topology: "gyroid")
        XCTAssertNil(set.refusal)
        let rhoMin = set.densityMin
        // the initial modulus: ε = 0.05 on the linear first segment, 0.020 / 0.1147
        let e0 = try FlexibleCore.squishModulus(law: Self.law, rho: rhoMin, strain: 0, skinFrac: 0)
        print(String(format: "FLEX-G law: rho range %.4f…%.4f · strain limit %.4f · E0(rhoMin) %.5f MPa", set.densityMin, set.densityMax, set.strainLimit, e0))
        XCTAssertEqual(e0, 0.1744, accuracy: 1e-3, "the initial modulus 0.020 / 0.1147")
        // the same from core's own stress_at: E = σ(0.05) / 0.05 (the law IS core's curve)
        let s05 = try FlexibleCore.stressAt(path: Self.materialsPath, materialID: "varioshore_tpu", tempC: 220, topology: "gyroid",
                                            strain: 0.05, density: rhoMin)
        XCTAssertEqual(e0, s05.stressMPa / 0.05, accuracy: 1e-12)
        // the secant at a column's operating strain (the second tabulated point, 0.2294)
        let es = try FlexibleCore.squishModulus(law: Self.law, rho: rhoMin, strain: 0.2294, skinFrac: 0)
        XCTAssertEqual(es, 0.122, accuracy: 1e-3, "0.028 / 0.2294")
        // a strain below 0.02 is read at 0.02 (the first segment: still the initial modulus)
        XCTAssertEqual(try FlexibleCore.squishModulus(law: Self.law, rho: rhoMin, strain: 0.001, skinFrac: 0), e0, accuracy: 1e-9)
        // ρ outside the table is clamped to its ends
        XCTAssertEqual(try FlexibleCore.squishModulus(law: Self.law, rho: rhoMin * 0.5, strain: 0, skinFrac: 0), e0, accuracy: 1e-12)
        let eMax = try FlexibleCore.squishModulus(law: Self.law, rho: set.densityMax, strain: 0, skinFrac: 0)
        XCTAssertEqual(try FlexibleCore.squishModulus(law: Self.law, rho: 0.95, strain: 0, skinFrac: 0), eMax, accuracy: 1e-12)
        XCTAssertGreaterThan(eMax, 5 * e0, "firmer rows are stiffer")
        // solid: the filament's own modulus (flexible_materials.json: 50 MPa)
        XCTAssertEqual(try FlexibleCore.squishModulus(law: Self.law, rho: -1, strain: 0, skinFrac: 0), 50, accuracy: 1e-12)
        // skin: the Voigt mix by the skin share
        XCTAssertEqual(try FlexibleCore.squishModulus(law: Self.law, rho: rhoMin, strain: 0, skinFrac: 0.5), 0.5 * 50 + 0.5 * e0, accuracy: 1e-9)
        // shape only: max(ρ, 0.05)² (relative units)
        var shape = Self.law
        shape.shapeOnly = true
        XCTAssertEqual(try FlexibleCore.squishModulus(law: shape, rho: 0.3, strain: 0.1, skinFrac: 0), 0.09, accuracy: 1e-12)
        XCTAssertEqual(try FlexibleCore.squishModulus(law: shape, rho: 0.01, strain: 0, skinFrac: 0), 0.0025, accuracy: 1e-12)
        XCTAssertEqual(try FlexibleCore.squishModulus(law: shape, rho: -1, strain: 0, skinFrac: 0), 1, accuracy: 1e-12)
        // a calibrate-first filament falls to the shape-only law (its curve set refuses)
        var cal = Self.law
        cal.materialID = "tpu95a_generic"
        XCTAssertEqual(try FlexibleCore.squishModulus(law: cal, rho: 0.3, strain: 0.1, skinFrac: 0), 0.09, accuracy: 1e-12)
        // ★ RED CONTROL (256): the law read on the table's NOMINAL strain axis (no 12.5 / 10.9 skin
        // correction) gives 0.020 / 0.1 = 0.20 MPa, not core's 0.174
        let nominal = try FlexibleCore.squishModulus(law: Self.law, rho: rhoMin, strain: 0, skinFrac: 0, control: 256)
        print(String(format: "FLEX-G law control 256 (nominal axis): %.5f MPa vs core's %.5f", nominal, e0))
        XCTAssertEqual(nominal, 0.20, accuracy: 2e-3)
        XCTAssertGreaterThan(abs(nominal - e0), 0.02, "the control is RED against the law")
    }

    /// The table the design quotes, printed from the law (evidence for the handoff).
    func testPrintTheLawsNumbers() throws {
        for (temp, topo) in [(190.0, "gyroid"), (220.0, "gyroid"), (220.0, "honeycomb")] {
            var l = Self.law
            l.tempC = temp; l.topology = topo
            let set = try FlexibleCore.curveSet(path: Self.materialsPath, materialID: "varioshore_tpu", tempC: temp, topology: topo)
            for rho in [set.densityMin, set.densityMax] {
                let e0 = try FlexibleCore.squishModulus(law: l, rho: rho, strain: 0, skinFrac: 0)
                let es = try FlexibleCore.squishModulus(law: l, rho: rho, strain: 0.229, skinFrac: 0)
                print(String(format: "FLEX-G law %3.0f °C %@ rho %.3f: E0 %.3f MPa · secant(0.229) %.3f MPa", temp, topo, rho, e0, es))
            }
        }
    }
}
