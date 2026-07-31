// LatticePageRound2Tests.swift — the round-2 bars (task lattice-page-round2):
//   M1  ONE selection system: the lattice page renders from the SAME group model
//       the TO page uses — not two models kept in sync.
//   M2  NON-DESTRUCTIVE: no lattice-page interaction can remove a TO-page face
//       or group.
//   M3  REGIONS REACH THE JOB: include + exclude regions appear in the emitted
//       job JSON in the schema core already accepts (PR 256), and the REAL
//       topopt-cli parses them without a schema error (gated on the binary).
//   M4  SPACING IS ONE CONSTANT: every chrome gap is the one token.
//   M5  OVERLAY: selections draw above the density overlay, and a varying field
//       maps to varying colour (never a constant).
// Plus the round-2 items with model surface: T1 (entry-button gate), T3 (grow a
// committed group — in WorkspaceInteractionTests), T4 (lbs default), T5 (one
// listed primitive after convert), L13 (transient notes), L14 (one footnote).

import XCTest
import simd
@testable import TopOptFlows
import TopOptKit

final class LatticePageRound2Tests: XCTestCase {

    // MARK: - fixtures (the ClearanceDerivationTests bore+plane part)

    /// An 8-sided through-bore (face 1, concave winding — a genuine fastener
    /// bore) plus a top plane (face 3), with exact face geometry for both.
    private func borePlusPlaneMesh() -> ViewerMesh {
        let n = 8
        var verts: [Float] = []
        let r: Float = 2.5
        for k in 0..<n { let a = Float(k) * (2 * .pi / Float(n)); verts += [r*cos(a), r*sin(a), 0] }
        for k in 0..<n { let a = Float(k) * (2 * .pi / Float(n)); verts += [r*cos(a), r*sin(a), 10] }
        verts += [0, 0, 10]
        let topCentre: Int32 = 16
        var indices: [Int32] = []
        var faceIDs: [Int32] = []
        func B(_ k: Int) -> Int32 { Int32(k % n) }
        func T(_ k: Int) -> Int32 { Int32(n + (k % n)) }
        for k in 0..<n {
            indices += [B(k), T(k + 1), B(k + 1), B(k), T(k), T(k + 1)]
            faceIDs += [1, 1]
        }
        for k in 0..<n { indices += [topCentre, T(k), T(k + 1)]; faceIDs += [3] }
        let cyl = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 2.5,
                                   axisPoint: SIMD3(0, 0, 0), axisDir: SIMD3(0, 0, 1))
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1),
                                     planeOrigin: SIMD3(0, 0, 10))
        let geo: [StepFaceGeometry] = [StepFaceGeometry(kind: .other), cyl,
                                       StepFaceGeometry(kind: .other), plane]
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs, faceGeometry: geo)
    }

    /// A project with the bore+plane mesh and two TO-page groups: the bore group
    /// committed as an anchor, the plane group committed as a load.
    @MainActor
    private func makeProject() -> (p: ProjectModel, bore: UUID, plane: UUID) {
        let p = ProjectModel(id: UUID(), name: "R2", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = borePlusPlaneMesh()
        var sel = SelectionModel()
        sel.addGroup(); sel.pickFaces([1])
        sel.addGroup(); sel.pickFaces([3])
        p.selection = sel
        let ids = sel.groups.map { $0.id }
        p.force.makeAnchor(ids[0])
        p.force.makeLoad(ids[1])
        p.selection.clearActive()          // the production deselect-on-commit
        return (p, ids[0], ids[1])
    }

    // MARK: - M1 · ONE selection system

    @MainActor
    func testLatticePageRendersFromTheSameGroupModelAsTheTOPage() {
        let (p, bore, plane) = makeProject()

        // The lattice page's library IS `project.selection` — the same value the
        // TO page's panel iterates. Giving a group a lattice role stores ONLY an
        // id-keyed attribute; the group itself neither moves nor copies.
        p.lattice.groupRoles[plane] = .include
        XCTAssertEqual(p.selection.groups.map(\.id), [bore, plane],
                       "roles never move or copy a group")
        XCTAssertEqual(p.selection.groups[1].faces, [3],
                       "the role group's faces are the TO page's own faces")

        // A TO-page mutation is visible to the lattice side INSTANTLY because
        // there is only one store: rename through the selection, read the same
        // group where the lattice role points.
        p.selection.rename(plane, to: "Wing")
        let roleGroups = p.selection.groups.filter { p.lattice.groupRoles[$0.id] != nil }
        XCTAssertEqual(roleGroups.map(\.name), ["Wing"],
                       "one model: the lattice side sees the TO-page rename with no sync step")

        // And the reverse: a lattice-page tap (the non-destructive router) acts on
        // THE SAME model the TO page reads.
        var sel = p.selection
        LatticeLibraryTap.route(faceID: 3, loop: [3], selection: &sel)
        XCTAssertEqual(sel.activeGroupID, plane,
                       "a lattice-page tap selects the TO page's own group object")

        // Structural half: LatticeSettings stores NO group or face collection —
        // only the id-keyed role attribute (a second store is the failure mode
        // this bar exists to prevent; two models that agree today diverge later).
        let mirror = Mirror(reflecting: p.lattice)
        for child in mirror.children {
            let typeName = String(describing: type(of: child.value))
            XCTAssertFalse(typeName.contains("SelectionGroup"),
                           "LatticeSettings must not hold its own group list (\(child.label ?? "?"): \(typeName))")
            XCTAssertFalse(typeName.contains("SelectionModel"),
                           "LatticeSettings must not hold a second SelectionModel (\(child.label ?? "?"))")
        }
    }

    @MainActor
    func testLatticePageSourceHasNoSecondSelectionUI() throws {
        // The page file must not construct its own selection model or define a
        // second library: the ONE `selectionsPanel` lives in WorkspacePlaceholder
        // and is mounted for both contexts.
        let src = try String(contentsOf: sourceURL("LatticePage.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("SelectionModel("),
                       "LatticePage must not build a second selection model")
        XCTAssertFalse(src.contains("var selectionsPanel"),
                       "LatticePage must not define its own selections panel — it opens the workspace's")
        let ws = try String(contentsOf: sourceURL("WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertEqual(ws.components(separatedBy: "var selectionsPanel").count - 1, 1,
                       "exactly ONE selections panel definition exists")
    }

    private func sourceURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()                      // → TopOptFlowsTests/
        url.deleteLastPathComponent()                      // → Tests/
        url.deleteLastPathComponent()                      // → TopOptKit/
        return url.appendingPathComponent("Sources/TopOptFlows/\(name)")
    }

    // MARK: - M2 · non-destructive

    @MainActor
    func testNoLatticePageInteractionCanRemoveATOFaceOrGroup() {
        let (p, bore, plane) = makeProject()
        let originalGroups = p.selection.groups.map(\.id)
        let originalFaces = Dictionary(uniqueKeysWithValues: p.selection.groups.map { ($0.id, Set($0.faces)) })

        func assertNothingLost(_ what: String) {
            for gid in originalGroups {
                let g = p.selection.groups.first { $0.id == gid }
                XCTAssertNotNil(g, "\(what): group \(gid) was removed")
                if let g {
                    let lost = originalFaces[gid]!.subtracting(Set(g.faces))
                    XCTAssertTrue(lost.isEmpty, "\(what): group lost faces \(lost)")
                }
            }
        }

        // 1. Tap an owned face (the anchor's bore) — selects, never toggles off.
        var sel = p.selection
        LatticeLibraryTap.route(faceID: 1, loop: [1], selection: &sel)
        p.selection = sel
        XCTAssertEqual(p.selection.activeGroupID, bore)
        assertNothingLost("owned-face tap")

        // 2. Tap the SAME owned face again — still non-destructive (the TO page's
        //    tap-again-to-deselect must NOT exist here, L23).
        sel = p.selection
        LatticeLibraryTap.route(faceID: 1, loop: [1], selection: &sel)
        p.selection = sel
        assertNothingLost("repeat owned-face tap")

        // 3. Tap an owned face whose loop drags in another group's face — no steal.
        sel = p.selection
        LatticeLibraryTap.route(faceID: 3, loop: [3, 1], selection: &sel)
        p.selection = sel
        assertNothingLost("cross-group loop tap")

        // 4. Set + clear lattice roles.
        p.lattice.groupRoles[bore] = .exclude
        p.lattice.groupRoles[plane] = .include
        p.lattice.groupRoles[plane] = nil
        assertNothingLost("role set/clear")

        // 5. Add a primitive to a role group (the library's "+ primitive").
        _ = p.addManualPrimitive(.bolt, to: bore)
        assertNothingLost("primitive add")

        // 6. A free-face tap grows WITHOUT stealing: face 0 is unowned here (the
        //    barrel bottom ring isn't a listed face id in any group).
        sel = p.selection
        LatticeLibraryTap.route(faceID: 0, loop: [0], selection: &sel)
        p.selection = sel
        assertNothingLost("free-face tap")
    }

    // MARK: - M3 · regions reach the job, in core's schema

    @MainActor
    func testIncludeAndExcludeRegionsReachTheEmittedJobJSON() throws {
        let (p, bore, plane) = makeProject()
        p.lattice.enabled = true
        p.lattice.groupRoles[bore] = .exclude     // the bore face → a bolt region
        p.lattice.groupRoles[plane] = .include    // the plane face → a face region
        p.lattice.paintDepthMM = 4

        let result = p.latticeJobRegions()
        XCTAssertEqual(result.skippedFaces, 0, "both faces carry exact geometry")
        XCTAssertEqual(result.regions.count, 2)
        let roles = Set(result.regions.map(\.role))
        XCTAssertEqual(roles, [.include, .exclude], "BOTH roles are emitted")
        for r in result.regions { XCTAssertTrue(r.isValid, "no refusable entry is emitted") }

        // Through the REAL serializer: the exact wire shape core's job.cpp accepts.
        let spec = try XCTUnwrap(p.lattice.runSpec(topology: "octet", regions: result.regions),
                                 "an octet lattice with regions produces a run spec")
        let job = try Self.jobDict(request: Self.request(lattice: spec))
        let lat = try XCTUnwrap(job["lattice"] as? [String: Any])
        let regions = try XCTUnwrap(lat["regions"] as? [[String: Any]])
        XCTAssertEqual(regions.count, 2)
        for entry in regions {
            XCTAssertEqual(Set(entry.keys), ["role", "kind", "geometry"],
                           "exactly the keys core's strict parser allows")
            let role = try XCTUnwrap(entry["role"] as? String)
            let kind = try XCTUnwrap(entry["kind"] as? String)
            XCTAssertTrue(["include", "exclude"].contains(role))
            let geom = try XCTUnwrap(entry["geometry"] as? [String: Any])
            if kind == "bolt" {
                XCTAssertEqual(Set(geom.keys),
                               ["axis_point", "axis_dir", "radius_mm", "half_length_mm"])
                XCTAssertGreaterThan(try XCTUnwrap(geom["radius_mm"] as? Double), 0)
                XCTAssertGreaterThan(try XCTUnwrap(geom["half_length_mm"] as? Double), 0)
            } else {
                XCTAssertEqual(kind, "face")
                XCTAssertEqual(Set(geom.keys),
                               ["origin", "normal", "half_u_mm", "half_w_mm", "depth_mm"])
                XCTAssertGreaterThan(try XCTUnwrap(geom["depth_mm"] as? Double), 0)
            }
        }
        // The exclude entry is the bore's own cylinder; the include entry is the
        // plane slab, reaching INTO the part (normal flipped from the outward
        // face normal) at the page's region depth.
        let boltEntry = try XCTUnwrap(regions.first { $0["kind"] as? String == "bolt" })
        XCTAssertEqual(boltEntry["role"] as? String, "exclude")
        let faceEntry = try XCTUnwrap(regions.first { $0["kind"] as? String == "face" })
        XCTAssertEqual(faceEntry["role"] as? String, "include")
        let faceGeom = try XCTUnwrap(faceEntry["geometry"] as? [String: Any])
        let normal = try XCTUnwrap(faceGeom["normal"] as? [Double])
        XCTAssertEqual(normal[2], -1, accuracy: 1e-9,
                       "the slab reaches INTO the part (outward +Z flipped)")
        XCTAssertEqual(try XCTUnwrap(faceGeom["depth_mm"] as? Double), 4, accuracy: 1e-9)
    }

    /// The other half of M3: the REAL topopt-cli parses the emitted regions
    /// without a schema error. Runs only when the locally-built CLI exists
    /// (core/build/topopt-cli); schema validation happens BEFORE model import,
    /// so a missing model file is the expected (non-schema) failure — exactly
    /// the real_cli_smoke.py discipline.
    @MainActor
    func testCoreCLIParsesTheEmittedRegions() throws {
        // #filePath = <repo>/app/TopOptKit/Tests/TopOptFlowsTests/…swift → the
        // repo root is 5 components up (file, TopOptFlowsTests, Tests, TopOptKit, app).
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let binary = repo.appendingPathComponent("core/build/topopt-cli")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("core/build/topopt-cli not built — CLI parse pass runs in evidence instead")
        }

        let (p, bore, plane) = makeProject()
        p.lattice.enabled = true
        p.lattice.groupRoles[bore] = .exclude
        p.lattice.groupRoles[plane] = .include
        let spec = try XCTUnwrap(p.lattice.runSpec(topology: "octet",
                                                   regions: p.latticeJobRegions().regions))
        var job = try Self.jobDict(request: Self.request(lattice: spec))
        job["model"] = "/nonexistent/round2-schema-probe.stl"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("r2-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobURL = dir.appendingPathComponent("job.json")
        try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
            .write(to: jobURL)

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["run", jobURL.path, "--out", dir.appendingPathComponent("out").path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""

        // The run must fail on the MISSING MODEL (post-schema), never on the
        // regions schema. Any schema-rejection wording naming our keys is a fail.
        for marker in ["\"role\" must be", "\"kind\" must be", "unknown key",
                       "lattice.regions", "must be > 0", "non-zero"] {
            XCTAssertFalse(out.contains(marker),
                           "core rejected the emitted regions schema: …\(out.suffix(400))")
        }
        XCTAssertNotEqual(proc.terminationStatus, 0,
                          "the probe model does not exist — the failure must be import, not schema silence")
    }

    // MARK: - M3 guardrails: absent roles ⇒ byte-identical, clearances unchanged

    @MainActor
    func testRoleGroupPrimitivesLeaveClearancesAndJoinRegions() {
        let (p, bore, _) = makeProject()
        _ = p.addManualPrimitive(.bolt, to: bore)
        let clearancesBefore = p.clearanceSpecs().count

        // Lattice OFF: a role is stored but INERT — clearances unchanged (U1: the
        // TO-only job cannot shift because a role was set).
        p.lattice.groupRoles[bore] = .exclude
        XCTAssertEqual(p.clearanceSpecs().count, clearancesBefore,
                       "with lattice off, roles change nothing")
        XCTAssertTrue(p.latticeJobRegions().regions.isEmpty)

        // Lattice ON: the role group's primitive is a REGION, not a keep-out —
        // it moves from loads.clearances to lattice.regions, never both.
        p.lattice.enabled = true
        let clearancesAfter = p.clearanceSpecs().count
        let regions = p.latticeJobRegions().regions
        XCTAssertEqual(clearancesAfter, clearancesBefore - 1,
                       "the role group's manual primitive left the clearance list")
        XCTAssertTrue(regions.contains { $0.kind == .bolt && $0.role == .exclude },
                      "…and became an exclude region")
    }

    // MARK: - M4 · one spacing token

    func testChromeSpacingIsOneConstant() throws {
        XCTAssertFalse(LatticeChromeLayout.allGaps.isEmpty)
        for g in LatticeChromeLayout.allGaps {
            XCTAssertEqual(g, LatticeChromeLayout.gap,
                           "every adjacent chrome gap is the ONE token")
        }
        // The task's sizing rule: a little larger than the old chip stack's 9,
        // smaller than the old Preview→Optimize 16.
        XCTAssertGreaterThan(LatticeChromeLayout.gap, 9)
        XCTAssertLessThan(LatticeChromeLayout.gap, 16)
        // And the chrome consumes the named constants — the old raw literals are gone.
        let src = try String(contentsOf: sourceURL("LatticePage.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains(".padding(.top, 74)"), "the From-Setup crowding literal is gone")
        XCTAssertFalse(src.contains("spacing: 9)"), "the old chip stack's 9 pt gap is gone")
        XCTAssertFalse(src.contains(".padding(.bottom, 104)"), "the 104 pt magic inset is derived now")
        XCTAssertTrue(src.contains("LatticeChromeLayout.topLeftRowSpacing"))
        XCTAssertTrue(src.contains("LatticeChromeLayout.titleToFromSetup"))
        XCTAssertTrue(src.contains("LatticeChromeLayout.bottomClusterSpacing"))
        XCTAssertTrue(src.contains("LatticeChromeLayout.reviewDrawerToCluster"))
    }

    // MARK: - M5 · overlay: selections above, gradient real

    func testOverlayMapsAVaryingFieldAndSelectionsDrawAbove() {
        let mesh = borePlusPlaneMesh()
        let params = LatticeProxyParams(latticeID: "octet", cellMM: 8,
                                        minRelativeDensity: 0.1, maxRelativeDensity: 0.9,
                                        gamma: 1, uniformRelativeDensity: 0.5)
        // A field varying along z: bottom quiet, top loud.
        let field = StressField(nx: 2, ny: 2, nz: 4,
                                origin: SIMD3<Float>(-3, -3, 0), spacing: 5,
                                values: (0..<16).map { Float($0) })
        let graded = LatticeDensityProxy.tints(for: mesh, demand: field, params: params)
        XCTAssertGreaterThan(Set(graded.map { "\($0)" }).count, 1,
                             "a varying field maps to VARYING colour — never a constant")

        // Selection override: every vertex of face 3 (the plane) carries the
        // group colour EXACTLY; other faces keep the density colour.
        let green = SIMD4<Float>(0, 1, 0, 1)
        let over = LatticeDensityProxy.tints(for: mesh, demand: field, params: params,
                                             selectionTints: [3: green])
        var planeVerts = 0
        for v in 0..<over.count {
            let face = mesh.faceIDs[v / 3]
            if face == 3 {
                XCTAssertEqual(over[v], green, "selection colour wins over the overlay")
                planeVerts += 1
            } else {
                XCTAssertEqual(over[v], graded[v], "non-selected faces keep the density colour")
            }
        }
        XCTAssertGreaterThan(planeVerts, 0)

        // The uniform (no-field) branch honours the override identically.
        let uni = LatticeDensityProxy.tints(for: mesh, demand: nil, params: params,
                                            selectionTints: [3: green])
        for v in 0..<uni.count where mesh.faceIDs[v / 3] == 3 {
            XCTAssertEqual(uni[v], green)
        }
    }

    // MARK: - T1 · the entry button states what is missing

    func testLatticeEntryButtonGate() {
        let all = LatticeEntryButtonGate.compute(gravitySet: true, anchors: 1, loads: 1)
        XCTAssertTrue(all.enabled)
        XCTAssertTrue(all.missing.isEmpty)

        let none = LatticeEntryButtonGate.compute(gravitySet: false, anchors: 0, loads: 0)
        XCTAssertFalse(none.enabled)
        XCTAssertEqual(none.missing, ["gravity", "an anchor", "a load"])
        XCTAssertEqual(none.subtitle, "needs gravity and an anchor and a load",
                       "the button SAYS what is missing — never just disabled")

        let noGravity = LatticeEntryButtonGate.compute(gravitySet: false, anchors: 2, loads: 1)
        XCTAssertEqual(noGravity.missing, ["gravity"])
        let noLoad = LatticeEntryButtonGate.compute(gravitySet: true, anchors: 1, loads: 0)
        XCTAssertEqual(noLoad.missing, ["a load"])
    }

    // MARK: - T4 · default weight unit

    func testDefaultWeightUnitIsLbs() throws {
        XCTAssertEqual(ForceModel().unit, .lbs, "T4: new projects default to lbs")
        // A pre-unit snapshot decodes to the lbs default too (display only —
        // stored weights are kgf and unchanged).
        let decoded = try JSONDecoder().decode(ForceModel.self,
                                               from: Data("{}".utf8))
        XCTAssertEqual(decoded.unit, .lbs)
    }

    // MARK: - T5 · one listed primitive after the move-icon convert

    @MainActor
    func testConvertingAnAutoClearanceListsExactlyOnePrimitive() throws {
        let (p, bore, _) = makeProject()
        let g = try XCTUnwrap(p.selection.groups.first { $0.id == bore })

        // The anchored bore auto-clears: ONE listed primitive, zero manual.
        XCTAssertEqual(p.listedClearanceFaces(g), [1])
        XCTAssertTrue(p.force.manualPrimitives(for: bore).isEmpty)

        // The move icon's action: materialise as manual + suppress the auto face.
        let newID = p.convertAutoClearanceToManual(face: 1, in: bore)
        XCTAssertNotNil(newID)

        // T5's bug: the panel listed the suppressed auto face AND the manual
        // primitive — two rows for one keep-out. The shared listing rule now
        // yields exactly ONE primitive total, matching the render and the run.
        XCTAssertEqual(p.listedClearanceFaces(g), [],
                       "the suppressed auto face no longer lists")
        XCTAssertEqual(p.force.manualPrimitives(for: bore).count, 1)
        XCTAssertEqual(p.clearanceSpecs().count, 1,
                       "the run carries exactly one keep-out — listing == run")
        XCTAssertEqual(p.clearanceVolumes().count, 1,
                       "the render draws exactly one volume — listing == picture")
    }

    // MARK: - L13 · transient notes

    @MainActor
    func testTransientNoteLifecycle() {
        let page = LatticePageModel()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(page.note)

        // Post; visible.
        page.post(note: "first", now: t0)
        XCTAssertEqual(page.note?.text, "first")

        // Rule 2: a DIFFERENT note replaces it.
        page.post(note: "second", now: t0.addingTimeInterval(5))
        XCTAssertEqual(page.note?.text, "second")

        // Rule 3: expires after 60 s — but not before.
        page.tick(now: t0.addingTimeInterval(5 + 59))
        XCTAssertEqual(page.note?.text, "second", "a note lives its full 60 s")
        page.tick(now: t0.addingTimeInterval(5 + 60))
        XCTAssertNil(page.note, "…and is gone at 60 s")

        // Rule 1: tap dismisses immediately.
        page.post(note: "third", now: t0)
        page.dismissNote()
        XCTAssertNil(page.note)
    }

    // MARK: - L14 · topology rows: one line, one footnote

    func testTopologyListShowsOneFootnoteNotPerRowBadges() throws {
        let src = try String(contentsOf: sourceURL("LatticePage.swift"), encoding: .utf8)
        // Exactly one footnote, and no per-row badge sentence in the pane.
        XCTAssertEqual(src.components(separatedBy: "* the geometry does not exist yet").count - 1, 1,
                       "ONE footnote carries the explanation")
        XCTAssertTrue(src.contains("lineLimit(1)"), "topology names render on one line")
        // The presentation still derives from CORE's split (B0 stands): the rows
        // and their generatable flags are LatticeTopologyPicker's, and a
        // certifiable-only topology exists today to exercise the asterisk.
        let rows = LatticeTopologyPicker.rowsFromCore()
        XCTAssertTrue(rows.contains { !$0.generatable },
                      "core still has certifiable-but-ungeneratable rows (else the footnote hides)")
        XCTAssertTrue(rows.contains { $0.generatable })
    }

    // MARK: - regions emission unit coverage

    func testRegionSpecMappingAndValidity() {
        // A bolt primitive maps 1:1 (the primitive IS the region, no margins).
        let bolt = ManualPrimitive.defaultBolt(at: SIMD3(1, 2, 3), radiusMM: 4, halfLengthMM: 10)
        let boltSpec = LatticeRegionEmission.spec(for: bolt, role: .exclude, depthMM: 5)
        XCTAssertEqual(boltSpec?.kind, .bolt)
        XCTAssertEqual(boltSpec?.axisPoint, SIMD3(1, 2, 3))
        XCTAssertEqual(boltSpec?.radiusMM, 4)
        XCTAssertEqual(boltSpec?.halfLengthMM, 10)

        // A face primitive carries the RESOLVED depth the caller passes.
        let slab = ManualPrimitive.defaultFace(at: SIMD3(0, 0, 5), halfMM: 6)
        let slabSpec = LatticeRegionEmission.spec(for: slab, role: .include, depthMM: 3.5)
        XCTAssertEqual(slabSpec?.kind, .face)
        XCTAssertEqual(slabSpec?.depthMM, 3.5)
        XCTAssertEqual(slabSpec?.normal, SIMD3(0, 0, 1), "a primitive's own normal is NOT flipped")

        // Degenerate entries are refused app-side (core would refuse them anyway).
        let zero = ManualPrimitive(kind: .bolt, center: .zero, axis: SIMD3(0, 0, 1),
                                   radiusMM: 0, halfLengthMM: 10)
        XCTAssertNil(LatticeRegionEmission.spec(for: zero, role: .include, depthMM: 5),
                     "a zero-extent region marks nothing — never emitted")

        // A resolved PART face flips the outward normal so the slab reaches into
        // the material.
        let planeSpec = LatticeRegionEmission.spec(
            for: .plane(center: SIMD3(0, 0, 10), normal: SIMD3(0, 0, 1),
                        halfUMM: 4, halfWMM: 4),
            role: .include, depthMM: 2)
        XCTAssertEqual(planeSpec?.normal, SIMD3(0, 0, -1))

        // A resolved cylinder face centres the bolt on its span.
        let cylSpec = LatticeRegionEmission.spec(
            for: .cylinder(axisPoint: .zero, axisDir: SIMD3(0, 0, 1),
                           radiusMM: 2.5, spanLoMM: 0, spanHiMM: 10),
            role: .exclude, depthMM: 2)
        XCTAssertEqual(cylSpec?.axisPoint, SIMD3(0, 0, 5))
        XCTAssertEqual(cylSpec?.halfLengthMM, 5)
    }

    @MainActor
    func testGroupRolesRoundTripAndLegacyDecode() throws {
        var settings = LatticeSettings()
        let gid = UUID()
        settings.groupRoles[gid] = .include
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertEqual(back.groupRoles[gid], .include)

        // A pre-round-2 snapshot (no groupRoles key) decodes with none.
        let legacy = try JSONDecoder().decode(LatticeSettings.self,
                                              from: Data(#"{"enabled": true}"#.utf8))
        XCTAssertTrue(legacy.groupRoles.isEmpty)
        XCTAssertTrue(legacy.enabled)
    }

    // MARK: - shared job helpers (the LatticePageTests shapes)

    private static func request(lattice: LatticeSpec?) -> RunRequest {
        RunRequest(
            modelPath: "/tmp/part.stl", material: "PLA", materialsPath: "", rulesPath: "",
            resolution: 96, projectName: "lattice-round2", anchorFaceIDs: [3],
            loadGroups: [.init(faceIDs: [5], force: SIMD3(0, 0, -100))],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40,
            lattice: lattice)
    }

    private static func jobDict(request: RunRequest) throws -> [String: Any] {
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: request,
                            progress: { _, _, _ in true }, onVariant: { _ in })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
    }
}
