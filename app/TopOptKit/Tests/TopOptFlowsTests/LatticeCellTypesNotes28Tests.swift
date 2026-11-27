// LatticeCellTypesNotes28Tests — ★ notes28, builder E (the maintainer's decision 2026-11-24): ALL the strut cell types on the
// NEW lattice engine, app side. Seven Structural and Aesthetic (octet, sc, bcc, fcc, diamond, kelvin, rhombic) and three
// Aesthetic only (bccz, fccz, reentrant); the sheets stay as they were. Each check has its RED control.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeCellTypesNotes28Tests: XCTestCase {

    static let structuralAndAesthetic = ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"]
    static let aestheticOnly = ["bccz", "fccz", "reentrant"]
    /// ★ TRIPWIRE (core's own `structural_note`, builder D's types.cpp, through the bridge): on the linked core (D's,
    /// merged f82ac0b8) the measured strength laws of these credit the engine's struts; SC's and BCC's start past the open
    /// look (builder F re-measures them). When F's laws land the live check fails BY NAME: move them across.
    /// ★ RE-PINNED (362, release (20), 2026-11-25): builder F's laws landed (932b0310: BCC, Diamond and SC measured down
    /// to two-line struts), so the tripwire fired by name as planned: SC and BCC are strength-checked now.
    static let structuralChecked = ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"]
    static let strengthNotCoveredToday: [String] = []
    static var all: [String] { structuralAndAesthetic + aestheticOnly }
    /// ★ TRIPWIRE: the strut types the linked engine does not lay. Empty since builder D's core (f82ac0b8): the tetragonal
    /// three have their cells and width limits. A type listed here is checked to be refused, by name.
    static let engineWaits: Set<String> = []

    static var cube: String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core/tests/fixtures/step/cube.step").path
    }

    private func src(_ f: String) throws -> String {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        return try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
    }

    // MARK: 1 · every type lays on core's 10 mm cube, through the app's own session

    func testEveryStrutTypeLaysOnTheCubeThroughTheSession() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        var laid: [String: [Float]] = [:]
        for id in Self.all {
            var s = LatticeLayoutSession.Settings()
            s.allLattice = true
            s.topology = id
            s.cellMM = 5
            if Self.engineWaits.contains(id) {
                XCTAssertFalse(LatticeLayoutSession.lays(id), "★ TRIPWIRE: the engine lays \(id) now — take it off engineWaits")
                XCTAssertFalse(LatticeLayoutSession.typeFacts(id).why.isEmpty, "\(id): the engine says why")
                do { _ = try await session.lay(s); XCTFail("\(id): the engine lays it — take it off engineWaits") } catch {}
                continue
            }
            XCTAssertTrue(LatticeLayoutSession.lays(id), "★ \(id): the engine says it lays it")
            let r = try await session.lay(s)
            print("NOTES28 lay \(id): \(r.barCount) bars, open look \(r.openLook), touch \(r.touch)")
            XCTAssertGreaterThan(r.barCount, 0, "★ \(id) lays a lattice in the cube")
            XCTAssertEqual(r.touch, LatticeLayoutSession.typeFacts(id).touch, accuracy: 1e-12, "\(id): the type's own limit")
            laid[id] = r.bars
        }
        // RED CONTROL: a type that fell back to octet would lay octet's bars — every laid type's bars are its own
        let ids = laid.keys.sorted()
        for (i, a) in ids.enumerated() { for b in ids[(i + 1)...] {
            XCTAssertNotEqual(laid[a], laid[b], "★ \(a) and \(b) lay different struts")
        } }
        // RED CONTROL: a sheet type is never laid by the strut engine — ★ RE-PINNED (notes28 sheets, builder C): the engine
        // lays a sheet now, as a sheet (core's family "sheet", no strut cell: LatticeSheetsAppTests)
        XCTAssertTrue(LatticeLayoutSession.typeFacts("gyroid").isSheet)
        XCTAssertEqual(LatticeLayoutSession.typeFacts("gyroid").s, 0, "no strut cell")
        XCTAssertFalse(LatticeLayoutSession.lays("lattice9"))
    }

    // MARK: 2 · the gate, Structural and Aesthetic

    func testTheGateIsOpenForEveryStrutTypeAndNotTheSheets() {
        // ★ RE-PINNED (notes28 sheets, builder C): the sheets joined the gate on the new engine (LatticeSheetsAppTests)
        XCTAssertEqual(LatticeTypeCatalog.appBatches, Set(Self.all + ["gyroid", "schwarz_d"]))
        let aesthetic = LatticeTypeCatalog.layoutEntriesFromCore(structural: false)
        let laidToday = LatticeTypeCatalog.order.filter {
            (Self.all + ["gyroid", "schwarz_d"]).contains($0) && !Self.engineWaits.contains($0)
        }
        XCTAssertEqual(aesthetic.filter(\.offered).map(\.id), laidToday, "★ Aesthetic: every type the engine lays")
        // RED CONTROL: behind a closed gate nothing new is offered
        LatticeTypeCatalog.appBatchesForTests = ["octet"]
        defer { LatticeTypeCatalog.appBatchesForTests = nil }
        XCTAssertEqual(LatticeTypeCatalog.layoutEntriesFromCore(structural: false).filter(\.offered).map(\.id), ["octet"])
    }

    func testStructuralRefusesTheThreeAestheticOnlyTypes() {
        let cert = TopOptKit.latticeCertifiableTopologies
        // core's own verdicts, through the bridge (builder D's types.cpp): the tetragonal three refused, in core's line
        for id in Self.aestheticOnly {
            let r = LatticeTypeCatalog.structuralRefusal(id)
            XCTAssertNotNil(r, "★ core refuses \(id) for Structural")
            XCTAssertTrue(r?.contains("strength cannot be checked") == true, r ?? "")
        }
        for id in Self.structuralAndAesthetic { XCTAssertNil(LatticeTypeCatalog.structuralRefusal(id), "RED CONTROL: \(id)") }
        // the pure form, driven with core's verdicts
        let structural = LatticeTypeCatalog.layoutEntries(structural: true, certifiable: cert, engineLays: { _ in true },
                                                          structuralRefusal: LatticeTypeCatalog.structuralRefusal)
        let aesthetic = LatticeTypeCatalog.layoutEntries(structural: false, certifiable: cert, engineLays: { _ in true },
                                                         structuralRefusal: LatticeTypeCatalog.structuralRefusal)
        for id in Self.aestheticOnly {
            let s = structural.first { $0.id == id }!, a = aesthetic.first { $0.id == id }!
            XCTAssertFalse(s.offered, "★ \(id): not choosable on Structural")
            XCTAssertEqual(s.reason, LatticeTypeCatalog.structuralRefusal(id), "★ core's own line is its (i)")
            XCTAssertEqual(LatticeTypeCatalog.caption(s), "Aesthetic only")
            XCTAssertTrue(a.offered, "RED CONTROL: \(id) is choosable on Aesthetic")
        }
        for id in Self.structuralAndAesthetic {
            XCTAssertTrue(structural.first { $0.id == id }!.offered, "\(id): no refusal, no note: Structural")
        }
        // ★ his answer 11-24: Structural takes a type only while its MEASURED law credits the engine's struts — core's
        // structural_note, never a list. Driven with explicit facts: SC noted, it is refused on Structural in core's line;
        // its note cleared, it opens by itself
        let note = "This lattice type's strength is measured only for denser struts than it lays."
        let notSC = LatticeTypeCatalog.layoutEntries(structural: true, certifiable: cert, engineLays: { _ in true },
                                                     structuralNote: { $0 == "sc" ? note : nil })
        let sc = notSC.first { $0.id == "sc" }!
        XCTAssertFalse(sc.offered, "★ SC: its law starts past the engine's struts")
        XCTAssertEqual(sc.reason, note)
        XCTAssertEqual(LatticeTypeCatalog.caption(sc), "Strength measured for denser struts")
        XCTAssertEqual(LatticeTypeCatalog.line(sc), "Simple cubic: \(note)")
        XCTAssertTrue(LatticeTypeCatalog.layoutEntries(structural: false, certifiable: cert, engineLays: { _ in true },
                                                       structuralNote: { $0 == "sc" ? note : nil }).first { $0.id == "sc" }!.offered,
                      "RED CONTROL: SC is choosable on Aesthetic")
        XCTAssertTrue(notSC.first { $0.id == "kelvin" }!.offered, "RED CONTROL: a law that credits is choosable on Structural")
        // the linked core, read live: TRIPWIRE — today SC's and BCC's measured laws credit none of the engine's struts; when
        // builder F's re-measured laws land, this fails BY NAME and they open on Structural by themselves
        for id in Self.structuralAndAesthetic {
            let n = LatticeTypeCatalog.structuralNote(id)
            print("NOTES28 core's structural note: \(id) \(n ?? "-")")
            XCTAssertEqual(n == nil, Self.structuralChecked.contains(id),
                           "★ TRIPWIRE \(id): core's note moved — update structuralChecked / strengthNotCoveredToday")
        }
        let liveStructural = LatticeTypeCatalog.layoutEntriesFromCore(structural: true).filter(\.offered).map(\.id)
        // ★ RE-PINNED (notes28 sheets, builder C): the two sheets too — core certifies both, with no refusal and no note
        // (their Structural floor is core's cells across a member: LatticeSheetsAppTests)
        // ★ RE-PINNED (notes30 M1, the reviewer's ruling 11-26 item 3(b)): the sheets are Aesthetic only until their measured
        // laws land (LatticeTypeCatalog.sheetStructuralCaption; Notes30SheetsIntegrateTests)
        XCTAssertEqual(liveStructural, LatticeTypeCatalog.order.filter { Self.structuralChecked.contains($0) },
                       "★ Structural, strength-checked: core says no refusal and no note")
        for id in Self.strengthNotCoveredToday {
            let e = LatticeTypeCatalog.layoutEntriesFromCore(structural: true).first { $0.id == id }!
            XCTAssertEqual(LatticeTypeCatalog.caption(e), "Strength measured for denser struts", id)
            XCTAssertEqual(e.reason, LatticeTypeCatalog.structuralNote(id), "\(id): core's own line")
            XCTAssertTrue(cert.contains(id), "(core certifies \(id): its law's range, not core's list, holds it back)")
        }
        // his rule: every caption at most five words
        for e in structural + aesthetic + LatticeTypeCatalog.layoutEntriesFromCore(structural: true) {
            if let c = LatticeTypeCatalog.caption(e) {
                XCTAssertLessThanOrEqual(c.split(separator: " ").count, 5, "★ at most five words: \(c)")
            }
        }
        XCTAssertLessThanOrEqual(LatticeTypeChange.caption.split(separator: " ").count, 5)
        // the saved type: Structural refuses it in the picker's own words, Aesthetic does not
        let live = LatticeTypeCatalog.layoutEntriesFromCore(structural: true)
        for id in Self.aestheticOnly { XCTAssertFalse(live.first { $0.id == id }!.offered, "★ \(id) on Structural (live)") }
        XCTAssertNil(LatticeTypeCatalog.layoutRefusal("kelvin", structural: true), "RED CONTROL: Kelvin runs on Structural")
        XCTAssertNotNil(LatticeTypeCatalog.layoutRefusal("reentrant", structural: true))
        XCTAssertNil(LatticeTypeCatalog.layoutRefusal("reentrant", structural: false), "★ Re-entrant runs on Aesthetic")
    }

    // MARK: 3 · every type has its OWN strut law; the dial's numbers differ per type

    func testEveryTypeHasItsOwnStrutLawAndNeverTheOctets() throws {
        for id in Self.all {
            let t = try XCTUnwrap(LatticeType.named(id), "★ \(id) has a strut law")
            XCTAssertEqual(t.id, id, "never octet in disguise")
        }
        for id in ["gyroid", "schwarz_d", "lattice9", ""] { XCTAssertNil(LatticeType.named(id), "RED CONTROL: \(id) has none") }
        // Kelvin, Rhombic and Re-entrant: the ENGINE'S OWN cell (core's lattice_strut_cell); Kelvin and Rhombic with core's
        // measured law first
        for id in ["kelvin", "rhombic", "reentrant"] {
            let t = try XCTUnwrap(LatticeType.named(id)), f = LatticeLayoutSession.typeFacts(id)
            XCTAssertEqual(t.denominator, f.s)
            XCTAssertEqual(t.struts.count, f.struts.count, "\(id): the engine's struts")
        }
        for id in ["kelvin", "rhombic"] {
            XCTAssertGreaterThan(TopOptKit.latticeStrutDiameterMM(topology: id, relativeDensity: 0.2, cellMM: 4), 0,
                                 "\(id): core's measured law")
        }
        // the Swift table is the engine's cell for every type core has one for (faithfulness), and K follows one rule
        for t in LatticeType.family where LatticeLayoutSession.lays(t.id) {
            let f = LatticeLayoutSession.typeFacts(t.id)
            func n(_ p: SIMD3<Int32>) -> LatticeType.Node { .init(Int(p.x), Int(p.y), Int(p.z)) }
            XCTAssertEqual(Set(t.struts), Set(f.struts.map { LatticeType.Strut(n($0.0), n($0.1)) }), "\(t.id): the engine's cell")
            let k = 2 * 2.0.squareRoot() * t.canonicalStrutLengthMM(cellMM: 1)
            XCTAssertEqual(k, t.densityCoefficient, accuracy: 1e-3, "\(t.id): K = 2√2 · strut length per cell")
        }
    }

    func testTheDialsNumbersDifferPerType() throws {
        let cell = 8.0, bead = 0.45, rho = 0.2
        let laws = Self.all.filter { LatticeType.named($0) != nil }
        XCTAssertEqual(laws.count, 10, "every strut type (Re-entrant: the engine's own cell, since builder D)")
        var seen: [String: (pct: Double, d: Double, band: Double)] = [:]
        for id in laws {
            let lat = try XCTUnwrap(LatticeType.named(id))
            let pct = try XCTUnwrap(ProjectModel.latticeDensityPercent(rho: rho, cellMM: cell, topology: id, lineWidthMM: bead), id)
            let band = try XCTUnwrap(ProjectModel.latticeDensityBandDiametersMM(topology: id, lineWidthMM: bead, cellMM: cell))
            let d = 2 * lat.strutRadiusMM(relativeDensity: rho, cellMM: cell)
            XCTAssertGreaterThan(lat.printabilityDensityFloor(lineWidthMM: bead, cellMM: cell), 0, "\(id): a printability floor")
            // the percent's inverse is the type's own: the number he types is the strut he gets
            let back = try XCTUnwrap(ProjectModel.latticeDensityForPercent(pct, cellMM: cell, topology: id, lineWidthMM: bead))
            XCTAssertEqual(back, rho, accuracy: 2e-3, "\(id): the dial's inverse")
            seen[id] = (pct, d, band.hi)
            print("NOTES28 dial \(id): rho \(rho) → \(String(format: "%.1f", pct)) %, strut \(String(format: "%.3f", d)) mm, top \(String(format: "%.2f", band.hi)) mm")
        }
        // RED CONTROL: the octet's law under another name gives the octet's numbers — no type here does
        let octet = try XCTUnwrap(seen["octet"])
        for id in laws where id != "octet" {
            let s = try XCTUnwrap(seen[id])
            XCTAssertNotEqual(s.d, octet.d, accuracy: 1e-6, "★ \(id)'s strut is its own, not the octet's")
        }
        for (i, a) in laws.enumerated() { for b in laws[(i + 1)...] {
            let x = seen[a]!, y = seen[b]!
            XCTAssertFalse(abs(x.pct - y.pct) < 1e-6 && abs(x.d - y.d) < 1e-6, "★ \(a) and \(b) read the dial differently")
        } }
    }

    // MARK: 4 · changing type says what changes; nothing keeps the old type's numbers

    func testATypeChangeKeepsTheDialAndSaysWhatChanges() throws {
        var l = LatticeSettings(enabled: true, topologyID: "octet")
        l.maxRelativeDensity = 0.30; l.minRelativeDensity = 0.12
        let g = UUID()
        l.groupDensities = [g: 0.25]
        l.selectableDensity = ["f7": 0.18]
        l.manualStrutThicknessMM = 1.2
        let bead = 0.45, cell = LatticeTypeChange.referenceCellMM(l)
        func pct(_ rho: Double, _ id: String) -> Double {
            ProjectModel.latticeDensityPercent(rho: rho, cellMM: cell, topology: id, lineWidthMM: bead) ?? -1
        }
        for id in Self.all where id != "octet" && LatticeType.named(id) != nil {
            let c = LatticeTypeChange.applied(l, to: id, lineWidthMM: bead)
            XCTAssertEqual(c.topologyID, id)
            for (old, new) in [(l.maxRelativeDensity, c.maxRelativeDensity), (l.minRelativeDensity, c.minRelativeDensity),
                               (l.groupDensities[g]!, c.groupDensities[g]!), (l.selectableDensity["f7"]!, c.selectableDensity["f7"]!)] {
                XCTAssertEqual(pct(new, id), pct(old, "octet"), accuracy: 0.6, "★ \(id): the same place on the dial")
            }
            XCTAssertEqual(c.manualStrutThicknessMM, 1.2, "a typed width stays as typed")
            // RED CONTROL: written as a plain number, the octet's density reads elsewhere on the new type's dial
            XCTAssertGreaterThan(abs(pct(l.maxRelativeDensity, id) - pct(l.maxRelativeDensity, "octet")), 1,
                                 "\(id): the octet's number would move the dial")
            let lines = LatticeTypeChange.lines(l, to: id, lineWidthMM: bead)
            let name = LatticeType.displayName(forID: id)
            XCTAssertTrue(lines.first?.contains(name) == true && lines.first?.contains("Octet truss") == true, lines.joined())
            XCTAssertTrue(lines.contains { $0.contains("1.20 mm") }, "★ the typed width is named")
            if Self.aestheticOnly.contains(id) {
                XCTAssertTrue(lines.contains { $0.contains("Aesthetic only") }, id)
            }
        }
        XCTAssertEqual(LatticeTypeChange.lines(l, to: "octet", lineWidthMM: bead), [], "RED CONTROL: no change, nothing said")
        XCTAssertEqual(LatticeTypeChange.applied(l, to: "octet", lineWidthMM: bead), l)
        // the page's model carries its two the same way
        var m = LatticeWizardModel(settings: l)
        m.setTopology("sc", lineWidthMM: bead)
        XCTAssertEqual(m.topologyID, "sc")
        XCTAssertEqual(pct(m.relativeDensity, "sc"), pct(l.maxRelativeDensity, "octet"), accuracy: 0.6)
        // and the page says it before Save, on a part that already has a lattice; Save carries the rest
        let wiz = try src("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains("captionLine(LatticeTypeChange.caption, info: \"type-change\""))
        XCTAssertTrue(wiz.contains("LatticeTypeChange.applied(project.lattice, to: model.topologyID,"))
        XCTAssertTrue(try src("LatticePage.swift").contains("project.lattice = LatticeTypeChange.applied(project.lattice, to: e.id,"))
    }

    // MARK: 5 · the job, the version lines, the details

    @MainActor
    func testThePrintFileJobSendsTheType() throws {
        for id in Self.all {
            var l = LatticeSettings(enabled: true, topologyID: id)
            l.stageMode = .aesthetic
            let s = LatticeLayoutPreview.partWide(l, beadMM: 0.45, wallRingMM: 0.9, referenceMPa: 0) { _, _ in nil }
            XCTAssertEqual(s.topology, id)
            let json = try LatticeFileJob.build(s, modelName: "part.step")
            let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            let text = String(decoding: json, as: UTF8.self)
            XCTAssertTrue(text.contains("\"topology\":\"\(id)\"") || text.contains("\"topology\" : \"\(id)\""), "★ \(id) rides the job: \(o.keys.sorted())")
        }
        // RED CONTROL: no type at all goes as the octet, the default
        let s = LatticeLayoutPreview.partWide(LatticeSettings(enabled: true, topologyID: ""), beadMM: 0.45, wallRingMM: 0,
                                              referenceMPa: 0) { _, _ in nil }
        XCTAssertEqual(s.topology, "octet")
    }

    func testTheVersionLinesAndDetailsNameTheType() {
        let a = LatticeSettings(enabled: true, topologyID: "octet")
        for id in Self.all where id != "octet" {
            let b = LatticeSettings(enabled: true, topologyID: id)
            let lines = VersionChanges.latticeLines(a, b, groupsA: [], groupsB: []).map(\.text)
            XCTAssertTrue(lines.contains("Cell type Octet truss → \(LatticeType.displayName(forID: id))"), "\(id): \(lines)")
            var snap = ProjectSnapshot(id: UUID(), name: "p", material: "PA12", process: .fdm, modelFileName: "m.step",
                                       originalFileName: "m.step", savedAt: Date(), selection: SelectionModel(), force: ForceModel())
            snap.lattice = b
            let rows = LibraryVersionFacts.settings(snap)
            XCTAssertEqual(rows.first { $0.0 == "Cell type" }?.1, LatticeType.displayName(forID: id), "★ Details name it")
        }
        XCTAssertTrue(VersionChanges.latticeLines(a, a, groupsA: [], groupsB: []).allSatisfy { !$0.text.hasPrefix("Cell type") },
                      "RED CONTROL: the same type says nothing")
        var topo = ProjectSnapshot(id: UUID(), name: "p", material: "PA12", process: .fdm, modelFileName: "m.step",
                                   originalFileName: "m.step", savedAt: Date(), selection: SelectionModel(), force: ForceModel())
        topo.lattice = nil
        XCTAssertNil(LibraryVersionFacts.settings(topo).first { $0.0 == "Cell type" }, "RED CONTROL: no lattice, no cell type")
    }

    // MARK: 6 · the card pictures are the engine's own samples

    func testTheCardPicturesAreTheEnginesOwnSamples() async throws {
        var made: [String: LatticeTypePicture] = [:]
        for id in Self.all {
            if Self.engineWaits.contains(id) {
                do { _ = try await LatticeTypePicture.make(id); XCTFail("\(id): the engine lays it — take it off engineWaits") }
                catch {}
                continue
            }
            let p = try await LatticeTypePicture.make(id)
            XCTAssertGreaterThan(p.lines.count, 8, "★ \(id): the engine's sample, drawn")
            for l in p.lines {
                for v in [l.a.x, l.a.y, l.b.x, l.b.y] { XCTAssertTrue(v >= -1e-4 && v <= 1 + 1e-4, "\(id): inside the card") }
            }
            made[id] = p
        }
        let ids = made.keys.sorted()
        for (i, a) in ids.enumerated() { for b in ids[(i + 1)...] {
            XCTAssertNotEqual(made[a], made[b], "★ \(a) and \(b) look different")
        } }
        // RED CONTROL: nothing laid, nothing drawn
        XCTAssertEqual(LatticeTypePicture.picture(bars: [], topology: "octet").lines, [])
        // the cards draw it (never hand art) and the greyed ones say why
        let wiz = try src("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains("LatticeTypePictureView(id: e.id, greyed: !e.offered)"))
        // ★ RE-PINNED (notes29, his 11-25: the one (i) app-wide, always a 44 pt target — AppInfoButton): titled by the type
        XCTAssertTrue(wiz.contains("if !e.offered, let why = e.reason { infoButton(\"type-\\(e.id)\", why, title: e.displayName) }"))
    }

    // MARK: 6b · the live sample lays and names each type by its own law

    func testTheLiveSampleLaysEachTypeByItsOwnLaw() async throws {
        for id in Self.structuralAndAesthetic {
            let plan = LatticeSampleLay.plain(topology: id, cellMM: 10, lineWidthMM: 0.45, rho: 0.2)
            XCTAssertEqual(plan.settings.topology, id)
            let made = try await LatticeSampleLay.lay(plan, cube: true)
            XCTAssertGreaterThan(made.struts, 0, "\(id): the sample lays")
            XCTAssertGreaterThan(made.rhoHi, 0, "★ \(id): its densities read by its own law")
            let name = LatticeType.displayName(forID: id)
            let caption = LatticeSampleLay.caption(made, typeName: name, cube: true, finish: nil, band: false)
            XCTAssertTrue(caption.contains(name), caption)
            if id != "octet" { XCTAssertFalse(caption.contains("Octet"), "★ never the octet's name: \(caption)") }
        }
        // RED CONTROL: the dial the plain sample sends is the type's own percent, so it differs from the octet's
        let o = LatticeSampleLay.plain(topology: "octet", cellMM: 10, lineWidthMM: 0.45, rho: 0.2).settings.dial
        let k = LatticeSampleLay.plain(topology: "kelvin", cellMM: 10, lineWidthMM: 0.45, rho: 0.2).settings.dial
        XCTAssertNotEqual(o, k, accuracy: 1e-6, "★ Kelvin's dial is read on Kelvin's law (it once fell back to 0.45)")
        XCTAssertNotEqual(k, LatticeLayoutSession.Settings().dial, accuracy: 1e-6)
    }

    // MARK: 6c · Structural's cells across a wall is the type's own floor

    func testStructuralCellsAcrossAWallIsTheTypesOwn() {
        for id in Self.structuralAndAesthetic {
            var l = LatticeSettings(enabled: true, topologyID: id)
            l.stageMode = .structural
            let core = TopOptKit.latticeLimits(topology: id).minCellsPerMember
            XCTAssertEqual(Double(LatticeLayoutPreview.minCellsAcross(l)), core.rounded(.up), "★ \(id): core's own floor")
            l.stageMode = .aesthetic
            XCTAssertEqual(LatticeLayoutPreview.minCellsAcross(l), 2, "\(id): Aesthetic's rule is the same for every type")
        }
        var k = LatticeSettings(enabled: true, topologyID: "kelvin"); k.stageMode = .structural
        XCTAssertNotEqual(LatticeLayoutPreview.minCellsAcross(k), 5, "RED CONTROL: never the octet's five under Kelvin's name")
        var o = LatticeSettings(enabled: true, topologyID: "octet"); o.stageMode = .structural
        XCTAssertEqual(LatticeLayoutPreview.minCellsAcross(o), 5, "the octet's own five is unchanged")
    }

    // MARK: 6d · "Not print-tested" (362's ruling 11-24, his rule): per type, the app's, octet and BCC + Z start tested

    @MainActor
    func testNotPrintTestedIsTheAppsPerTypeAndClearsWhenMarked() throws {
        let suite = "notes28.printTested.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let a = AppSettings(defaults: d)
        XCTAssertEqual(a.latticePrintTested, ["octet", "bccz"], "★ octet and BCC + Z start tested")
        for id in Self.all {
            XCTAssertEqual(LatticeTypeCatalog.showsNotPrintTested(id, tested: a.latticePrintTested), !["octet", "bccz"].contains(id),
                           "★ \(id): the tag until he marks it")
        }
        // ★ RE-PINNED (notes28 sheets, builder C): the sheets are on the new engine's page, untested until he marks them
        XCTAssertTrue(LatticeTypeCatalog.showsNotPrintTested("gyroid", tested: []))
        XCTAssertEqual(LatticeTypeCatalog.notPrintTestedCaption.split(separator: " ").count, 2, "★ at most five words")
        XCTAssertTrue(LatticeTypeCatalog.notPrintTestedInfo("Kelvin").contains("sample coupon"), "★ the (i) says how it goes")
        // he marks Kelvin: it is the app's, so a fresh read of the same device has it (every project)
        a.markPrintTested("kelvin")
        XCTAssertFalse(LatticeTypeCatalog.showsNotPrintTested("kelvin", tested: a.latticePrintTested))
        XCTAssertTrue(AppSettings(defaults: d).latticePrintTested.contains("kelvin"), "★ kept on this device")
        XCTAssertTrue(AppSettings.isPrintTested("kelvin", d))
        // RED CONTROL: another device (fresh defaults) has not seen his mark
        let other = try XCTUnwrap(UserDefaults(suiteName: suite + ".other"))
        defer { other.removePersistentDomain(forName: suite + ".other") }
        XCTAssertFalse(AppSettings.isPrintTested("kelvin", other))
        // the tag is under every card, its tap the centred pop-up with the one action
        let tag = try src("LatticePrintTested.swift"), wiz = try src("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains("LatticePrintTestedTag(id: e.id, name: e.displayName)"))
        // ★ RE-PINNED (notes29, his 11-25: an (i)'s notification says "Tap anywhere to continue", not OK): `help`, its one
        // action kept
        XCTAssertTrue(tag.contains("AppPopups.shared.help(LatticeTypeCatalog.notPrintTestedCaption")
                      && tag.contains("AppSettings.shared.markPrintTested(id)"))
    }

    // MARK: 6e · "Cannot Lattice" when the print check empties a region (builder D, organic-1 5bdca042)

    @MainActor
    func testAPrintFileThatEmptiedARegionSaysCannotLatticeInItsName() throws {
        let report = Data(#"{"ok": true, "layout": {"cells": 12, "bars": 40, "cannot_lattice": [{"region": 2, "struts": 96, "left_out": 94, "why": "Every strut there would start in mid-air."}]}}"#.utf8)
        let e = LatticeCannotLattice.emptied(report: report)
        XCTAssertEqual(e, [.init(region: 2, struts: 96, leftOut: 94, why: "Every strut there would start in mid-air.")])
        let text = try XCTUnwrap(LatticeCannotLattice.popUpText(e, name: { $0 == 2 ? "Front wall" : "?" }))
        XCTAssertEqual(text, "Front wall: Every strut there would start in mid-air.", "★ his name for it, core's line")
        XCTAssertFalse(text.contains("2"), "★ never a region number")
        XCTAssertEqual(LatticeCannotLattice.title, "Cannot Lattice")
        // RED CONTROL: a result with nothing emptied (the key absent, as core writes it) says nothing
        XCTAssertNil(LatticeCannotLattice.popUpText(LatticeCannotLattice.emptied(report: Data(#"{"ok": true, "layout": {"bars": 40}}"#.utf8)),
                                                     name: { _ in "x" }))
        XCTAssertEqual(LatticeCannotLattice.emptied(report: nil), [])
        // a region his way: the whole part, or a group's name; one the project no longer has is never its number
        let p = ProjectModel(id: UUID(), name: "p", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        XCTAssertEqual(LatticeCannotLattice.regionName(0, in: p), "The part")
        XCTAssertEqual(LatticeCannotLattice.regionName(7, in: p), "A lattice area")
        // it is said in the centred pop-up when a print file lands
        let ws = try src("WorkspacePlaceholder.swift")
        // ★ RE-PINNED (notes28 sheets, builder C): else a blend that fell back to the solid wall is said in the same pop-up
        XCTAssertTrue(ws.contains("if ph == .succeeded, run.outcomeIsPrintFile, !LatticeCannotLattice.sayEmptied(report: run.outcome?.reportJSON, in: project) {"))
        XCTAssertTrue(ws.contains("LatticeSheets.sayFellBack(report: run.outcome?.reportJSON, in: project)"))
        XCTAssertTrue(try src("LatticeCannotLattice.swift").contains("AppPopups.shared.show(title, text)"))
    }

    // MARK: 7 · the octet-only controls: Allow quilt is every type's, with its own numbers

    func testAllowQuiltSaysEachTypesOwnNumbers() {
        let octet = LatticeSetupWizard.quiltInfo("octet")
        XCTAssertTrue(octet.contains("35 %") && octet.contains("19 %"), octet)
        for id in Self.structuralAndAesthetic where id != "octet" {
            let t = LatticeSetupWizard.quiltInfo(id)
            XCTAssertTrue(t.hasPrefix(LatticeType.displayName(forID: id)), t)
            XCTAssertFalse(t.contains("Octet"), "★ never the octet's words under \(id)")
        }
        XCTAssertNotEqual(LatticeSetupWizard.quiltInfo("sc"), octet.replacingOccurrences(of: "Octet truss", with: "Simple cubic"),
                          "RED CONTROL: sc's touch is its own (100 %), not the octet's 35 %")
        XCTAssertEqual(LatticeDensityProxy.realTriangles(latticeID: "kelvin", cellMM: 8, volumeMM3: 1000), 0,
                       "★ no measured count: never the octet's")
        XCTAssertGreaterThan(LatticeDensityProxy.realTriangles(latticeID: "octet", cellMM: 8, volumeMM3: 1000), 0)
    }
}

#if canImport(AppKit) && canImport(MetalKit)
import SwiftUI

/// ★ notes28 on the page itself (hosted: the ids come from `latticeID`'s probe, LatticeProbeKey — a test process builds no
/// SwiftUI accessibility tree, FlexibleSaid): on Structural every Structural type is a card, the Aesthetic-only three are
/// cards too, greyed with their caption and (i), and a tap on one says why and picks nothing.
@MainActor
final class LatticeCellTypesNotes28HostedTests: XCTestCase {

    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() {
        FlexibleSaid.recording = false
        LatticeTypeCatalog.appBatchesForTests = nil   // ★ 362: the stand-in newLattice opens (his A1 pad is an old-run part)
        super.tearDown()
    }

    final class Probe { var all: [String: CGRect] = [:] }
    private var probe = Probe()

    private func ids(_ h: AppBuildHost) -> [String: CGRect] { probe.all.merging(h.frames.all) { a, _ in a } }
    private func click(_ h: AppBuildHost, _ id: String) {
        if let f = ids(h)[id], f.width > 1 { h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.6) }
    }

    private func newLattice(_ mode: LatticeStageMode) throws -> AppBuildHost {
        // ★ 362 (his 11-25 "Sure": the old run keeps the octet only): this fixture is his A1 pad, a part the OLD run makes
        // (no STEP), where only the octet is offered now (Notes28OldRunTypesTests pins that). The cards' behaviour per type
        // is what this class checks, so the test stand-in opens every gate as on a STEP part.
        if LatticeTypeCatalog.appBatchesForTests == nil { LatticeTypeCatalog.appBatchesForTests = LatticeTypeCatalog.appBatches }
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(mode)
        p.lattice.enabled = false
        let pr = Probe(); probe = pr
        let v = LatticeSetupWizard(project: p, onExit: {}).cellsPage(regions: ["Group 1"], closeToken: 0)
            .onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 }
        let h = AppBuildHost(v, size: AppBuildHost.landscape13, test: self)
        h.pump(1.2)
        click(h, "lattice-page-tab-part")
        return h
    }

    func testStructuralShowsEveryTypeAndGreysTheAestheticOnlyThree() throws {
        let h = try newLattice(.structural)
        let seen = Set(ids(h).keys)
        for id in LatticeCellTypesNotes28Tests.all {
            XCTAssertTrue(seen.contains("wizard-type-\(id)"), "★ a card for \(id): \(seen.filter { $0.hasPrefix("wizard-type") }.sorted())")
        }
        for id in LatticeCellTypesNotes28Tests.aestheticOnly + LatticeCellTypesNotes28Tests.strengthNotCoveredToday {
            XCTAssertTrue(seen.contains("wizard-type-caption-\(id)"), "★ \(id): its caption")
            XCTAssertTrue(seen.contains("wizard-info-type-\(id)"), "★ \(id): its (i)")
            if let f = ids(h)["wizard-info-type-\(id)"] {
                XCTAssertGreaterThanOrEqual(Swift.min(f.width, f.height), 43.5, "★ his 44 pt target: \(f)")
            }
        }
        for id in LatticeCellTypesNotes28Tests.structuralChecked {
            XCTAssertFalse(seen.contains("wizard-type-caption-\(id)"), "RED CONTROL: \(id) can be picked, no caption")
        }
        // ★ 362's ruling 11-24 (his rule "NOT PRINT-TESTED"): the tag under every card but the ones he has marked tested
        let tested = AppSettings.shared.latticePrintTested
        for id in LatticeCellTypesNotes28Tests.all {
            XCTAssertEqual(seen.contains("wizard-type-untested-\(id)"), !tested.contains(id), "★ \(id): the print-tested tag")
            if let f = ids(h)["wizard-type-untested-\(id)"] {
                XCTAssertGreaterThanOrEqual(f.height, 43.5, "★ his 44 pt target: \(f)")
            }
        }
        XCTAssertFalse(seen.contains("wizard-type-untested-octet"), "RED CONTROL: the octet starts tested")
        XCTAssertTrue(seen.contains("wizard-type-pick-note"), "nothing pre-picked on a new lattice")
        // a greyed card says why and picks nothing; an offered one is picked
        click(h, "wizard-type-reentrant")
        XCTAssertNotNil(ids(h)["wizard-type-reason"], "★ the tap says why")
        XCTAssertNotNil(ids(h)["wizard-type-pick-note"], "★ and picks nothing")
        click(h, "wizard-type-kelvin")
        XCTAssertNil(ids(h)["wizard-type-pick-note"], "Kelvin is picked")
        XCTAssertNil(ids(h)["wizard-type-reason"], "the pick answers it")
    }

    func testAClosedGateHidesTheAestheticOnlyCards() throws {
        LatticeTypeCatalog.appBatchesForTests = ["octet", "kelvin"]   // RED CONTROL: their batch not shipped
        defer { LatticeTypeCatalog.appBatchesForTests = nil }
        let h = try newLattice(.structural)
        let seen = Set(ids(h).keys)
        XCTAssertTrue(seen.contains("wizard-type-octet") && seen.contains("wizard-type-kelvin"))
        for id in LatticeCellTypesNotes28Tests.aestheticOnly + ["sc", "rhombic"] {
            XCTAssertFalse(seen.contains("wizard-type-\(id)"), "\(id): hidden behind its batch")
        }
    }
}
#endif
