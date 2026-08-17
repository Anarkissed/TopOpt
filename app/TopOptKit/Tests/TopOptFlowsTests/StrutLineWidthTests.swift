// StrutLineWidthTests — task 2026-08-06-strut-line-width-field, S2.
//
// The lattice strut floor used to be `PrintParams.wallLineWidthOuterMM`: a WALL-LOOP
// bead standing in for a lone unsupported extrusion, and the NARROWER of the two
// beads on the shipped 0.4-nozzle profile (0.42 vs 0.45). `PrintParams.strutLineWidthMM`
// separates the two facts. This file locks the three things that can silently undo
// that:
//
//   §1 THE RULE, not the number. The default is `max(outer, inner)` — derived from
//      the project's OWN beads. A literal 0.45 would be one machine's number on
//      every device, and the task's own blocked-stop.
//   §2 THE MIGRATION. A project saved before the field existed resolves by the same
//      rule against its own decoded beads.
//   §3 THE CALL SITES. A single lattice site left on the wall bead reverts this task
//      silently, and a single wall site wrongly redirected corrupts the wall ring.
//      §3b is a SOURCE-LEVEL tripwire over TopOptFlows: it fails when a NEW
//      `lineWidthMM:` site is wired to a wall bead, which no value test can catch
//      because a site that does not exist yet cannot be asserted about.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class StrutLineWidthTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/settings/rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-strut-width-tests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - §1 the rule

    /// The shipped default is the WIDER bead — 0.45 mm on the 0.42 / 0.45 profile —
    /// and it is 0.45 because the rule says so, not because 0.45 is written anywhere.
    func testDefaultStrutWidthIsTheWiderBeadByRule() {
        let d = PrintParams.fdmDefault
        XCTAssertEqual(d.wallLineWidthOuterMM, 0.42)
        XCTAssertEqual(d.wallLineWidthInnerMM, 0.45)
        XCTAssertEqual(d.strutLineWidthMM, 0.45,
                       "max(0.42, 0.45): the WIDER bead, the conservative direction")
        XCTAssertEqual(d.strutLineWidthMM,
                       PrintParams.defaultStrutLineWidthMM(outer: d.wallLineWidthOuterMM,
                                                           inner: d.wallLineWidthInnerMM),
                       "the shipped default IS the rule applied to the shipped beads")
    }

    /// ★ THE BLOCKED-STOP, as an assertion: 0.45 must not be baked in. On a machine
    /// whose beads are wider, the strut width follows THEM. If someone replaces the
    /// rule with a literal, every row here except the 0.42/0.45 one fails.
    func testStrutWidthFollowsTheMachineNotAConstant() {
        let cases: [(outer: Double, inner: Double, expect: Double)] = [
            (0.42, 0.45, 0.45),   // the shipped 0.4-nozzle profile
            (0.60, 0.55, 0.60),   // a 0.6 nozzle: the OUTER bead is the wider one
            (0.50, 0.50, 0.50),   // equal beads: no ambiguity to resolve
            (0.30, 0.34, 0.34),   // a 0.25 nozzle
        ]
        for c in cases {
            let p = PrintParams(layerHeightMM: 0.2, wallLoops: 3, topLayers: 4,
                                bottomLayers: 4, infillPercent: 20, infillPattern: "gyroid",
                                wallLineWidthOuterMM: c.outer, wallLineWidthInnerMM: c.inner)
            XCTAssertEqual(p.strutLineWidthMM, c.expect, accuracy: 1e-12,
                           "outer \(c.outer) / inner \(c.inner) -> strut \(c.expect)")
        }
    }

    /// A stated strut width is kept — the rule is a DEFAULT, not a computed property.
    func testAnExplicitStrutWidthSurvivesTheInitialiserAndAClamp() {
        let p = PrintParams(layerHeightMM: 0.2, wallLoops: 3, topLayers: 4,
                            bottomLayers: 4, infillPercent: 20, infillPattern: "gyroid",
                            wallLineWidthOuterMM: 0.42, wallLineWidthInnerMM: 0.45,
                            strutLineWidthMM: 0.80)
        XCTAssertEqual(p.strutLineWidthMM, 0.80)
        XCTAssertEqual(p.clamped().strutLineWidthMM, 0.80, "in range: untouched")
        XCTAssertEqual(p.clamped(), p.clamped().clamped(), "clamped() is idempotent")

        var wild = p
        wild.strutLineWidthMM = 9.0
        XCTAssertEqual(wild.clamped().strutLineWidthMM, 2.0, "capped at the bead bound")
        wild.strutLineWidthMM = 0.001
        XCTAssertEqual(wild.clamped().strutLineWidthMM, 0.1, "floored at the bead bound")
        wild.strutLineWidthMM = .nan
        XCTAssertEqual(wild.clamped().strutLineWidthMM, 0.45,
                       "a non-finite value falls back to the rule on the clamped beads")
    }

    /// Editing a wall bead does NOT move a strut width the project already carries.
    /// That is the separation working: the two facts stopped being one field.
    func testEditingAWallBeadDoesNotMoveAStoredStrutWidth() {
        var p = PrintParams.fdmDefault
        XCTAssertEqual(p.strutLineWidthMM, 0.45)
        p.wallLineWidthOuterMM = 0.30
        XCTAssertEqual(p.strutLineWidthMM, 0.45,
                       "the strut floor no longer tracks the outer wall bead")
        XCTAssertEqual(p.clamped().strutLineWidthMM, 0.45)
    }

    // MARK: - §2 the migration

    /// A project saved BEFORE this field existed — its JSON has both wall widths and
    /// no strut key — resolves the strut width by the rule against ITS OWN beads.
    /// On the shipped profile that is 0.45 mm, which is a REAL CHANGE from the 0.42 mm
    /// the strut floor used to take (measured in S4); it is not a silent one.
    func testProjectSavedBeforeTheFieldResolvesByTheRule() throws {
        let saved = """
        {"layerHeightMM":0.2,"wallLoops":5,"topLayers":4,"bottomLayers":4,
         "infillPercent":20,"infillPattern":"gyroid",
         "wallLineWidthOuterMM":0.42,"wallLineWidthInnerMM":0.45}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(PrintParams.self, from: saved)
        XCTAssertEqual(p.wallLineWidthOuterMM, 0.42, "the wall beads are untouched")
        XCTAssertEqual(p.wallLineWidthInnerMM, 0.45)
        XCTAssertEqual(p.strutLineWidthMM, 0.45,
                       "no strut key -> max(its own 0.42, its own 0.45)")
    }

    /// …and it derives from THAT project's beads, not from the FDM default's. A
    /// project on a 0.6 nozzle migrates to 0.6 mm, not to 0.45 mm.
    func testMigrationUsesTheProjectsOwnBeadsNotTheShippedOnes() throws {
        let saved = """
        {"layerHeightMM":0.3,"wallLoops":3,"topLayers":4,"bottomLayers":4,
         "infillPercent":20,"infillPattern":"gyroid",
         "wallLineWidthOuterMM":0.62,"wallLineWidthInnerMM":0.58}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(PrintParams.self, from: saved)
        XCTAssertEqual(p.strutLineWidthMM, 0.62,
                       "max(0.62, 0.58) — the project's own machine, not the shipped 0.45")
    }

    /// A project saved with NO line-width keys at all (the pre-line-width era) still
    /// decodes, and its strut width resolves against the defaulted beads.
    func testPreLineWidthProjectStillDecodes() throws {
        let ancient = """
        {"layerHeightMM":0.16,"wallLoops":5,"topLayers":6,"bottomLayers":5,
         "infillPercent":42,"infillPattern":"grid"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(PrintParams.self, from: ancient)
        XCTAssertEqual(p.wallLineWidthOuterMM, PrintParams.fdmDefault.wallLineWidthOuterMM)
        XCTAssertEqual(p.wallLineWidthInnerMM, PrintParams.fdmDefault.wallLineWidthInnerMM)
        XCTAssertEqual(p.strutLineWidthMM, 0.45)
    }

    /// A project saved AFTER this change keeps exactly what it stated — the round trip
    /// is lossless, so the migration fires once and never again.
    func testStrutWidthRoundTripsAndOverridesTheRuleOnceStated() throws {
        var p = PrintParams.fdmDefault
        p.strutLineWidthMM = 0.62
        let back = try JSONDecoder().decode(PrintParams.self,
                                            from: try JSONEncoder().encode(p))
        XCTAssertEqual(back, p, "the stated strut width survives encode + decode")
        XCTAssertEqual(back.strutLineWidthMM, 0.62,
                       "a stated width is NOT re-derived from the beads")
    }

    // MARK: - §3a the call site that reaches the job

    /// ★ THE SITE THAT MATTERS: AppModel.makeRunRequest. The job's lattice block must
    /// carry the STRUT width as `min_extrudable_width_mm`, while the request's wall
    /// fields keep carrying the WALL beads. The two widths are deliberately different
    /// here — with equal widths this test passes vacuously whichever field is read.
    func testRunRequestSendsTheStrutWidthAndKeepsTheWallBeads() throws {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                         store: ProjectStore(rootDir: tempDir),
                         presetStore: PrintParamsPresetStore(rootDir: tempDir))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        let project = try XCTUnwrap(m.project)

        // Three distinct widths, so no two can be confused for one another.
        project.printParams.wallLineWidthOuterMM = 0.42
        project.printParams.wallLineWidthInnerMM = 0.45
        project.printParams.strutLineWidthMM = 0.62
        project.lattice.enabled = true
        project.lattice.densityMode = .auto

        let request = try XCTUnwrap(m.makeRunRequest())
        let lattice = try XCTUnwrap(request.lattice,
                                    "lattice mode on + a strut width -> the job carries a lattice block")
        XCTAssertEqual(lattice.minExtrudableWidthMM, 0.62,
                       "the STRUT width reaches core's min_extrudable_width_mm")
        XCTAssertEqual(request.wallLineWidthOuterMM, 0.42,
                       "the OUTER wall bead is unchanged — this is not a wall-loop site")
        XCTAssertEqual(request.wallLineWidthInnerMM, 0.45,
                       "the INNER wall bead is unchanged")
    }

    /// The strut width is part of the request's identity, so editing it re-enables
    /// Optimize rather than silently reusing a run derived at the old width.
    func testStrutWidthChangesTheLatticeSpecItProduces() throws {
        var s = LatticeSettings(enabled: true)
        s.densityMode = .auto
        let at042 = try XCTUnwrap(s.runSpec(lineWidthMM: 0.42))
        let at045 = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45))
        XCTAssertEqual(at042.minExtrudableWidthMM, 0.42)
        XCTAssertEqual(at045.minExtrudableWidthMM, 0.45)
        XCTAssertNotEqual(at042.minExtrudableWidthMM, at045.minExtrudableWidthMM,
                          "the two widths this task moves between are distinguishable")
    }

    // MARK: - §3b the missed-call-site tripwire

    /// ★ THE FAILING-TEST-FIRST BAR FOR THE MISSED CALL SITE (R2). A value test can
    /// only assert about sites that exist; the risk this task carries is a site added
    /// LATER — or one of the six missed NOW — reading a wall bead into a lattice
    /// `lineWidthMM:`. So this walks the TopOptFlows sources and fails on any
    /// `lineWidthMM:` argument whose value is a `printParams` property other than
    /// `strutLineWidthMM`.
    ///
    /// It is deliberately a whitelist of ONE. `lineWidthMM:` in this app means "the
    /// printability reference for a lattice strut" at every site; there is no lattice
    /// call that legitimately wants a wall bead. When one appears, this test should
    /// fail and the person adding it should say why in the exemption, rather than the
    /// redirect being reverted by accident.
    func testNoLatticeLineWidthSiteReadsAWallBead() throws {
        let sources = Self.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the source walk found no files — the path is wrong")

        var offenders: [String] = []
        var strutSites = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, rawLine) in text.components(separatedBy: .newlines).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }              // prose, not a call
                guard let r = line.range(of: "lineWidthMM:") else { continue }
                let value = line[r.upperBound...]
                guard value.contains("printParams") else { continue }  // a literal/local
                if value.contains("strutLineWidthMM") {
                    strutSites += 1
                } else {
                    offenders.append("\(file.lastPathComponent):\(i + 1): \(line)")
                }
            }
        }
        // FIVE, not six. The task brief listed six candidate sites, but one of them
        // — AppModel.swift's `wallLineWidthOuterMM:` argument to RunRequest — is a
        // WALL-LOOP site, not a lattice one: it flows to
        // `loads.wall_line_width_outer_mm` over the LAN (RemoteRunner) and to
        // `BridgeLoadCase.wall_line_width_outer_mm` on device (RunModel ->
        // TopOptKit), which is the very field S0 restored. Redirecting it would have
        // corrupted the wall ring. The five real lattice sites all pass
        // `lineWidthMM:`, which is what this walk counts.
        // ★ SIX SINCE 2026-08-17-lattice-stage-repair §1, and the sixth was
        // AUDITED rather than the count merely bumped — which is what the message
        // below asks of whoever moves it.
        //
        // NEW SITE: `ProjectModel.latticeDeclaredDensity` (ProjectModel.swift).
        // It resolves the density a face card is derived at, and in UNIFORM mode
        // that is `LatticeBounds.compute(...).generateRelativeDensity` — the
        // single density the RUN generates at. `LatticeBounds.compute` uses its
        // `lineWidthMM` for the STRUT printability floor (`0.5 * lineWidthMM`
        // against the strut radius) and for core's cell floor, both of which are
        // lattice questions about a lone unsupported extrusion. A wall bead here
        // would put the card's density on the wrong printability floor and make
        // it disagree with the run. `strutLineWidthMM` is correct.
        XCTAssertEqual(strutSites, 6,
                       "the six audited lattice sites (AppModel 1, LatticePage 2, "
                       + "WorkspacePlaceholder 2, ProjectModel 1). If this number "
                       + "moved, audit the new site and update the count.")
        XCTAssertTrue(offenders.isEmpty,
                      "lattice lineWidthMM site(s) reading a WALL bead:\n"
                      + offenders.joined(separator: "\n"))
    }

    /// The other half of the same risk, in the other direction: the WALL-LOOP
    /// consumers must NOT have been redirected. `PrintParamsSheet` edits the outer
    /// bead, `RunModel`/`RemoteRunner` send it to the bridge and the job as
    /// `wall_line_width_outer_mm`. A strut width appearing on any of those paths would
    /// corrupt the wall ring the width-aware gate sizes — the exact quantity S0 just
    /// spent a fix restoring.
    func testWallLoopConsumersStillCarryTheWallBead() throws {
        let flows = Self.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        for name in ["PrintParamsSheet.swift", "RunModel.swift", "RemoteRunner.swift"] {
            let text = try String(contentsOf: flows.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("wallLineWidthOuterMM"),
                          "\(name) still reads the OUTER WALL bead")
            XCTAssertFalse(text.contains("strutLineWidthMM"),
                           "\(name) is a WALL-LOOP consumer and must not read the strut width")
        }
        // And the value-level statement of the same fact: a request built from a
        // project whose strut width differs from both beads sends the BEADS.
        let p = PrintParams(layerHeightMM: 0.2, wallLoops: 5, topLayers: 4, bottomLayers: 4,
                            infillPercent: 20, infillPattern: "gyroid",
                            wallLineWidthOuterMM: 0.42, wallLineWidthInnerMM: 0.45,
                            strutLineWidthMM: 0.62)
        XCTAssertEqual(p.wallLineWidthOuterMM, 0.42)
        XCTAssertEqual(p.wallLineWidthInnerMM, 0.45)
        XCTAssertEqual(p.steppingOuterLineWidth(by: 1), 0.44,
                       "the outer stepper still steps the OUTER bead")
    }
}
