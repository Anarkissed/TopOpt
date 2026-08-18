// SurfaceDoubleTapMatchEvidence.swift — ★ BAR R2: THE MATCH COUNT ON HIS OWN PART.
//
// "★ THE SIMILAR-FACE MATCH COUNT REPORTED on his part, against PR 331's measured
//  24-of-78. ★If your number differs, say why before assuming yours is right."
//
// ── THE TWO NUMBERS ARE MEASURING DIFFERENT THINGS ───────────────────────────
//
// PR 331's 24-of-78 (handoff 2026-08-14-face-regions, evidence
// `r2_r3_his_part.txt` §2) is ONE filter evaluated ONCE over the whole part:
//
//     blend(maxAreaMM2: 41.95)   — 0.25 × the median face area
//     -> 24 faces, and the naive kind == "other" reading matched 30 but MISSED 13
//        of those and OVER-CAUGHT 19 the blend filter rejects.
//
// The double tap does not evaluate that filter. It evaluates
// `ProjectModel.surfaceSimilarFilter(to:)` — the SHIPPED signature, which reads
// its threshold off THE FACE THAT WAS TAPPED, not off the part. So the answer is
// a number PER SEED, and there is no single count to compare. This generator
// therefore reports both: PR 331's part-level filter reproduced exactly, and the
// per-seed distribution the double tap actually produces.
//
// ★ AND IT IS A GENERATOR, NOT A THRESHOLD. It asserts only what must not drift —
// that the part still has 78 faces, that PR 331's filter still matches 24 of them,
// and that no double tap sweeps up half the model the way a kind-only filter did.
// The distribution goes in the evidence, where a human can read it.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SurfaceDoubleTapMatchEvidence: XCTestCase {

    private var evidenceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TopOptFlowsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TopOptKit
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("evidence/2026-08-17-surface-stage-gestures",
                                    isDirectory: true)
    }

    /// His part, through the same importer the app uses.
    private func hisPart() throws -> ViewerMesh {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/M2_verticalStand.step").path
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture absent")
        }
        let im = try TopOptKit.importMesh(path: fixture)
        return ViewerMesh(vertices: im.vertices, indices: im.indices,
                          faceIDs: im.faceIDs, faceGeometry: im.faceGeometry)
    }

    func testTheDoubleTapMatchCountOnHisPart() throws {
        let mesh = try hisPart()
        let project = ProjectModel(id: UUID(), name: "M2", material: "ABS",
                                   process: .fdm, importedFile: nil,
                                   importedMesh: nil)
        project.viewerMesh = mesh

        let areas = FaceRegionGeometry.faceAreas(in: mesh)
        let withArea = areas.filter { $0.value > 0 }
        let sorted = withArea.values.sorted()
        let median = sorted[sorted.count / 2]
        let faceCount = mesh.faceGeometry.count

        var out = ""
        func line(_ s: String = "") { out += s + "\n"; print("R2 " + s) }

        line("=== 1. THE PART ===")
        line("part                 Fixtures/M2_verticalStand.step")
        line("faces                \(faceCount)  (\(withArea.count) with area)")
        line(String(format: "median face area     %.4g mm^2", median))
        var kinds: [String: Int] = [:]
        for f in 0..<Int32(faceCount) {
            let k: String
            switch mesh.faceGeometry(f)?.kind {
            case .plane:    k = "plane"
            case .cylinder: k = "cylinder"
            default:        k = "other"
            }
            kinds[k, default: 0] += 1
        }
        line("kinds                " + kinds.sorted { $0.key < $1.key }
                                             .map { "\($0.key) \($0.value)" }
                                             .joined(separator: "  "))
        line()

        // ── PR 331's OWN NUMBER, REPRODUCED ────────────────────────────────
        line("=== 2. PR 331'S PART-LEVEL BLEND FILTER (the 24-of-78) ===")
        let threshold = median * 0.25
        let pr331 = FaceRegionGeometry.match(.blend(maxAreaMM2: threshold), in: mesh)
        line(String(format: "threshold            %.4g mm^2  (0.25 x median)", threshold))
        line("blend  (small + 2 larger)   \(pr331.count) faces   <- PR 331 measured 24")
        let kindOther = (0..<Int32(faceCount)).filter {
            mesh.faceGeometry($0)?.kind != .plane
                && mesh.faceGeometry($0)?.kind != .cylinder
        }
        line("kind == other               \(kindOther.count) faces   <- the NAIVE reading "
             + "(PR 331: 30)")
        let blendSet = Set(pr331)
        let otherSet = Set(kindOther)
        line("`other` MISSES              \(blendSet.subtracting(otherSet).count) "
             + "of the blend matches   <- PR 331: 13")
        line("`other` OVER-CATCHES        \(otherSet.subtracting(blendSet).count) "
             + "faces the blend filter rejects   <- PR 331: 19")
        line()

        // ── WHAT THE DOUBLE TAP ACTUALLY PRODUCES, PER SEED ────────────────
        line("=== 3. THE DOUBLE TAP, ONE SEED AT A TIME ===")
        line("(`surfaceSimilarFilter(to:)` — the shipped signature. Its threshold is")
        line(" read off the TAPPED face, so the count is per seed, not per part.)")
        line()
        var counts: [Int] = []
        var byRule: [String: [Int]] = [:]
        var noFilter = 0
        for f in 0..<Int32(faceCount) {
            guard let filter = project.surfaceSimilarFilter(to: f) else {
                noFilter += 1
                continue
            }
            let n = FaceRegionGeometry.match(filter, in: mesh).count
            counts.append(n)
            let rule: String
            if filter.cylinderRadiusMM > 0 { rule = "bore (radius)" }
            else if filter.maxAreaMM2 > 0 && filter.minAreaMM2 <= 0 { rule = "blend" }
            else { rule = "kind + size band" }
            byRule[rule, default: []].append(n)
        }
        let sortedCounts = counts.sorted()
        line("seeds that yield a rule     \(counts.count) of \(faceCount) "
             + "(\(noFilter) have no area and yield none)")
        line("matches  min/median/max     \(sortedCounts.first ?? 0) / "
             + "\(sortedCounts[sortedCounts.count / 2]) / \(sortedCounts.last ?? 0)")
        line(String(format: "mean                        %.2f faces  (%.1f%% of the part)",
                    Double(counts.reduce(0, +)) / Double(max(counts.count, 1)),
                    100 * Double(counts.reduce(0, +)) / Double(max(counts.count, 1))
                        / Double(faceCount)))
        for (rule, ns) in byRule.sorted(by: { $0.key < $1.key }) {
            let s = ns.sorted()
            line("  \(rule.padding(toLength: 18, withPad: " ", startingAt: 0))"
                 + "seeds \(ns.count)   min/med/max "
                 + "\(s.first!) / \(s[s.count / 2]) / \(s.last!)")
        }
        line()
        var histogram: [Int: Int] = [:]
        for n in counts { histogram[n, default: 0] += 1 }
        line("count -> how many seeds give it")
        for (n, k) in histogram.sorted(by: { $0.key < $1.key }) {
            line("  \(String(n).padding(toLength: 4, withPad: " ", startingAt: 0))"
                 + "\(String(repeating: "#", count: min(k, 60))) \(k)")
        }
        line()

        // ── AND THE COMPARISON THE BAR ASKED FOR ───────────────────────────
        line("=== 4. WHY THE NUMBER DIFFERS FROM 24 ===")
        line("PR 331's 24 is ONE filter over the WHOLE part at 0.25 x median.")
        line("The double tap derives a filter FROM THE TAP, so on this part it")
        line("gives \(sortedCounts.first ?? 0)-\(sortedCounts.last ?? 0) faces "
             + "depending on which face is tapped, median "
             + "\(sortedCounts[sortedCounts.count / 2]).")
        line("Both numbers are reproduced above from the same part, so neither is")
        line("being taken on trust. The 24 is unchanged (\(pr331.count)); the")
        line("per-seed spread is what a TAP can produce and is new information.")
        let kindOnlyWorst = (0..<Int32(faceCount)).map { f -> Int in
            var kindOnly = RegionFilter()
            switch mesh.faceGeometry(f)?.kind {
            case .plane:    kindOnly.kind = "plane"
            case .cylinder: kindOnly.kind = "cylinder"
            default:        kindOnly.kind = "other"
            }
            return FaceRegionGeometry.match(kindOnly, in: mesh).count
        }.max() ?? 0
        line("A KIND-ONLY filter's worst seed still matches \(kindOnlyWorst) of "
             + "\(faceCount) faces")
        line("(\(Int((100.0 * Double(kindOnlyWorst) / Double(faceCount)).rounded()))% of "
             + "the model) — the wrong answer PR 331 proved wrong, not used here.")

        try FileManager.default.createDirectory(at: evidenceDir,
                                                withIntermediateDirectories: true)
        try out.write(to: evidenceDir.appendingPathComponent("r2_similar_match_count.txt"),
                      atomically: true, encoding: .utf8)

        // ── WHAT MUST NOT DRIFT ────────────────────────────────────────────
        XCTAssertEqual(faceCount, 78, "★ his part still has 78 faces")
        XCTAssertEqual(pr331.count, 24,
                       "★ PR 331's blend filter still matches 24 of 78 — the "
                       + "measurement this task was told to reuse")
        XCTAssertEqual(blendSet.subtracting(otherSet).count, 13,
                       "★ and kind-only still MISSES 13 of them")
        XCTAssertEqual(otherSet.subtracting(blendSet).count, 19,
                       "★ and still OVER-CATCHES 19")
        XCTAssertLessThan(sortedCounts.last ?? 0, faceCount / 2,
                          "★ NO DOUBLE TAP SWEEPS UP HALF THE PART. A kind-only "
                          + "filter's worst seed took \(kindOnlyWorst) of \(faceCount); "
                          + "the measured signature's worst takes "
                          + "\(sortedCounts.last ?? 0)")
    }
}
