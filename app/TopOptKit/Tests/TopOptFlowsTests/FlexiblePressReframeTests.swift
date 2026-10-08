// FlexiblePressReframeTests — inputs carried between two of core's frames (task 2026-10-07, angled presses,
// batch AP1; final spec §4 "Inputs belong to a frame"). C1's pad with its top split at x = 50 on the Surface
// stage's own model (FlexibleRegionsTests.splitTop): the whole top is a square, so core TIES its principal
// axes (X = ±X), and Top B (x < 50) is 50 × 100, so core's X runs along its long side (±Y). A face press
// moved from Top to Top B (spec §8's [Press the rest of Top]) keeps its stamp at the same point ON THE
// SURFACE and each curve along the world axis it was drawn along — through core's stack, from_uv and to_uvt
// only. A press's own frame (core's build_press_stack) waits on AP9 and says so.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePressReframeTests: XCTestCase {

    struct Split {
        let scene: FlexibleScene
        let frames: FlexibleSceneFrames
        let top: Int
        let topB: Int
        let model: FaceRegionModel
    }

    /// C1's pad, top split at x = 50, opened as a scene the way the page opens one (the sectors declared).
    static func split() throws -> Split {
        let (mesh, path) = FlexibleRegionsTests.pad
        let (model, _) = FlexibleRegionsTests.splitTop(mesh)
        let regions = FlexibleRegions(model: model, mesh: mesh)
        let top = regions.faces(of: FlexibleRegions.wireID(regions.sectors[0]), mesh: mesh)[0]
        let topB = regions.region(at: SIMD3(20, 50, 20), face: top, mesh: mesh)
        XCTAssertTrue(FlexibleRegions.isSector(topB), "premise: Top B is a sector")
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", nozzleTempC: 220)
        s.setFace(FlexibleFaceSettings(faceRegionID: top, weightKg: 10, deepestMM: 3))
        var inputs = FlexibleJob.Inputs(modelPath: path, resolution: 50, beadWidthMM: 0.42, faceCount: 6, settings: s)
        inputs.sectorRegions = regions.wire
        let scene = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(inputs, fallbackMaterial: "varioshore_tpu"), jobDir: "/")
        return Split(scene: scene, frames: FlexibleSceneFrames(scene), top: top, topB: topB, model: model)
    }

    static let cx = FlexCurve(x: [0, 0.3, 1], y: [0.2, 0.9, 0.5])
    static let cy = FlexCurve(x: [0, 0.8, 1], y: [0.7, 0.1, 0.35])

    /// Top's press: two different curves and a 12 × 20 mm stamp turned 30°, centred at the world point
    /// (25, 70, 20) — inside Top B's half.
    static func topPress(_ sp: Split) throws -> FlexibleFaceSettings {
        let uv = try sp.frames.toUVT(.face(sp.top), [SIMD3(25, 70, 20)])[0]
        let stamp = FlexibleStampPlacement(id: UUID(uuidString: "AE000003-0000-4000-8000-000000000001")!,
                                           source: .library("thumb"), widthMM: 12, lengthMM: 20, rotationDeg: 30,
                                           centreU: uv.x, centreV: uv.y, weightKg: 10, rigid: false)
        return FlexibleFaceSettings(faceRegionID: sp.top, weightKg: 10, deepestMM: 3, curveX: cx, curveY: cy,
                                    designStamp: stamp, shape: "stamp")
    }

    /// The stamp's point on the part, through core: from_uv + the column's entry along the load.
    static func onPart(_ sp: Split, _ ref: FlexibleFrameRef, _ st: FlexStackInfo, _ u: Double, _ v: Double) throws -> SIMD3<Double> {
        try sp.frames.fromUV(ref, [SIMD2(u, v)])[0] + st.load * st.entryT(nearU: u, v: v)
    }

    /// The stamp's width axis on the part (its heading in the world), from core's axes.
    static func heading(_ st: FlexStackInfo, _ p: FlexibleStampPlacement) -> SIMD3<Double> {
        let th = p.rotationDeg * .pi / 180
        return cos(th) * st.xAxis + sin(th) * st.yAxis
    }

    /// ★ Top's press moved to Top B: the stamp's point on the surface is unchanged (1e-9 mm) and so is its
    /// heading; the curves SWAP (Top's X runs along world X, Top B's X along world Y) and each runs the same
    /// way along its world axis (judged by core's own from_uv at the curves' ends). RED: the unconverted
    /// settings (the AP1 red commit's reframe) put the stamp elsewhere and run the X curve along world Y.
    func testMovingTopsPressToTopBKeepsTheStampOnTheSurfaceAndCurvesOnTheirAxes() throws {
        let sp = try Self.split()
        let a = try sp.frames.stack(.face(sp.top)), b = try sp.frames.stack(.face(sp.topB))
        print("FLEX-AP1 reframe: Top X \(a.xAxis) Y \(a.yAxis) tied \(a.principalAxisTied) \(a.uExtentMM)×\(a.vExtentMM) · Top B X \(b.xAxis) Y \(b.yAxis) tied \(b.principalAxisTied) \(b.uExtentMM)×\(b.vExtentMM)")
        XCTAssertTrue(a.principalAxisTied, "premise: the whole top is a square — core ties its axes")
        XCTAssertFalse(b.principalAxisTied, "premise: Top B is 50 × 100 — untied")
        XCTAssertGreaterThan(abs(a.xAxis.x), 0.999, "premise: Top's X is ±X")
        XCTAssertGreaterThan(abs(b.xAxis.y), 0.999, "premise: Top B's X is ±Y (its long side)")
        let f = try Self.topPress(sp)
        let stamp = try XCTUnwrap(f.designStamp)
        let r = try FlexiblePressReframe.reframe(f, from: .face(sp.top), to: .face(sp.topB), frames: sp.frames)
        let moved = try XCTUnwrap(r.settings.designStamp)

        // the stamp: the same point ON THE SURFACE, the same heading
        let was = try Self.onPart(sp, .face(sp.top), a, stamp.centreU, stamp.centreV)
        let now = try Self.onPart(sp, .face(sp.topB), b, moved.centreU, moved.centreV)
        print("FLEX-AP1 reframe stamp: (\(stamp.centreU), \(stamp.centreV)) @\(stamp.rotationDeg)° in Top → (\(moved.centreU), \(moved.centreV)) @\(moved.rotationDeg)° in Top B · on the part \(was) → \(now) · moved \(simd_distance(was, now)) mm")
        XCTAssertEqual(was.x, 25, accuracy: 1e-9, "premise: the stamp sits at x = 25")
        XCTAssertEqual(was.y, 70, accuracy: 1e-9)
        XCTAssertLessThan(simd_distance(was, now), 1e-9, "★ the stamp's point on the surface is unchanged")
        XCTAssertLessThan(simd_distance(Self.heading(a, stamp), Self.heading(b, moved)), 1e-9, "its heading on the part too")
        XCTAssertEqual(moved.widthMM, stamp.widthMM)
        XCTAssertEqual(moved.lengthMM, stamp.lengthMM)

        // the curves: each along the world axis it was drawn along, the same way (core's from_uv at its ends)
        XCTAssertTrue(r.swapped, "★ Top B's X runs along the world axis Top's Y ran along")
        let oldX = try sp.frames.fromUV(.face(sp.top), [SIMD2(0, 0), SIMD2(a.uExtentMM, 0)])
        let oldY = try sp.frames.fromUV(.face(sp.top), [SIMD2(0, 0), SIMD2(0, a.vExtentMM)])
        let newX = try sp.frames.fromUV(.face(sp.topB), [SIMD2(0, 0), SIMD2(b.uExtentMM, 0)])
        let newY = try sp.frames.fromUV(.face(sp.topB), [SIMD2(0, 0), SIMD2(0, b.vExtentMM)])
        let xSame = (oldY[1].y - oldY[0].y) * (newX[1].y - newX[0].y) > 0   // world Y: Top's Y curve vs Top B's X
        let ySame = (oldX[1].x - oldX[0].x) * (newY[1].x - newY[0].x) > 0   // world X: Top's X curve vs Top B's Y
        print("FLEX-AP1 reframe curves: swapped \(r.swapped) · reversed X \(r.reversedX) Y \(r.reversedY) · world senses X \(xSame) Y \(ySame)")
        XCTAssertEqual(r.settings.curveX, xSame ? Self.cy : FlexiblePressReframe.reversed(Self.cy), "★ Top B's X curve is Top's Y curve, along world Y")
        XCTAssertEqual(r.settings.curveY, ySame ? Self.cx : FlexiblePressReframe.reversed(Self.cx), "★ Top B's Y curve is Top's X curve, along world X")
        XCTAssertEqual(r.reversedX, !xSame)
        XCTAssertEqual(r.reversedY, !ySame)
        XCTAssertEqual(r.toast, "Curves follow the face")
        // everything else as it was
        var rest = r.settings
        rest.curveX = f.curveX; rest.curveY = f.curveY; rest.designStamp = f.designStamp
        XCTAssertEqual(rest, f, "only the curves and the stamp are re-expressed")

        // ★ RED CONTROL: the UNCONVERTED settings in Top B's frame
        let stays = try Self.onPart(sp, .face(sp.topB), b, stamp.centreU, stamp.centreV)
        print("FLEX-AP1 reframe control: the unconverted stamp lands at \(stays), \(simd_distance(was, stays)) mm away")
        XCTAssertGreaterThan(simd_distance(was, stays), 1, "control: unconverted, the stamp moves on the part")
        XCTAssertLessThan(abs(simd_dot(b.xAxis, SIMD3(1, 0, 0))), 1e-6, "control: unconverted, Top's X curve would run along world Y")
    }

    /// The same frame returns the settings bit for bit (no toast); a press's OWN frame waits on core
    /// (AP9) and says so; the model's wrapper reads core's frames through the open scene, with the
    /// same answer as the pure call.
    func testTheSameFrameIsUnchangedAndAPressFrameWaitsOnCore() async throws {
        let sp = try Self.split()
        let f = try Self.topPress(sp)
        let same = try FlexiblePressReframe.reframe(f, from: .face(sp.top), to: .face(sp.top), frames: sp.frames)
        XCTAssertEqual(same.settings, f)
        XCTAssertNil(same.toast)
        XCTAssertThrowsError(try FlexiblePressReframe.reframe(f, from: .face(sp.top), to: .press(UUID()), frames: sp.frames)) {
            XCTAssertEqual($0 as? FlexiblePressReframe.Waiting, .pressFrame, "a press's frame is core's build_press_stack — AP9")
            print("FLEX-AP1 reframe waits: \($0)")
        }
        XCTAssertThrowsError(try sp.frames.stack(.press(UUID())))

        // the model's wrapper, through the page's own open scene of the same split pad
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        pm.faceRegions = sp.model
        let m = try await FlexibleHisProject.openedModel(pm, test: self)
        let viaModel = try await m.reframed(f, from: .face(sp.top), to: .face(sp.topB))
        let pure = try FlexiblePressReframe.reframe(f, from: .face(sp.top), to: .face(sp.topB), frames: sp.frames)
        XCTAssertEqual(viaModel, pure, "the open scene gives core's same frames")
        do {
            _ = try await m.reframed(f, from: .face(sp.top), to: .press(UUID()))
            XCTFail("a press frame must wait on core")
        } catch {
            XCTAssertEqual(error as? FlexiblePressReframe.Waiting, .pressFrame)
        }
    }
}
