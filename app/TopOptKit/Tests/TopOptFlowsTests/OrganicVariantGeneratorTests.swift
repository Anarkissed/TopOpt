import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE SHIPPED VARIANTS (2026-09-04). Not a test of behaviour: when
/// `GENERATE_ORGANIC_VARIANTS=1` this traces the cube for the wizard's default organic
/// picks and writes each topology as a beam-lattice 3MF into the bundle's
/// `OrganicSample/variants/`, keyed exactly as the app will look them up. Otherwise it
/// only checks that whatever is shipped still matches the current key (a stale
/// variant after a core bump is a silent miss, not a wrong picture).
final class OrganicVariantGeneratorTests: XCTestCase {
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<5 { u.deleteLastPathComponent() }; return u
    }()
    static var variantsDir: URL {
        repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/OrganicSample/variants", isDirectory: true)
    }
    /// The wizard's default organic picks, and the three neighbours it offers first.
    static func defaultPicks() -> [(name: String, picks: OrganicSampleCube.Picks)] {
        var s = LatticeSettings(); s.enabled = true
        var m = LatticeWizardModel(settings: s); m.selectOrganic()
        let base = m.applied(to: s)
        let layer = PrintParams.fdmDefault.layerHeightMM
        var out: [(String, OrganicSampleCube.Picks)] = []
        for (name, grow, mode) in [("traced-auto", false, LatticeCellSizeMode.auto), ("traced-fit", false, .fit),
                                   ("grown-auto", true, .auto), ("grown-fit", true, .fit)] {
            var v = base; v.organicGrowth = grow; v.cellSizeMode = mode
            out.append((name, OrganicSampleCube.Picks(settings: v, layerHeightMM: layer)))
        }
        return out
    }

    func testShippedVariantsMatchTheCurrentKeys() throws {
        let generate = ProcessInfo.processInfo.environment["GENERATE_ORGANIC_VARIANTS"] == "1"
        let dir = Self.variantsDir
        let shipped = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".3mf") } ?? []
        var missing: [String] = []
        for (name, picks) in Self.defaultPicks() {
            let key = OrganicVariantCache.key(picks: picks, fieldIdentity: OrganicSampleCube.fieldIdentity)
            if !shipped.contains("\(key).3mf") { missing.append("\(name) → \(key)") }
        }
        if generate {
            OrganicSampleCube.configPaths = (
                Self.repoRoot.appendingPathComponent("core/src/materials/materials.json").path,
                Self.repoRoot.appendingPathComponent("core/src/settings/rules.json").path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let exp = expectation(description: "generate")
            Task {
                for (name, picks) in Self.defaultPicks() {
                    let key = OrganicVariantCache.key(picks: picks, fieldIdentity: OrganicSampleCube.fieldIdentity)
                    try? FileManager.default.removeItem(at: OrganicVariantCache.cachedURL(for: key))
                    let t0 = Date()
                    guard let b = await OrganicSampleCube.baked(picks: picks, latticeID: "octet") else { print("GEN \(name): FAILED"); continue }
                    let src = OrganicVariantCache.cachedURL(for: key)
                    let dst = dir.appendingPathComponent("\(key).3mf")
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.copyItem(at: src, to: dst)
                    let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? -1
                    print("GEN \(name): \(key) \(size) bytes " + String(format: "%.0f s · ", Date().timeIntervalSince(t0)) + String(b.measurement.prefix(120)))
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: 3600)
        } else if !missing.isEmpty {
            // Not a failure: a shipped variant only makes the first bake instant. Say it.
            print("★ no shipped variant for: " + missing.joined(separator: "; ") + " — run with GENERATE_ORGANIC_VARIANTS=1")
        }
    }
}
