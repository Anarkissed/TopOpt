import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ MAINTAINER, 2026-10-02, AT THE #358 SYNC: "bridge.cpp:1913 runs lattice_variant_job
/// IN-PROCESS, so the app's relattice receipts still stamp fingerprint 'unknown'. Call
/// topopt::set_build_identity(CoreFingerprint.value, <the linked core's build time>) once at
/// bridge start-up, before the first bridge run … Test it: an in-app relattice receipt names the
/// linked core's fingerprint."
final class CoreBuildIdentityTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    /// Core holds the identity this app links, stated once; a second, DIFFERENT identity is
    /// refused by core and changes nothing (set-once, 23e6154e).
    func testCoreHoldsTheLinkedIdentityAndRefusesASecond() throws {
        XCTAssertNil(CoreBuildIdentity.state(), "★ core took the app's identity")
        XCTAssertFalse(CoreFingerprint.value.isEmpty)
        XCTAssertFalse(CoreFingerprint.buildTime.isEmpty, "build_core.sh stamps the linked core's build time")
        let held = TopOptKit.coreBuildIdentity
        XCTAssertEqual(held.fingerprint, CoreFingerprint.value)
        XCTAssertEqual(held.buildTime, CoreFingerprint.buildTime)
        // the same again is a no-op
        XCTAssertNoThrow(try TopOptKit.stateCoreBuildIdentity(fingerprint: CoreFingerprint.value,
                                                               buildTime: CoreFingerprint.buildTime))
        // a different one is core's refusal, through the bridge's error (never a C++ throw into Swift)
        XCTAssertThrowsError(try TopOptKit.stateCoreBuildIdentity(fingerprint: "not-this-core",
                                                                  buildTime: CoreFingerprint.buildTime)) { e in
            XCTAssertTrue("\(e)".contains("already"), "\(e)")
        }
        XCTAssertEqual(TopOptKit.coreBuildIdentity.fingerprint, CoreFingerprint.value, "★ unchanged by the refusal")
    }

    /// ★ THE RECEIPT: a lattice run through the app's ONE on-device entry (`RunModel.bridgeRunner`
    /// → `latticeBridgeRunner` → `TopOptKit.runLatticeJob` → core's `lattice_variant_job`, in
    /// process) writes `run_info.json` naming the linked core, not "unknown". The part is core's own
    /// fixture (`dead_parity_tab.stl`) with its load case (`organic/dead_parity.json`'s faces).
    @MainActor
    func testAnInAppLatticeReceiptNamesTheLinkedCore() throws {
        let fm = FileManager.default
        let core = Self.repoRoot.appendingPathComponent("core")
        let work = fm.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let model = work.appendingPathComponent("dead_parity_tab.stl")
        try fm.copyItem(at: core.appendingPathComponent("tests/fixtures/organic/dead_parity_tab.stl"), to: model)

        var spec = LatticeSpec(topologyID: "octet", cellMM: 6, strutRadiusMM: 0.6,
                               generateRelativeDensity: 0.3, minRelativeDensity: 0.1, maxRelativeDensity: 0.5,
                               skin: "none", minExtrudableWidthMM: 0.45)
        spec.algorithm = ""
        let request = RunRequest(
            modelPath: model.path, material: "PLA",
            materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
            rulesPath: core.appendingPathComponent("src/settings/rules.json").path, resolution: 48,
            projectName: "identity", anchorFaceIDs: [2],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [9], force: SIMD3(0, 0, -400))],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            lattice: spec, jobMode: "lattice_part")

        let tmp = fm.temporaryDirectory
        let before = Set((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [])
        _ = try RunModel.bridgeRunner(request, { _, _, _ in true }, { _ in })
        let made = Set(try fm.contentsOfDirectory(atPath: tmp.path)).subtracting(before)
            .filter { $0.hasPrefix("lattice-") }
        XCTAssertEqual(made.count, 1, "the run's one output directory: \(made)")
        let out = tmp.appendingPathComponent(try XCTUnwrap(made.first), isDirectory: true)
        defer { try? fm.removeItem(at: out) }
        let info = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: out.appendingPathComponent("run_info.json"))) as? [String: Any])
        XCTAssertEqual(info["fingerprint"] as? String, CoreFingerprint.value,
                       "★ the in-app receipt names the linked core (it said \"unknown\" before #358's call)")
        XCTAssertEqual(info["build_time"] as? String, CoreFingerprint.buildTime)
        print("IDENTITY receipt fingerprint \(info["fingerprint"] ?? "nil") build_time \(info["build_time"] ?? "nil")")
    }

    /// Stated before the first bridge run: at the app's start-up and at the one on-device entry.
    func testItIsStatedAtStartUpAndAtTheRunEntry() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
        }
        let app = try src("AppModel.swift")
        let initBody = try XCTUnwrap(app.range(of: "    ) {\n        // ★ Before any bridge run"))
        XCTAssertTrue(app[initBody.upperBound...].prefix(200).contains("CoreBuildIdentity.state()"),
                      "★ the first statement of AppModel.init")
        let run = try src("RunModel.swift")
        let entry = try XCTUnwrap(run.range(of: "public static func bridgeRunner("))
        let head = String(run[entry.lowerBound...].prefix(1200))
        XCTAssertTrue(head.contains("CoreBuildIdentity.state()"), "★ before the mode routes the run")
        XCTAssertLessThan(try XCTUnwrap(head.range(of: "CoreBuildIdentity.state()")).lowerBound,
                          try XCTUnwrap(head.range(of: "request.jobMode")).lowerBound)
    }
}

/// ★ BRIEF ITEM (a), AT THE #358 SYNC: the picker's verdict and words are core's
/// (`lattice_type_readiness` + `lattice_type_readiness_plain`). The Swift enum mirrors core's by
/// ordinal; these pin the mapping with core's own answers, so a reordering in core goes red.
final class LatticeTypeReadinessFromCoreTests: XCTestCase {

    func testTheOrdinalsAreCoresVerdicts() {
        XCTAssertEqual(TopOptKit.latticeTypeReadiness("octet", generatable: ["octet"], certifiable: ["octet"]), .live)
        XCTAssertEqual(TopOptKit.latticeTypeReadiness("fcc", generatable: [], certifiable: ["fcc"]), .notGeneratable)
        XCTAssertEqual(TopOptKit.latticeTypeReadiness("fcc", generatable: ["fcc"], certifiable: []), .notCertifiable)
        XCTAssertEqual(TopOptKit.latticeTypeReadiness("bccz", generatable: [], certifiable: []), .notEither)
        XCTAssertEqual(TopOptKit.latticeTypeReadiness("lattice9", generatable: [], certifiable: []), .unknownId)
        // an id in either set is one core knows (core's rule), and the joins never split an id
        XCTAssertEqual(TopOptKit.latticeTypeReadiness("lattice9", generatable: ["lattice9", "octet"],
                                                      certifiable: ["octet", "lattice9"]), .live)
    }

    /// The words, recorded as core states them (maintainer-facing wording, 2026-09-30).
    func testThePlainWordsAreCores() {
        XCTAssertEqual(TopOptKit.LatticeTypeReadiness.allCases.map(TopOptKit.latticeTypeReadinessPlain), [
            "Ready to use",
            "Strength-checked, but not buildable yet",
            "Buildable, but not strength-checked yet",
            "Not buildable or strength-checked yet",
            "Not a lattice type",
        ])
    }

    /// The linked core, through the catalog: the octet alone offered; the struts certified but not
    /// built; the tetragonal three neither; the sheets (no core id yet) told core's "neither" line.
    func testTheLinkedCoreThroughTheCatalog() {
        let e = LatticeTypeCatalog.entriesFromCore()
        func why(_ id: String) -> String? { e.first { $0.id == id }?.reason }
        XCTAssertNil(why("octet"))
        XCTAssertEqual(why("kelvin"), "Strength-checked, but not buildable yet")
        XCTAssertEqual(why("reentrant"), "Not buildable or strength-checked yet")
        XCTAssertEqual(why("gyroid"), "Not buildable or strength-checked yet")
        XCTAssertEqual(TopOptKit.latticeTypeReadiness("gyroid", generatable: TopOptKit.latticeGeneratableTopologies,
                                                      certifiable: TopOptKit.latticeCertifiableTopologies),
                       .notEither, "★ #358 at 36f5fdde carries a gyroid id: core's own \"neither\" (was .unknownId at 23e6154e)")
    }
}
