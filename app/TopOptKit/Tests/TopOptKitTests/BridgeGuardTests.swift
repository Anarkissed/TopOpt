// ★★ MAINTAINER, 2026-10-03: "THE RULE: no core exception ever crosses the bridge.
// Every bridge.cpp function that calls into core wraps its body … Use one helper, not
// copies … a new bridge test calls each per-type bridge function with every non-live type
// id (sc, bcc, fcc, diamond, kelvin, rhombic, bccz, fccz, reentrant) and with an unknown
// id. Each returns invalid with core's reason; none crashes."
//
// #362 found the crash on #361 421fde3d: LatticeStaleTypeTests aborted (SIGTRAP) because
// 4764ca7e makes core refuse an unmeasured type and `lattice_cell_bounds` let the C++
// exception cross into Swift. A crash here kills the whole test process, so "none
// crashes" is asserted by this class finishing at all.
import XCTest
import simd
@testable import TopOptKit

final class BridgeGuardTests: XCTestCase {

    /// The round's non-live ids, and one core has never heard of.
    static let nonLive = ["sc", "bcc", "fcc", "diamond", "kelvin", "rhombic", "bccz", "fccz", "reentrant"]
    static let unknown = "lattice9"

    /// Core's own words for a type it knows but does not call live, from its own sets.
    private func coreWords(_ id: String) -> String {
        TopOptKit.latticeTypeReadinessPlain(
            TopOptKit.latticeTypeReadiness(id, generatable: TopOptKit.latticeGeneratableTopologies,
                                           certifiable: TopOptKit.latticeCertifiableTopologies))
    }

    /// One answer per per-type bridge function: did it answer, and with what reason.
    private struct Answer { let valid: Bool; let reason: String? }

    /// EVERY per-type bridge function (the cross-checked inventory, round 3), called the way
    /// the app calls it, with valid arguments so the topology is the only thing in question.
    private func perTypeAnswers(_ id: String) -> [String: Answer] {
        var out: [String: Answer] = [:]
        let d = TopOptKit.latticeStrutDiameterMM(topology: id, relativeDensity: 0.2, cellMM: 4)
        out["lattice_strut_diameter_mm"] = Answer(valid: d > 0, reason: TopOptKit.lastCoreRefusal)
        let rho = TopOptKit.latticeRelativeDensity(topology: id, strutRadiusMM: 0.3, cellMM: 4)
        out["lattice_relative_density"] = Answer(valid: rho > 0, reason: TopOptKit.lastCoreRefusal)
        let c = TopOptKit.latticeAestheticDensityCeiling(topology: id)
        out["lattice_aesthetic_density_ceiling"] = Answer(valid: c != nil, reason: TopOptKit.lastCoreRefusal)
        let lim = TopOptKit.latticeLimits(topology: id)
        out["lattice_limits"] = Answer(valid: lim.certifiable, reason: lim.reason)
        let b = TopOptKit.latticeCellBounds(topology: id, minExtrudableWidthMM: 0.45)
        out["lattice_cell_bounds"] = Answer(valid: b.valid, reason: b.reason)
        let r = TopOptKit.latticeRegionDerivation(topology: id, memberWidthMM: 12, minExtrudableWidthMM: 0.45)
        out["lattice_region_derivation"] = Answer(valid: r.valid, reason: r.reason)
        let f = TopOptKit.latticeAestheticCellsPerMemberFloor(topology: id, utilisation: 0.3)
        out["lattice_aesthetic_cells_per_member_floor"] = Answer(valid: f > 0, reason: TopOptKit.lastCoreRefusal)
        let h = TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: id)
        out["lattice_aesthetic_cells_per_member_hard_floor"] = Answer(valid: h > 0, reason: TopOptKit.lastCoreRefusal)
        let m = TopOptKit.latticeMinPrintableCellMM(topology: id, minExtrudableWidthMM: 0.45, maxRelativeDensity: 0.2)
        out["lattice_min_printable_cell_mm"] = Answer(valid: m != nil, reason: TopOptKit.lastCoreRefusal)
        // the plan: a 6×6×6 block of candidates at 1 mm, one 6 mm member
        let n = 216
        let plan = TopOptKit.latticeCellSizePlan(
            nx: 6, ny: 6, nz: 6, spacing: SIMD3<Float>(repeating: 1), origin: .zero,
            candidate: [Bool](repeating: true, count: n), relativeDensity: [Double](repeating: 0.3, count: n),
            memberWidthMM: [Double](repeating: 30, count: n), minCellMM: 2, maxCellMM: 6,
            minExtrudableWidthMM: 0.45, topology: id)
        out["lattice_cell_size_plan"] = Answer(valid: plan != nil, reason: TopOptKit.lastCoreRefusal)
        return out
    }

    static let perTypeFunctions: Set<String> = [
        "lattice_strut_diameter_mm", "lattice_relative_density", "lattice_aesthetic_density_ceiling",
        "lattice_limits", "lattice_cell_bounds", "lattice_region_derivation",
        "lattice_aesthetic_cells_per_member_floor", "lattice_aesthetic_cells_per_member_hard_floor",
        "lattice_cell_size_plan", "lattice_min_printable_cell_mm",
    ]

    /// ★ THE POSITIVE CONTROL: octet, the one live type, answers on every function with no
    /// reason — so "invalid" below is about the type, not a broken call.
    func testOctetAnswersEverywhere() {
        let a = perTypeAnswers("octet")
        XCTAssertEqual(Set(a.keys), Self.perTypeFunctions)
        for (fn, ans) in a {
            XCTAssertTrue(ans.valid, "★ octet must answer on \(fn)")
            XCTAssertNil(ans.reason, "\(fn): no reason when it answers")
        }
    }

    /// ★★ THE RULING'S TEST: every non-live id, every per-type function — invalid, with
    /// core's reason, and no crash (a crash ends this process before the class finishes).
    func testEveryNonLiveTypeIsInvalidWithCoresReason() {
        for id in Self.nonLive {
            let words = coreWords(id)
            XCTAssertFalse(words.isEmpty, id)
            XCTAssertNotEqual(words, TopOptKit.latticeTypeReadinessPlain(.live), "\(id) is not live")
            for (fn, ans) in perTypeAnswers(id) {
                XCTAssertFalse(ans.valid, "★ \(fn)(\(id)) must not answer: its numbers are not its own")
                let why = try? XCTUnwrap(ans.reason, "★ \(fn)(\(id)) must carry core's reason")
                XCTAssertTrue(why?.contains(words) ?? false,
                              "★ \(fn)(\(id)): core's words \"\(words)\", got \(why ?? "nil")")
            }
        }
    }

    /// An id core has never heard of: core's own "unknown lattice topology" reason.
    func testAnUnknownIdIsInvalidWithCoresReason() {
        for (fn, ans) in perTypeAnswers(Self.unknown) {
            XCTAssertFalse(ans.valid, fn)
            XCTAssertTrue(ans.reason?.contains("unknown lattice topology") ?? false,
                          "★ \(fn): core's reason, got \(ans.reason ?? "nil")")
            XCTAssertTrue(ans.reason?.contains(Self.unknown) ?? false, "\(fn) names the id")
        }
    }

    /// The guard's three exits: a normal return clears the reason; a std::exception keeps
    /// e.what(); anything else (an OCCT Standard_Failure is not a std::exception) gets a
    /// generic reason — and none of them crosses into Swift.
    func testTheGuardsThreeExits() {
        XCTAssertEqual(TopOptKit.bridgeGuardSelfTest(1), "")
        XCTAssertEqual(TopOptKit.lastCoreRefusal, "self-test: a std::exception")
        XCTAssertEqual(TopOptKit.bridgeGuardSelfTest(0), "answered")
        XCTAssertNil(TopOptKit.lastCoreRefusal, "★ a call that answers clears the reason")
        XCTAssertEqual(TopOptKit.bridgeGuardSelfTest(2), "")
        XCTAssertTrue(TopOptKit.lastCoreRefusal?.contains("not a std::exception") ?? false,
                      TopOptKit.lastCoreRefusal ?? "nil")
        // a refusal is not left behind for the next caller to misread
        _ = TopOptKit.latticeLimits(topology: "kelvin")
        XCTAssertNotNil(TopOptKit.lastCoreRefusal)
        _ = TopOptKit.latticeLimits(topology: "octet")
        XCTAssertNil(TopOptKit.lastCoreRefusal, "★ cleared by the next call that answers")
    }

    /// The sweep's one non-exception hazard: an export whose triangle names a vertex that
    /// does not exist made core's writer read past the array (undefined behaviour, which no
    /// guard catches). Now it is refused, with the corner named; a valid triangle exports.
    func testAnExportWithABadCornerIsRefusedNotUndefined() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let v: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let bad = ImportedMesh(vertices: v, indices: [0, 1, 7], faceIDs: [0], vertexCount: 3,
                               triangleCount: 1, faceCount: 1, watertight: false)
        XCTAssertThrowsError(try TopOptKit.exportSTL(mesh: bad, to: dir.appendingPathComponent("bad.stl").path)) { e in
            XCTAssertTrue("\(e)".contains("triangle corner 7"), "\(e)")
        }
        let good = ImportedMesh(vertices: v, indices: [0, 1, 2], faceIDs: [0], vertexCount: 3,
                                triangleCount: 1, faceCount: 1, watertight: false)
        XCTAssertNoThrow(try TopOptKit.exportSTL(mesh: good, to: dir.appendingPathComponent("good.stl").path),
                         "control: a valid triangle exports")
    }

    /// ★ "Use one helper, not copies" — and "sweep EVERY bridge function": every function
    /// TopOptBridge.hpp declares has a body that goes through `guarded` first, and the
    /// file keeps no boundary catch of its own beyond the helper and the catches that are
    /// a function's answer (the schema probes; "fills the cell"; organic's non-fatal
    /// synthesis and emission).
    func testEveryDeclaredFunctionGoesThroughTheOneGuard() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("Sources/TopOptBridge")
        let hpp = try String(contentsOf: dir.appendingPathComponent("include/TopOptBridge.hpp"), encoding: .utf8)
        let cpp = try String(contentsOf: dir.appendingPathComponent("bridge.cpp"), encoding: .utf8)
        let names = Self.declaredFunctions(hpp)
        XCTAssertGreaterThanOrEqual(names.count, 60, "the parser found the surface")
        XCTAssertTrue(names.contains("lattice_cell_bounds") && names.contains("run_lattice_job"))
        let lines = cpp.components(separatedBy: "\n")
        var unguarded: [String] = []
        for name in names.sorted() {
            guard let def = lines.lastIndex(where: { l in
                guard let r = l.range(of: name + "(") else { return false }
                let head = l[..<r.lowerBound]
                return !l.hasPrefix(" ") && !l.hasPrefix("//") && (head.hasSuffix(" ") || head.hasSuffix("*"))
                    && !l.trimmingCharacters(in: .whitespaces).hasSuffix(";")
            }) else { unguarded.append("\(name): no definition"); continue }
            var i = def
            while !lines[i].trimmingCharacters(in: .whitespaces).hasSuffix("{") { i += 1 }
            var j = i + 1
            while lines[j].trimmingCharacters(in: .whitespaces).isEmpty
                    || lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("//") { j += 1 }
            let first = lines[j].trimmingCharacters(in: .whitespaces)
            let ok = first.hasPrefix("return guarded") || first.hasPrefix("guarded")
                || (name == "import_step" && first.hasPrefix("#ifdef TOPOPT_BRIDGE_HAS_OCCT")
                    && lines[j + 1].trimmingCharacters(in: .whitespaces).hasPrefix("return guarded"))
            if !ok { unguarded.append("\(name): \(first)") }
        }
        XCTAssertEqual(unguarded, [], "★ every exported function's body goes through the one guard")
        // boundary copies are gone: `catch (const std::exception& e) {` appears only in the
        // helper and in the two answers that keep core's words (schema probe, job_schema_error)
        let stdCatches = lines.filter { $0.contains("catch (const std::exception& e)") }.count
        XCTAssertEqual(stdCatches, 3, "★ the helper + schema_refused_key_by_name + job_schema_error")
        XCTAssertEqual(lines.filter { $0.contains("lattice_topology_from_name") }.count, 0,
                       "★ the per-type functions resolve through core (live_topology)")
    }

    /// The function names TopOptBridge.hpp declares at namespace scope (structs skipped).
    static func declaredFunctions(_ hpp: String) -> Set<String> {
        var text = hpp.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var names = Set<String>()
        var depth = 0
        var statement = ""
        for ch in text {
            if ch == "{" { depth += 1; statement = ""; continue }
            if ch == "}" { depth -= 1; statement = ""; continue }
            if depth != 1 { continue }   // inside `namespace topoptbridge {` only, not a struct
            if ch == ";" {
                let s = statement.trimmingCharacters(in: .whitespacesAndNewlines)
                if let open = s.firstIndex(of: "("),
                   !s.hasPrefix("using"), !s.hasPrefix("typedef"), !s.hasPrefix("struct") {
                    let head = s[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let name = head.split(whereSeparator: { $0 == " " || $0 == "*" || $0 == "&" }).last,
                       name.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" }),
                       head.contains(" ") {
                        names.insert(String(name))
                    }
                }
                statement = ""
            } else {
                statement.append(ch)
            }
        }
        return names
    }
}
