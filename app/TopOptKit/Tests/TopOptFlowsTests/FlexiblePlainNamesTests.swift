// FlexiblePlainNamesTests — ★ B10 for the Flexible pages (#362; the reviewer's scope ruling 2026-11-11 03:50Z: "#362 fixes
// the Flexible pages"). Design-system §3: "Faces from Cut — plain names: 'Left drum top, half 1' — never Face 104"; his rule
// (10-24): never a face number. Before B10 every Flexible row, chip, card and line named a face "Face 3" (its number), and
// BannedWordsTests skipped the Flexible files.
//   • a Flexible file's "Face 3" is caught by the §3 scan now (RED before: the Flexible prefix was skipped);
//   • a stored name's data form ("Face 12 A", "Edge 9 · Face 1") reads as the face's plain name; a plain name's own
//     number ("Sloped face 2, facing up") is left alone;
//   • on his pad the page's names are the plain names Lattice Setup and Topology give, never a number;
//   • core's sentence names a whole face plainly too ("face 3 is too firm" → "Top face is too firm").
#if canImport(AppKit)
import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class FlexiblePlainNamesTests: XCTestCase {

    func testAFlexibleFilesFaceNumberIsCaught() {
        // ★ RED before B10: "Flexible" was a listed prefix, so nothing in a Flexible file was scanned
        XCTAssertEqual(BannedWordsTests.scanSection3([#"        Text("Face \(f) rests")"#], file: "FlexibleX.swift").count, 1,
                       "★ a Flexible file's face number is a §3 word")
        // control: the lattice pages are still listed (they wait for the rebuild)
        XCTAssertEqual(BannedWordsTests.scanSection3([#"        Text("Face \(f) rests")"#], file: "LatticeX.swift"), [])
    }

    func testAStoredNamesDataFormReadsAsThePlainName() {
        let plain: (Int) -> String = { $0 == 12 ? "Top face" : "Underside" }
        XCTAssertEqual(FlexibleRowCopy.plainFaces("Face 12 A", plain), "Top face A")
        XCTAssertEqual(FlexibleRowCopy.plainFaces("Edge 9 · Face 1", plain), "Edge 9 · Underside")
        XCTAssertEqual(FlexibleRowCopy.plainFaces("Sloped face 2, facing up", plain), "Sloped face 2, facing up",
                       "a plain name's own number stays")
        XCTAssertEqual(FlexibleRowCopy.faceName(sector: nil, face: 12, plain: plain), "Top face")
        XCTAssertEqual(FlexibleRowCopy.faceName(sector: "Face 12 B", face: 12, plain: plain), "Top face B")
        XCTAssertEqual(FlexibleRowCopy.faceName(sector: "top A", face: 12, plain: plain), "Top A", "his own sector name stays")
    }

    func testThePadsNamesAreThePlainNames() throws {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        let plain = pm.faceName(FaceID(top))
        XCTAssertNil(plain.range(of: #"^Face \d"#, options: .regularExpression), "premise: the pad's top has a plain name: \(plain)")
        XCTAssertEqual(m.displayName(top), plain, "★ the panel's name is the plain name")
        XCTAssertEqual(m.name(top), plain, "★ the sentence name too")
        XCTAssertEqual(m.text("face \(top) is too firm"), "\(plain) is too firm", "★ core's sentence names the face plainly")
        XCTAssertEqual(m.plainNamer()(top), plain, "★ the off-main namer is the same name")
        for f in Set(mesh.faceIDs) {
            XCTAssertNil(m.displayName(Int(f)).range(of: #"\bFace \d"#, options: .regularExpression),   // ("Curved face 2" is a plain name's own number)
                         "★ never a face number: \(m.displayName(Int(f)))")
        }
    }
}
#endif
