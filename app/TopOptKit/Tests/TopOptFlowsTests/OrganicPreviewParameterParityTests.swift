import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ EVERY ORGANIC PARAMETER THE RUN SETS, THE PREVIEW SETS TOO (his walk,
/// 2026-09-07: "There are no horizontal struts whatsoever. Where are the ties? None of
/// these vertical struts are connected … even in the preview there are no horizontal
/// struts. That means half the algorithm isn't running. Please ensure the ties and the
/// *entire* lattice algorithm is being pushed through the preview code").
///
/// ★ HE WAS RIGHT, AND THE CAUSE WAS A DEFAULT. `OrganicParams::transfer_ties` is
/// `false` in core's own struct; `run_job` overrides it from the job (the app writes
/// the key, and its default is ON) and the preview bridge never assigned it at all. So
/// the RUN built cross-members between the grown pillars and the PICTURE did not — the
/// one difference is invisible in every test that counts spans, because the pillars are
/// still there. `tie_swirl`, the per-voxel bead and core's density floor were adrift for
/// the same reason: a parameter the run sets and the preview simply never mentioned.
///
/// This is the guard against the next one. It reads both files and requires that the
/// set of `OrganicParams` fields `run_job.cpp` assigns is the set the bridge assigns.
final class OrganicPreviewParameterParityTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The field names assigned as `<recv>.<field> =` — comments and continuation lines
    /// excluded, so a field merely NAMED in prose does not count as carried.
    private func assigned(_ src: String, receiver: String) -> Set<String> {
        var out: Set<String> = []
        for raw in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("/*") else { continue }
            guard let r = line.range(of: "\(receiver).") else { continue }
            let rest = line[r.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty else { continue }
            let after = rest.dropFirst(name.count).drop { $0 == " " }
            guard after.hasPrefix("="), !after.hasPrefix("==") else { continue }
            out.insert(String(name))
        }
        return out
    }

    func testThePreviewCarriesEveryOrganicParameterTheRunSets() throws {
        let run = try text("core/src/cli/run_job.cpp")
        let bridge = try text("app/TopOptKit/Sources/TopOptBridge/bridge.cpp")
        // ★ The run's own tracer parameters: `op` is the OrganicParams it fills before
        // `trace_organic_lattice` / `grow_organic_lattice`.
        let byTheRun = assigned(run, receiver: "op")
        // ★ …and the preview's, which it calls `p`.
        let byThePreview = assigned(bridge, receiver: "p")
        XCTAssertGreaterThan(byTheRun.count, 8, "the reader found nothing — the run moved")
        let missing = byTheRun.subtracting(byThePreview).sorted()
        print("""

        ── organic parameters ──────────────────────────────────────────────
        set by the run ....... \(byTheRun.sorted().joined(separator: ", "))
        set by the preview ... \(byThePreview.sorted().joined(separator: ", "))
        missing .............. \(missing.isEmpty ? "none" : missing.joined(separator: ", "))
        """)
        XCTAssertEqual(missing, [],
                       "★ the run sets these on the tracer and the preview does not, so "
                       + "the picture is built by a different algorithm than the file")
    }

    /// A behavioural pin, not a source-text one: with the ties on, the grown path lays
    /// members ACROSS the pillars, and with them off it does not.
    func testTheTiesReachTheGrownPreviewAndAddCrossMembers() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let n = 20
        let spacing = 1.0
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let e = (k * n + j) * n + i
            let x = Double(i) / Double(n - 1)
            let y = 2 * Double(j) / Double(n - 1) - 1
            // ★ THE TWO TRANSVERSE STRESSES MUST DIFFER. Core refuses a tie whose minor
            // principal ratio is under `kOrganicXferTieMinorRatio`, and a field with
            // sigma_xx == sigma_yy has no minor direction at all — a degenerate fixture
            // refuses every tie and would make this test pass for the wrong reason.
            tensor[6 * e] = 4 + 2 * x; tensor[6 * e + 1] = 1
            tensor[6 * e + 2] = 12                 // mostly vertical: pillars
            tensor[6 * e + 4] = 0.5 * y
        } } }
        let cand = [Bool](repeating: true, count: n * n * n)
        let sep = [Double](repeating: 3.0, count: n * n * n)

        func across(ties: Bool) -> (spans: Int, horizontal: Int) {
            guard let t = TopOptKit.organicTrace(
                nx: n, ny: n, nz: n, spacingMM: spacing, origin: .zero,
                candidate: cand, stressTensor: tensor, separationMM: sep,
                minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
                fieldDims: (2, 2, 2), fieldOrigin: .zero,
                fieldSpacingMM: Double(n) * spacing, bandMM: 1,
                rhoMin: 0.05, rhoMax: 0.6,
                grow: true, layerHeightMM: 0.2,
                transferTies: ties) else { return (0, 0) }
            var h = 0
            for s in t.spans {
                let d = s.b - s.a
                let L = simd_length(d)
                if L > 1e-9, abs(d.z / L) < 0.5 { h += 1 }
            }
            return (t.spans.count, h)
        }
        let off = across(ties: false)
        let on = across(ties: true)
        print("""

        ── the transfer ties, through the preview bridge ────────────────────
        ties off ... \(off.spans) spans, \(off.horizontal) across the build direction
        ties on .... \(on.spans) spans, \(on.horizontal) across the build direction
        """)
        XCTAssertGreaterThan(off.spans, 0, "positive control: the grown path traced something")
        XCTAssertGreaterThan(on.horizontal, off.horizontal,
                             "★ the ties are the horizontal members and they must reach the preview")
    }

    /// The ties are a GROWN-path pass in core, so they belong in the sample cube's cache
    /// key only when the sample is grown — otherwise every traced variant this build
    /// ships is orphaned for a parameter that cannot change its geometry.
    func testTheTiesKeyOnlyTheGrownVariants() {
        var s = LatticeSettings(); s.enabled = true
        s.organicGrowth = false
        var traced = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        let tracedKey = OrganicVariantCache.key(picks: traced, fieldIdentity: "id")
        traced.transferTies = !traced.transferTies
        XCTAssertEqual(OrganicVariantCache.key(picks: traced, fieldIdentity: "id"), tracedKey,
                       "★ a traced variant is identical with the ties on or off")
        s.organicGrowth = true
        var grown = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        let grownKey = OrganicVariantCache.key(picks: grown, fieldIdentity: "id")
        grown.transferTies = !grown.transferTies
        XCTAssertNotEqual(OrganicVariantCache.key(picks: grown, fieldIdentity: "id"), grownKey,
                          "★ a grown variant baked without the ties is a different lattice")
    }

    /// The settings' own values reach the part bake, not the initialiser's defaults.
    func testTheJobsTieSettingsReachThePartPreview() throws {
        let ws = try text("app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("transferTies: lat.organicTransferTies, tieSwirl: lat.organicTieSwirl"),
                      "★ the part preview must take the job's ties, never a default")
        let cube = try text("app/TopOptKit/Sources/TopOptFlows/OrganicSampleCube.swift")
        XCTAssertTrue(cube.contains("transferTies: picks.transferTies, tieSwirl: picks.tieSwirl"),
                      "★ and so must the sample cube")
    }
}
