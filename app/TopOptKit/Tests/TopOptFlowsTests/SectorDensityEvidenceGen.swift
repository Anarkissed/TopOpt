// SectorDensityEvidenceGen.swift — WHAT THE SECTOR DENSITY CONTROL ACTUALLY SAYS
// (task 2026-08-16-per-sector-density-override, §3).
//
// Prints the exact strings the page renders, for his own part's numbers, through
// the REAL bridge derivation — not a stub. This is not a device screenshot and is
// not presented as one: it is the model's own output, which is what decides every
// number and word on those rows.

import XCTest
@testable import TopOptFlows
import TopOptKit

final class SectorDensityEvidenceGen: XCTestCase {

    func testWriteSectorDensitySurfaceEvidence() throws {
        // His part, face 15 split 1x2: both sectors measure 13.6422 mm through the
        // body (run_info.json, the completed override run). Profile width 0.42 mm.
        let extent = 13.64223442, width = 0.42
        var lines: [String] = []
        func row(_ name: String, _ stated: Double?) {
            let d = TopOptKit.latticeRegionDerivation(
                topology: "octet", memberWidthMM: extent,
                minExtrudableWidthMM: width, statedRelativeDensity: stated ?? 0)
            let r = LatticeSectorDensity.Row(id: UUID(), name: name,
                                             extentMM: extent, stated: stated,
                                             derivation: d)
            lines.append("  \(name)   \(r.isAuto ? "[Auto] " : "       ")"
                         + "\(Int((d.relativeDensity * 100).rounded())) %")
            lines.append("      \(r.readout)")
            if let range = r.validRange {
                lines.append(String(format: "      valid here: %.0f–%.0f %%",
                                    range.lowerBound * 100, range.upperBound * 100))
            }
            if let why = r.refusal { lines.append("      ⚠︎ \(why)") }
        }

        lines.append("=== THE SECTOR DENSITY SECTION, as the page renders it ===")
        lines.append("part: M2_verticalStand, face 15 split 1x2, both sectors 7.5 mm deep")
        lines.append("both sectors measure \(extent) mm through the body; profile width \(width) mm")
        lines.append("")
        lines.append("--- untouched project (what a user sees before dialling anything) ---")
        row("Sector 1", nil); row("Sector 2", nil)
        lines.append("")
        lines.append("--- after dialling 25 % and 60 % — the task's headline ---")
        row("Sector 1", 0.25); row("Sector 2", 0.60)
        lines.append("")
        lines.append("--- a density core will REFUSE (6 %) ---")
        row("Sector 1", 0.06)
        lines.append("")
        lines.append("--- a region too thin to lattice at all (0.5 mm) ---")
        let thin = TopOptKit.latticeRegionDerivation(
            topology: "octet", memberWidthMM: 0.5, minExtrudableWidthMM: width,
            statedRelativeDensity: 0.30)
        let tr = LatticeSectorDensity.Row(id: UUID(), name: "Sliver", extentMM: 0.5,
                                          stated: 0.30, derivation: thin)
        lines.append("  Sliver          30 %")
        lines.append("      \(tr.readout)")
        lines.append("      ⚠︎ \(tr.refusal ?? "")")
        lines.append("      (no valid range offered: \(tr.validRange == nil))")
        lines.append("")
        lines.append("--- the one-line summary on the collapsed ladder row ---")
        let a = SelectionGroup(id: UUID(), name: "Sector 1", colorIndex: 0, faces: [])
        let b = SelectionGroup(id: UUID(), name: "Sector 2", colorIndex: 1, faces: [])
        var spec = LatticeRegionSpec(role: .include, kind: .face)
        spec.halfUMM = 20; spec.halfWMM = 20; spec.depthMM = extent
        let roles: [UUID: LatticeGroupRole] = [a.id: .include, b.id: .include]
        for (label, dens) in [("nothing dialled", [UUID: Double]()),
                              ("one dialled", [a.id: 0.25]),
                              ("both dialled", [a.id: 0.25, b.id: 0.60])] {
            let rows = LatticeSectorDensity.rows(
                groups: [a, b], roles: roles, densities: dens,
                regionsFor: { _ in [spec] }, topology: "octet",
                minExtrudableWidthMM: width)
            lines.append("  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))"
                         + "\"\(LatticeSectorDensity.summary(rows))\"")
        }
        lines.append("")
        lines.append("--- and the Optimize button, with a refusable density present ---")
        let blocked = LatticeOptimizeSurface.compute(
            baseCanOptimize: true, baseSummary: "PLA · 128", latticeEnabled: true,
            densityMode: .auto, topologyDisplayName: "Octet", cellMM: 2.728,
            bounds: nil, running: false, lineWidthMM: width,
            densityRefusals: [("Sector 1",
                               "0.27 mm strut, under the profile's extrusion width")])
        lines.append("  enabled: \(blocked.enabled)")
        lines.append("  sub:     \"\(blocked.sub)\"")

        let text = lines.joined(separator: "\n") + "\n"
        print(text)
        var u = URL(fileURLWithPath: #filePath)
        // …/Tests/TopOptFlowsTests/<this file> → the worktree root is FIVE up.
        for _ in 0..<5 { u.deleteLastPathComponent() }
        let dir = u.appendingPathComponent(
            "evidence/2026-08-16-per-sector-density-override")
        // ★ NO SILENT SKIP. The first cut of this wrote the file only `if
        // fileExists(dir)` and got the depth wrong, so it PASSED while writing
        // nothing — a generator that produces no evidence and reports success is
        // the exact shape of a check that measures nothing. It asserts instead.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "the evidence directory must exist: \(dir.path)")
        let out = dir.appendingPathComponent("r3_app_surface.txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "and the file must be on disk afterwards")
        XCTAssertTrue(text.contains("25 %") && text.contains("60 %"))
    }
}
