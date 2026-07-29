// LatticeModeEvidenceGen — writes the handoff evidence for lattice mode (handoff
// 2026-07-29-lattice-mode-ui). Opt-in: set TOPOPT_LATTICE_EVIDENCE_DIR and it writes
// the artifacts there; without it the tests SKIP so a normal run stays fast. It proves
// the load-bearing claims off-device: the certifiable band is READ FROM CORE at runtime
// (U2), LATTICE OFF is byte-identical (U1), the clamps state their reason (the ★ bar),
// and the topology picker renders a true-geometry sample per type through the proxy's
// own sample-patch path (requirement 3). The live iPad screenshot is the maintainer's
// on-device step (U7), per the /app/ precedent.

import XCTest
import Foundation
import simd
import ImageIO
import CoreGraphics
@testable import TopOptFlows
import TopOptKit

@MainActor
final class LatticeModeEvidenceGen: XCTestCase {

    private var outDir: String? { ProcessInfo.processInfo.environment["TOPOPT_LATTICE_EVIDENCE_DIR"] }

    func testWriteEvidence() throws {
        guard let dir = outDir else { throw XCTSkip("set TOPOPT_LATTICE_EVIDENCE_DIR") }
        let base = URL(fileURLWithPath: dir)

        // 1) The certifiable limits, READ FROM CORE via the bridge at runtime.
        var band = "Certifiable lattice limits, read from CORE at runtime (topoptbridge.lattice_limits):\n\n"
        band += "certifiable topologies (core): \(TopOptKit.latticeCertifiableTopologies)\n\n"
        for t in LatticeType.family {
            let l = TopOptKit.latticeLimits(topology: t.id)
            band += String(format: "%-8@ certifiable=%@  band=[%.5f, %.5f]  minCellsPerMember=%.3f\n",
                           t.id as NSString, l.certifiable ? "YES" : "no ",
                           l.rhoMin, l.rhoMax, l.minCellsPerMember)
        }
        band += "\nThe app hardcodes NONE of these — LatticeModeTests."
             + "testNoHardcodedCertifiableBandLiteralsInControlSources greps the control sources for the band.\n"
        try band.write(to: base.appendingPathComponent("certifiable_band_from_core.txt"),
                       atomically: true, encoding: .utf8)

        // 2) LATTICE OFF byte-identical: the two job bodies, and the diff.
        let off = try jobDict(lattice: nil)
        let core = TopOptKit.latticeLimits(topology: "octet")
        var s = LatticeSettings(enabled: true, topologyID: "octet", cellMM: 8,
                                minRelativeDensity: 0.0, maxRelativeDensity: 1.0)
        let spec = try XCTUnwrap(s.runSpec())
        let on = try jobDict(lattice: spec)
        var offOn = "LATTICE OFF vs ON job.json (U1).\n\n"
        offOn += "OFF keys: \(off.keys.sorted())\n"
        offOn += "ON  keys: \(on.keys.sorted())\n\n"
        offOn += "The ONLY added key is \"lattice\":\n\(pretty(on["lattice"]))\n\n"
        var onMinusBlock = on; onMinusBlock.removeValue(forKey: "lattice")
        offOn += "ON minus the lattice block == OFF: "
              + "\(NSDictionary(dictionary: onMinusBlock).isEqual(to: off))\n"
        offOn += "\nGenerate density (uniform build, dense end of the clamped range): "
              + String(format: "%.5f  → strut radius %.4f mm at %.1f mm cell\n",
                       spec.generateRelativeDensity, spec.strutRadiusMM, spec.cellMM)
        try offOn.write(to: base.appendingPathComponent("job_off_vs_on.txt"),
                        atomically: true, encoding: .utf8)

        // 3) Clamp reasons — the ★ "say why" bar, across the scenarios.
        var reasons = "Clamp reasons (LatticeBounds), the ★ 'say why a control is clamped' bar.\n"
        reasons += "Band read from core: [\(core.rhoMin), \(core.rhoMax)]\n\n"
        func dump(_ title: String, _ b: LatticeBounds) {
            reasons += "— \(title)\n"
            reasons += "  density → [\(b.densityLo), \(b.densityHi)] certifiable=\(b.certifiable)\n"
            if let r = b.densityLoReason { reasons += "  low:  \(r)\n" }
            if let r = b.densityHiReason { reasons += "  high: \(r)\n" }
            if let r = b.topologyReason { reasons += "  topo: \(r)\n" }
            if let r = b.cellReason { reasons += "  cell: \(r)\n" }
            if let r = b.strutReason { reasons += "  strut: \(r)\n" }
            reasons += "\n"
        }
        s.minRelativeDensity = 0.0; s.maxRelativeDensity = 0.99
        dump("octet, range 0–99% (both ends out of band)",
             LatticeBounds.compute(settings: s, limits: core, memberMM: 9.4, lineWidthMM: 0.45))
        var bcc = LatticeSettings(enabled: true, topologyID: "bcc")
        dump("bcc (preview-only topology)",
             LatticeBounds.compute(settings: bcc, limits: TopOptKit.latticeLimits(topology: "bcc")))
        var thin = LatticeSettings(enabled: true, topologyID: "octet", cellMM: 16)
        thin.minRelativeDensity = core.rhoMin; thin.maxRelativeDensity = core.rhoMax
        let future = TopOptKit.LatticeLimits(rhoMin: core.rhoMin, rhoMax: core.rhoMax,
                                             certifiable: true, minCellsPerMember: 3)
        dump("octet 16mm cell on a 9.4mm rib, IF core certified 3 cells/member (future)",
             LatticeBounds.compute(settings: thin, limits: future, memberMM: 9.4, lineWidthMM: 0.45))
        try reasons.write(to: base.appendingPathComponent("clamp_reasons.txt"),
                          atomically: true, encoding: .utf8)

        // 4) Topology sample thumbnails — the picker's per-type render (proxy sample path).
        let samplesDir = base.appendingPathComponent("topology_samples")
        try? FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)
        for t in LatticeType.family {
            let mesh = LatticeSamplePatch.mesh(lattice: t, cellMM: LatticeSettings.defaultCellMM,
                                               cells: 2, relativeDensity: 0.5)
            if let img = MeshThumbnail.cgImage(for: mesh, size: 240) {
                writePNG(img, to: samplesDir.appendingPathComponent("\(t.id).png"))
            }
        }

        print("wrote lattice-mode evidence to \(dir)")
    }

    private func jobDict(lattice: LatticeSpec?) throws -> [String: Any] {
        let req = RunRequest(
            modelPath: "/tmp/part.stl", material: "PLA", materialsPath: "", rulesPath: "",
            resolution: 96, projectName: "lattice", anchorFaceIDs: [3], loadGroups: [],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40,
            clearances: [], faceProtections: [], faceProtectionDepthMM: -1, lattice: lattice)
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: req, progress: { _, _, _ in true }, onVariant: { _ in })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
    }

    private func pretty(_ v: Any?) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "\(String(describing: v))" }
        return s
    }

    private func writePNG(_ img: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        _ = CGImageDestinationFinalize(dest)
    }
}
