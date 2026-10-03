import XCTest
@testable import TopOptKit
@testable import TopOptFlows

/// ★★ LATTICE TYPES A0 (03-app-spec §1, 2026-10-01): every core-capability probe the app asks,
/// printed with its value ON THE LINKED CORE and PINNED — so the next "sync core" that flips one
/// fails here, by name, instead of changing a job or a screen silently. The values are core
/// 19a1443bee65 (PR 358 at 4a1ccc45, merged one-way). The flip history since the pre-#358 core
/// is docs/handoffs/evidence/2026-09-28-lattice-types-app/probes_flipped.md.
final class LatticeCoreProbeReportTests: XCTestCase {

    func testEveryProbeOnTheLinkedCore() {
        let bools: [(String, Bool)] = [
            ("coreCarriesTheSampleRepairFix", TopOptKit.coreCarriesTheSampleRepairFix),
            ("steppedStructuralCertificationWired", TopOptKit.steppedStructuralCertificationWired),
            ("regionFrameAxesWired", TopOptKit.regionFrameAxesWired),
            ("steppedCellsWired", TopOptKit.steppedCellsWired),
            ("organicStructuralCertificationWired", TopOptKit.organicStructuralCertificationWired),
            ("organicSyntheticStressWired", TopOptKit.organicSyntheticStressWired),
            ("organicProbeWired", TopOptKit.organicProbeWired),
            ("gradingSchemaProbeIsReliable", TopOptKit.gradingSchemaProbeIsReliable),
            ("latticeSchemaAccepts(emit_organic_spans)", TopOptKit.latticeSchemaAccepts(key: "emit_organic_spans")),
            ("gradingSchemaAcceptsCellMode(fit)", TopOptKit.gradingSchemaAcceptsCellMode("fit")),
        ] + ["intent", "stepped_min_tile_mm", "max_relative_density", "shape_grade", "shape_grade_band_mm",
             "structural_certification", "organic_overhang_fillet", "retain_subfloor_in_unloaded_regions",
             "subfloor_stress_fraction", "subfloor_per_region", "report_region_cells"].map {
            ("gradingSchemaAccepts(\($0))", TopOptKit.gradingSchemaAccepts(key: $0))
        }
        print("PROBE-REPORT core \(CoreFingerprint.value)")
        for (k, v) in bools { print("PROBE-REPORT \(k) = \(v)") }
        print("PROBE-REPORT latticeGeneratableTopologies = \(TopOptKit.latticeGeneratableTopologies)")
        print("PROBE-REPORT latticeCertifiableTopologies = \(TopOptKit.latticeCertifiableTopologies)")

        // ★ PINNED. Flipped false → true when #358 was first linked (74e510c4, 2026-09-28):
        let flippedOn = ["coreCarriesTheSampleRepairFix", "steppedStructuralCertificationWired", "regionFrameAxesWired",
                         "gradingSchemaAccepts(stepped_min_tile_mm)", "gradingSchemaAccepts(max_relative_density)",
                         "gradingSchemaAccepts(shape_grade)", "gradingSchemaAccepts(shape_grade_band_mm)",
                         "gradingSchemaAccepts(structural_certification)"]
        // unchanged since before #358, all true
        let unchangedOn = ["organicStructuralCertificationWired", "organicSyntheticStressWired", "organicProbeWired",
                           "gradingSchemaProbeIsReliable", "latticeSchemaAccepts(emit_organic_spans)",
                           "gradingSchemaAcceptsCellMode(fit)", "gradingSchemaAccepts(intent)",
                           "gradingSchemaAccepts(retain_subfloor_in_unloaded_regions)",
                           "gradingSchemaAccepts(subfloor_stress_fraction)", "gradingSchemaAccepts(subfloor_per_region)",
                           "gradingSchemaAccepts(report_region_cells)"]
        // false: the fillet key #358 removed (true → false at 74e510c4; its toggle went with it), and
        // steppedCellsWired — a BROKEN PROBE, false on every core (see the next test)
        let off = ["gradingSchemaAccepts(organic_overhang_fillet)", "steppedCellsWired"]
        let value = Dictionary(uniqueKeysWithValues: bools)
        XCTAssertEqual(Set(value.keys), Set(flippedOn + unchangedOn + off), "every probe is pinned")
        for k in flippedOn + unchangedOn { XCTAssertEqual(value[k], true, "★ \(k) on core \(CoreFingerprint.value)") }
        for k in off { XCTAssertEqual(value[k], false, "★ \(k) on core \(CoreFingerprint.value)") }
        // the offered set: generatable ∩ certifiable — octet alone until core lights a type
        XCTAssertEqual(TopOptKit.latticeGeneratableTopologies, ["octet"], "★ a new GENERATABLE type: light it up (A2)")
        XCTAssertEqual(TopOptKit.latticeCertifiableTopologies, ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"])
    }

    /// ★ steppedCellsWired is a BROKEN PROBE, not a core that lacks the key: its document puts
    /// lattice `cell_mm` + `strut_radius_mm` beside a grading block, which core refuses as a pair —
    /// so the app has never sent `lattice.stepped_cells`. The same document without those two keys
    /// parses. Fixing the probe would add `stepped_cells` to every Stepped / Default Grade octet job
    /// with a baked plan — an octet byte move, so it is the maintainer's to rule (not fixed here).
    func testSteppedCellsWiredIsABrokenProbe() throws {
        func doc(latticeExtras: String) -> Data {
            var text = TopOptKit.latticeProbeBaseJob.replacingOccurrences(
                of: #""output":"#,
                with: #""grading": {"topology": "octet", "min_extrudable_width_mm": 0.4, "cell_mm": 3.0, "algorithm": "stepped"}, "output":"#)
            text.removeLast()
            text += #", "lattice": {"topology": "octet""# + latticeExtras
                + #", "stepped_cells": [{"region_id": 1, "origin_mm": [0, 0, 0], "size_mm": 3.0}]}}"#
            return Data(text.utf8)
        }
        let asProbed = try XCTUnwrap(TopOptKit.jobSchemaError(doc(latticeExtras: #", "cell_mm": 3.0, "strut_radius_mm": 0.4"#)),
                                     "the probe's own document is refused")
        print("PROBE-REPORT steppedCellsWired's document is refused: \(asProbed)")
        XCTAssertFalse(asProbed.contains("stepped_cells"), "★ refused for the cell_mm/strut_radius_mm pair, not for stepped_cells")
        XCTAssertNil(TopOptKit.jobSchemaError(doc(latticeExtras: "")), "★ without that pair, stepped_cells parses on this core")
    }
}
