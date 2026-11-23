// MacPrintAccurate1123Tests — ★ his 11-22: the print-accurate lattice made on the Mac and drawn on the iPad (LatticeMacMake,
// LatticeFileMesh, LatticeFileRun.Early, AppPopups.choose). His decisions: only on his press ("Lattice print accurate" or
// similar), a nice generating modal with an animation, no Mac = Try again / Cancel / Make it on the iPad, "Check right after".
import XCTest
import simd
@testable import TopOptFlows

@MainActor
final class MacPrintAccurate1123Tests: XCTestCase {

    override func tearDown() { LatticeMacMake.shared.reset(); AppPopups.shared.current = nil; super.tearDown() }

    /// Every word on the button and the card is short (his 11-20 rule: five at most).
    func testTheWordsAreShort() {
        for w in [LatticeMacMakeCopy.button, LatticeMacMakeCopy.buttonLine, LatticeMacMakeCopy.making, LatticeMacMakeCopy.checking,
                  LatticeMacMakeCopy.title, LatticeMacMakeCopy.cancel, LatticeMacMakeCopy.tryAgain, LatticeMacMakeCopy.onIPad,
                  LatticeMacMakeCopy.opening, LatticeMacMakeCopy.laying, LatticeMacMakeCopy.printCheck, LatticeMacMakeCopy.makingFile,
                  LatticeMacMakeCopy.saving, LatticeMacMakeCopy.drawing, LatticeMacMakeCopy.waiting,
                  LatticeMacMakeCopy.strengthening(3)] {
            XCTAssertLessThanOrEqual(w.split(separator: " ").count, 5, w)
        }
        XCTAssertTrue(LatticeMacMakeCopy.button.lowercased().contains("print-accurate"), "★ names the step in between")
    }

    /// The Mac's own lines in plain words: the strengthening's rounds counted from one, the file's steps, nothing else.
    func testTheMacsStepsInPlainWords() {
        XCTAssertEqual(LatticeMacMakeCopy.stage("organic-strengthen: laying the lattice (once)"), LatticeMacMakeCopy.laying)
        XCTAssertEqual(LatticeMacMakeCopy.stage("organic-strengthen: checking the lattice prints (round 0)"), LatticeMacMakeCopy.printCheck)
        XCTAssertEqual(LatticeMacMakeCopy.stage("organic-strengthen: round 2: checking its strength"), "Strengthening, round 3")
        XCTAssertEqual(LatticeMacMakeCopy.stage("lattice-file: laying the lattice"), LatticeMacMakeCopy.laying)
        XCTAssertEqual(LatticeMacMakeCopy.stage("lattice-file: making the file"), LatticeMacMakeCopy.makingFile)
        XCTAssertEqual(LatticeMacMakeCopy.stage("lattice-file: saving the file"), LatticeMacMakeCopy.saving)
        XCTAssertEqual(LatticeMacMakeCopy.stage("lattice-file: checking its strength"), LatticeMacMakeCopy.checking)
        XCTAssertNil(LatticeMacMakeCopy.stage("mesh: /Users/x/out/lattice.3mf"))
        XCTAssertNil(LatticeMacMakeCopy.stage("[loadcase] region 153"))
        XCTAssertEqual(LatticeMacMakeCopy.clock(134), "2:14")
        XCTAssertEqual(LatticeMacMakeCopy.clock(3725), "1:02:05")
        XCTAssertTrue(LatticeMacMakeCopy.macStopped("The Mac did not answer (timed out)"))
        XCTAssertTrue(LatticeMacMakeCopy.macStopped("Lost the job on the Mac"))
        XCTAssertFalse(LatticeMacMakeCopy.macStopped("No lattice cell fits anywhere"))
        XCTAssertFalse(LatticeMacMakeCopy.macStopped(nil))
    }

    /// The card: up from his press; the file drawn closes it (the button then says the check runs on a Structural part);
    /// the run's end puts everything back; Cancel cancels the run.
    func testTheCardFromThePressToTheDrawing() {
        let m = LatticeMacMake.shared
        let id = UUID()
        var cancelled = false
        m.begin(project: id, path: "/p/part.step", cancel: { cancelled = true }, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(m.shown); XCTAssertTrue(m.isMaking(id)); XCTAssertFalse(m.isMaking(UUID()))
        XCTAssertEqual(m.stage, LatticeMacMakeCopy.waiting)
        m.fileArrived()
        XCTAssertEqual(m.stage, LatticeMacMakeCopy.drawing)
        m.drawn(checkFollows: true, now: Date(timeIntervalSince1970: 200))
        XCTAssertFalse(m.shown, "★ the drawing closes the card")
        XCTAssertTrue(m.checking); XCTAssertTrue(m.isMaking(id))
        m.ended()
        XCTAssertFalse(m.checking); XCTAssertFalse(m.isMaking(id))
        m.begin(project: id, path: "/p/part.step", cancel: { cancelled = true })
        XCTAssertEqual(m.expectedS, 200, "★ the time it took last time is the card's 'about'")
        m.cancel()
        XCTAssertTrue(cancelled); XCTAssertFalse(m.shown)
        // RED CONTROL: an Aesthetic part (no check after): the card closes and the button is free at once
        m.begin(project: id, path: nil, cancel: {})
        m.drawn(checkFollows: false)
        XCTAssertFalse(m.checking)
    }

    /// No Mac: one centred pop-up, "Try again", "Make it on the iPad" and "Cancel"; each does its own thing.
    func testNoMacAsksTryAgainIPadOrCancel() {
        var did: [String] = []
        AppPopups.shared.choose(LatticeMacMakeCopy.noMacTitle, LatticeMacMakeCopy.noMacText,
                                first: (LatticeMacMakeCopy.tryAgain, { did.append("again") }),
                                second: (LatticeMacMakeCopy.onIPad, { did.append("ipad") }), dismiss: LatticeMacMakeCopy.cancel)
        XCTAssertEqual(AppPopups.shared.current?.title, LatticeMacMakeCopy.noMacTitle)
        XCTAssertEqual(AppPopups.shared.action?.title, LatticeMacMakeCopy.tryAgain)
        XCTAssertEqual(AppPopups.shared.second?.title, LatticeMacMakeCopy.onIPad)
        XCTAssertEqual(AppPopups.shared.dismissTitle, LatticeMacMakeCopy.cancel)
        AppPopups.shared.second?.run()
        AppPopups.shared.action?.run()
        XCTAssertEqual(did, ["ipad", "again"])
        AppPopups.shared.current = nil
        XCTAssertNil(AppPopups.shared.second); XCTAssertNil(AppPopups.shared.dismissTitle)
        // RED CONTROL: a plain pop-up keeps OK alone
        AppPopups.shared.show("t", "x")
        XCTAssertNil(AppPopups.shared.second)
    }

    /// The parts note core writes beside the file: the solid's triangle count.
    func testThePartsNote() {
        XCTAssertEqual(LatticeFileRun.Early.baseTriangles(Data(#"{"base_triangles": 134492, "triangles": 5575534}"#.utf8)), 134492)
        XCTAssertNil(LatticeFileRun.Early.baseTriangles(Data("nope".utf8)))
    }

    /// The file's lattice: only the triangles after the solid's, their vertices packed apart with unit normals pointing out of
    /// each closed shell; a count that is not the file's is refused.
    func testTheFilesLatticeIsTheShellsAfterTheSolid() throws {
        // a solid quad (2 triangles, vertices 0-3), then a closed tetrahedron (vertices 4-7, 4 triangles, outward winding)
        let v: [Float] = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0,
                          10, 10, 10, 11, 10, 10, 10, 11, 10, 10, 10, 11]
        let t: [Int32] = [0, 1, 2, 0, 2, 3,
                          4, 6, 5, 4, 5, 7, 4, 7, 6, 5, 6, 7]
        let m = try LatticeFileMesh.make(vertices: v, indices: t, baseTriangles: 2, token: 1)
        XCTAssertEqual(m.triangleCount, 4)
        XCTAssertEqual(m.vertices.count, 4 * 6, "★ only the shell's own four vertices")
        XCTAssertEqual(Set(m.indices), [0, 1, 2, 3])
        let centre = SIMD3<Float>(10.25, 10.25, 10.25)
        for i in 0..<4 {
            let p = SIMD3(m.vertices[6 * i], m.vertices[6 * i + 1], m.vertices[6 * i + 2])
            let n = SIMD3(m.vertices[6 * i + 3], m.vertices[6 * i + 4], m.vertices[6 * i + 5])
            XCTAssertEqual(simd_length(n), 1, accuracy: 1e-5)
            XCTAssertGreaterThan(simd_dot(n, p - centre), 0, "★ out of the shell")
            XCTAssertGreaterThanOrEqual(p.x, 10, "★ none of the solid's")
        }
        XCTAssertThrowsError(try LatticeFileMesh.make(vertices: v, indices: t, baseTriangles: 6, token: 1), "RED CONTROL: all solid")
        XCTAssertThrowsError(try LatticeFileMesh.make(vertices: v, indices: [0, 1, 99], baseTriangles: 0, token: 1))
    }

    /// The press's path in the workspace: the Mac job from the lattice on screen (no iPad exact), the card begun with it, the
    /// early file drawn; no Mac → the three-choice pop-up; the card mounted at the root; nothing new on the workspace's state.
    func testTheWorkspaceSendsTheDraftToTheMacWithTheCard() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let start = try XCTUnwrap(ws.range(of: "    private func startLatticeRun(_ request: RunRequest) {"))
        let body = String(ws[start.upperBound...].prefix(4200))
        XCTAssertTrue(body.contains("organicMacInputsWhenReady()"), "★ the lattice on screen, a Draft too")
        XCTAssertFalse(body.contains("organicInputsWhenReady()"), "RED CONTROL: never the iPad's exact lay first")
        XCTAssertTrue(body.contains("LatticeMacMake.shared.begin(project: project.id"), "★ the card with his press")
        XCTAssertTrue(body.contains("macNotAnsweringPopup(request)"), "★ no Mac: the three choices")
        XCTAssertTrue(ws.contains("early: macEarlyFile(checkFollows: strengthJob != nil)"), "★ check right after")
        XCTAssertTrue(ws.contains("macStep ? LatticeMacMakeCopy.button"), "★ the button names the step")
        let root = try FlexibleSource.code("RootView.swift")
        XCTAssertTrue(root.contains(".overlay { LatticeMacMakeModal() }"))
        XCTAssertFalse(body.contains(".alert(") || body.contains(".confirmationDialog("))
    }
}
