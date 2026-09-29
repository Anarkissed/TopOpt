// FlexibleStageTests — the app's side of the Flexible stage (task
// 2026-09-29-flexible-screens): the job block the app writes, read back by CORE'S parser;
// stamps rasterised by the app and checked by CORE's force rule; settings saved with the
// project and absent from a project that never chose Flexible.
import XCTest
import CoreGraphics
import ImageIO
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleStageTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    static var materialsPath: String {
        repoRoot.appendingPathComponent("core/src/materials/flexible_materials.json").path
    }
    static var stampsPath: String {
        repoRoot.appendingPathComponent("docs/design/flexibles/data/stamps.json").path
    }
    static var padSTL: String {
        repoRoot.appendingPathComponent(
            "docs/handoffs/evidence/2026-09-28-flexible-squish-maths/a_pad_centre_soft/pad_100x100x20.stl").path
    }

    static func settings() -> FlexibleStageSettings {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", nozzleTempC: 220, topology: "auto",
                                      feel: "damped", beadsPerWall: 1)
        s.setFace(FlexibleFaceSettings(faceRegionID: FlexibleJob.regionID(face: 1), rotationDeg: 90,
                                       weightKg: 30, deepestMM: 4, mode: "both",
                                       curveX: FlexCurve(x: [0, 0.4, 1], y: [0.2, 1, 0.3]),
                                       curveY: FlexCurve(x: [0, 1], y: [1, 0.5]), skinOn: false))
        s.setFace(FlexibleFaceSettings(faceRegionID: FlexibleJob.regionID(face: 0), role: "resting"))
        return s
    }

    static func inputs(_ s: FlexibleStageSettings, stamps: [UUID: FlexStamp] = [:]) -> FlexibleJob.Inputs {
        FlexibleJob.Inputs(modelPath: padSTL, resolution: 50, beadWidthMM: 0.42, faceCount: 6,
                           settings: s, stampGrids: stamps)
    }

    // MARK: S5 — the job block, through core's parser

    func testRunJobRoundTripsThroughCoresParser() throws {
        let s = Self.settings()
        let json = try FlexibleJob.runJobJSON(Self.inputs(s))
        let b = try FlexibleCore.parseJobBlock(json)
        XCTAssertEqual(b.materialID, "varioshore_tpu")
        XCTAssertEqual(b.nozzleTempC, 220)
        XCTAssertEqual(b.topology, "auto")
        XCTAssertEqual(b.feel, "damped")
        XCTAssertEqual(b.beadsPerWall, 1)
        XCTAssertEqual(b.minExtrudableWidthMM, 0.42, "the bead the other stages send")
        let loaded = try XCTUnwrap(b.faces.first { $0.role == "loaded" })
        XCTAssertEqual(loaded.faceRegionID, FlexibleJob.regionID(face: 1))
        XCTAssertEqual(loaded.rotationDeg, 90)
        XCTAssertEqual(loaded.weightN, 30 * 9.80665, accuracy: 1e-9, "kg → N at 9.80665 m/s²")
        XCTAssertEqual(loaded.deepestMM, 4)
        XCTAssertEqual(loaded.map.mode, "both")
        XCTAssertEqual(loaded.map.x, FlexCurve(x: [0, 0.4, 1], y: [0.2, 1, 0.3]))
        XCTAssertEqual(loaded.map.y, FlexCurve(x: [0, 1], y: [1, 0.5]))
        XCTAssertFalse(loaded.skinOn)
        XCTAssertEqual(b.faces.first { $0.role == "resting" }?.faceRegionID, FlexibleJob.regionID(face: 0))
    }

    func testAutoTemperatureAndCentreEdgeRoundTrip() throws {
        var s = Self.settings()
        s.nozzleTempC = nil
        var f = try XCTUnwrap(s.face(FlexibleJob.regionID(face: 1)))
        f.mode = "centre_edge"
        f.curveCentreEdge = FlexCurve(x: [0, 0.5, 1], y: [0, 0.8, 1])
        s.setFace(f)
        let b = try FlexibleCore.parseJobBlock(try FlexibleJob.runJobJSON(Self.inputs(s)))
        XCTAssertTrue(b.nozzleTempAuto)
        let loaded = try XCTUnwrap(b.faces.first { $0.role == "loaded" })
        XCTAssertEqual(loaded.map.mode, "centre_edge")
        XCTAssertEqual(loaded.map.centreEdge, f.curveCentreEdge)
    }

    func testStampsRoundTripAsCoreGrids() throws {
        let lib = try FlexibleStampLibrary.load(path: Self.stampsPath)
        var s = Self.settings()
        let thumb = FlexibleStamps.place(try XCTUnwrap(lib.shape("thumb")), uExtentMM: 100, vExtentMM: 100, weightKg: 5)
        let palm = FlexibleStamps.place(try XCTUnwrap(lib.shape("palm")), uExtentMM: 100, vExtentMM: 100, weightKg: 20)
        var f = try XCTUnwrap(s.face(FlexibleJob.regionID(face: 1)))
        f.designStamp = thumb
        s.setFace(f)
        s.checkStamps = [FlexibleCheckStamp(faceRegionID: f.faceRegionID, stamp: palm)]
        let pitch = 2.0
        var grids: [UUID: FlexStamp] = [:]
        for p in [thumb, palm] {
            grids[p.id] = try XCTUnwrap(FlexibleStamps.grid(p, library: lib, uExtentMM: 100, vExtentMM: 100,
                                                           pitchMM: pitch, onFace: { _, _ in true }))
        }
        let b = try FlexibleCore.parseJobBlock(try FlexibleJob.runJobJSON(Self.inputs(s, stamps: grids)))
        let loaded = try XCTUnwrap(b.faces.first { $0.role == "loaded" })
        XCTAssertEqual(loaded.designStamp, grids[thumb.id])
        XCTAssertEqual(b.checkStamps.count, 1)
        XCTAssertEqual(b.checkStamps[0].stamp, grids[palm.id])
        XCTAssertEqual(b.checkStamps[0].face, f.faceRegionID)
    }

    func testRunJobRefusesWithoutAFilamentOrALoadedFace() {
        XCTAssertThrowsError(try FlexibleJob.runJobJSON(Self.inputs(FlexibleStageSettings()))) {
            XCTAssertEqual($0 as? FlexibleJob.EncodeError, .noFilament)
        }
        XCTAssertThrowsError(try FlexibleJob.runJobJSON(Self.inputs(FlexibleStageSettings(materialID: "varioshore_tpu")))) {
            XCTAssertEqual($0 as? FlexibleJob.EncodeError, .noLoadedFace)
        }
    }

    /// The scene job opens a real scene on the pad (no loaded face needed).
    func testSceneJobOpensAScene() throws {
        let json = try FlexibleJob.sceneJobJSON(Self.inputs(FlexibleStageSettings()), fallbackMaterial: "varioshore_tpu")
        let scene = try FlexibleScene(jobJSON: json, jobDir: "/")
        let info = try scene.info()
        XCTAssertEqual(info.regions.count, 6)
        XCTAssertGreaterThan(info.latticeVoxels, 0)
    }

    // MARK: S4 — stamps rasterised by the app, checked by core

    func testEveryLibraryStampConservesItsForceByCoresRule() throws {
        let lib = try FlexibleStampLibrary.load(path: Self.stampsPath)
        XCTAssertEqual(Set(lib.stamps.map(\.id)),
                       ["fingertip", "thumb", "four_fingers", "palm", "fist", "heel", "knee", "elbow",
                        "flat_plate", "ifd_foot"])
        for pitch in [1.0, 2.0, 3.4] {
            for shape in lib.stamps {
                let p = FlexibleStamps.place(shape, uExtentMM: 300, vExtentMM: 300, weightKg: 7)
                let g = try XCTUnwrap(FlexibleStamps.grid(p, library: lib, uExtentMM: 300, vExtentMM: 300,
                                                         pitchMM: pitch, onFace: { _, _ in true }), shape.id)
                XCTAssertEqual(FlexibleCore.stampError(g), "", "\(shape.id) at pitch \(pitch)")
                XCTAssertLessThanOrEqual(g.cellMM, pitch / 2 + 1e-12, "C1 #6: at most half the column pitch")
                XCTAssertEqual(g.rigid, shape.press == "rigid", shape.id)
            }
        }
    }

    func testStampSizeAndRotationFollowTheShape() throws {
        let lib = try FlexibleStampLibrary.load(path: Self.stampsPath)
        let thumb = try XCTUnwrap(lib.shape("thumb"))                      // 20 × 26 ellipse
        var p = FlexibleStamps.place(thumb, uExtentMM: 100, vExtentMM: 100, weightKg: 2)
        let g0 = try XCTUnwrap(FlexibleStamps.grid(p, library: lib, uExtentMM: 100, vExtentMM: 100, pitchMM: 1, onFace: { _, _ in true }))
        XCTAssertEqual(Double(g0.nu) * g0.cellMM, 20, accuracy: 1)
        XCTAssertEqual(Double(g0.nv) * g0.cellMM, 26, accuracy: 1)
        // core's narrowest-width measure of the rasterised shape ≈ its 20 mm width
        XCTAssertEqual(FlexibleCore.stampWidthMM(g0), 20, accuracy: 2)
        p.rotationDeg = 90
        let g1 = try XCTUnwrap(FlexibleStamps.grid(p, library: lib, uExtentMM: 100, vExtentMM: 100, pitchMM: 1, onFace: { _, _ in true }))
        XCTAssertEqual(Double(g1.nu) * g1.cellMM, 26, accuracy: 1, "turned 90°: the long side runs along u")
    }

    func testWholeFaceStampCoversOnlyTheFace() throws {
        let lib = try FlexibleStampLibrary.load(path: Self.stampsPath)
        let plate = try XCTUnwrap(lib.shape("flat_plate"))
        let p = FlexibleStamps.place(plate, uExtentMM: 40, vExtentMM: 40, weightKg: 10)
        // a face that is only the left half of its box
        let g = try XCTUnwrap(FlexibleStamps.grid(p, library: lib, uExtentMM: 40, vExtentMM: 40, pitchMM: 2,
                                                 onFace: { u, _ in u < 20 }))
        XCTAssertTrue(g.rigid)
        XCTAssertEqual(FlexibleCore.stampError(g), "")
        for iv in 0..<g.nv { for iu in 0..<g.nu where (Double(iu) + 0.5) * g.cellMM > 21 {
            XCTAssertEqual(g.valuesMPa[iv * g.nu + iu], 0, "no pressure off the face")
        } }
    }

    func testImportedImageDarkerPressesHarder() throws {
        // a 2 × 1 image: left black, right mid grey
        let w = 2, h = 1
        var px: [UInt8] = [0, 0, 0, 255, 128, 128, 128, 255]
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        guard case .imported(_, let side, let mask, let aspect) = try FlexibleStampImport.image(data: data as Data, name: "t")
        else { return XCTFail("not an imported stamp") }
        XCTAssertEqual(aspect, 2, accuracy: 1e-9)
        let left = mask[side / 2 * side + side / 4], right = mask[side / 2 * side + 3 * side / 4]
        XCTAssertGreaterThan(left, right, "darker presses harder")
        XCTAssertGreaterThan(right, 0.3)
    }

    func testImportedSVGOutlineIsFilled() throws {
        let svg = #"<svg viewBox="0 0 100 50"><path d="M0 0 L100 0 L100 50 L0 50 Z"/></svg>"#
        guard case .imported(_, let side, let mask, let aspect) = try FlexibleStampImport.svg(text: svg, name: "r")
        else { return XCTFail("not an imported stamp") }
        XCTAssertEqual(aspect, 2, accuracy: 1e-6)
        XCTAssertGreaterThan(mask[side / 2 * side + side / 2], 0.9)
        XCTAssertThrowsError(try FlexibleStampImport.svg(text: "<svg></svg>", name: "e"))
    }

    // MARK: S5 — saved with the project

    func testSettingsRoundTripInsideLatticeSettings() throws {
        var lat = LatticeSettings()
        lat.flexible = Self.settings()
        let data = try JSONEncoder().encode(lat)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertEqual(back.flexible, lat.flexible)
        XCTAssertNil(back.stageMode, "Flexible is a choice BESIDE stageMode, never a case of it")
    }

    func testAProjectThatNeverChoseFlexibleIsByteIdentical() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let plain = try enc.encode(LatticeSettings())
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("flexible"))
        let back = try JSONDecoder().decode(LatticeSettings.self, from: plain)
        XCTAssertNil(back.flexible)
        XCTAssertEqual(try enc.encode(back), plain)
    }

    func testDeleteAndReAskClearsFlexible() {
        var lat = LatticeSettings()
        lat.flexible = Self.settings()
        lat = LatticeSettings()           // what "Delete and choose again" does
        XCTAssertNil(lat.flexible)
        XCTAssertNil(lat.stageMode)
    }

    @MainActor
    func testEditsAreUndoableWithTheProject() throws {
        let project = ProjectModel(id: UUID(), name: "flex", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        project.lattice.flexible = FlexibleStageSettings()
        project.sealUndoStep()
        project.lattice.flexible?.materialID = "varioshore_tpu"
        project.sealUndoStep()
        XCTAssertEqual(project.lattice.flexible?.materialID, "varioshore_tpu")
        project.performUndo()
        XCTAssertNil(project.lattice.flexible?.materialID)
        project.performRedo()
        XCTAssertEqual(project.lattice.flexible?.materialID, "varioshore_tpu")
    }

    func testWeightIsConvertedAtStandardGravity() {
        XCTAssertEqual(FlexibleUnits.newtons(kg: 1), 9.80665, accuracy: 1e-12)
        XCTAssertEqual(FlexibleFaceSettings(faceRegionID: 1, weightKg: 30).weightN, 294.1995, accuracy: 1e-9)
    }
}
