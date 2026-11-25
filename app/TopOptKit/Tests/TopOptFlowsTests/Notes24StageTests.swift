// Notes24StageTests — ★ his iPad notes 2026-11-23 (on release 15), the stage's floor:
//   * item 1 (img 49): "At perfectly straight on, the background becomes this blue haze instead of showing a flat floor line and
//     keeping the same black background." A level view (the orthographic front view his picture shows, and the lens's) keeps
//     the black background and draws the floor as one thin line at the part's base. RED CONTROL `controlHazeAtLevel`: the glow
//     as before (the blue haze, no line).
//   * item 4: "Can you make the grid an infinitely shrinking view of squares? So I want to be able to see more and more squares
//     the more I zoom in. And when I zoom out, it should hide the smallest of the squares." Squares of 10ⁿ mm, each 10 × 10 of
//     the next finer, chosen by how much floor a pixel covers; the levels cross-fade (no pop: RED CONTROL a hard switch pops);
//     lines one pixel wide at every level; on the renderer, zooming in a hundred times still shows squares (never a mat, never
//     bare) and the picture changes smoothly through a decade of zoom.
import XCTest
import simd
@testable import TopOptFlows
#if canImport(Metal)
import Metal
#endif

final class Notes24StageTests: XCTestCase {

    override func tearDown() {
        StageFloor.controlHazeAtLevel = false
        super.tearDown()
    }

    // MARK: item 1, pure

    /// The floor is a plane from about 10° up or down, an edge-on line within about 2° of level; the glow is as wide as the
    /// lens's share of the picture (the telephoto's rays are all within half a degree of level).
    func testThePlaneFollowsTheElevationAndTheGlowNeverCoversTheScreen() {
        XCTAssertEqual(StageFloor.planeWeight(elevationSine: 0), 0, "★ level: the floor edge-on")
        XCTAssertEqual(StageFloor.planeWeight(elevationSine: sinf(1.5 * .pi / 180)), 0)
        XCTAssertEqual(StageFloor.planeWeight(elevationSine: sinf(12 * .pi / 180)), 1, "looking down: a plane, as before")
        XCTAssertEqual(StageFloor.planeWeight(elevationSine: -sinf(30 * .pi / 180)), 1, "and looking up")
        var last: Float = -1
        for d in stride(from: Float(0), through: 20, by: 0.25) {
            let w = StageFloor.planeWeight(elevationSine: sinf(d * .pi / 180))
            XCTAssertGreaterThanOrEqual(w, last, "rises with the elevation, never jumps back")
            XCTAssertEqual(w, StageFloor.planeWeight(elevationSine: -sinf(d * .pi / 180)), "either side alike")
            last = w
        }
        let cam = OrbitCamera()
        XCTAssertEqual(StageFloor.glowBand(drawFovY: cam.fovY, fovY: cam.fovY), 0.14, accuracy: 1e-6, "the lens: as before")
        XCTAssertLessThan(StageFloor.glowBand(drawFovY: OrbitCamera.telephotoFovY, fovY: cam.fovY), 0.005,
                          "★ the orthographic telephoto: the same share of its picture, never all of it")
    }

    #if canImport(Metal)
    // MARK: item 1, on the renderer

    /// A 200 × 60 × 80 mm box seen level (front view), orthographic as in his picture and through the lens: the background
    /// keeps the black of every other view, and the floor shows as one thin line at the part's base beside it.
    func testALevelViewKeepsTheBlackBackgroundAndDrawsTheFloorAsOneLine() throws {
        let r = try renderer()
        let (w, h) = (480, 360)
        func frame() throws -> [UInt8] {
            try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                                            stage: true))
        }
        func px(_ f: [UInt8], _ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = 4 * (y * w + x)
            return SIMD3(Float(f[i + 2]), Float(f[i + 1]), Float(f[i]))   // BGRA
        }
        func meanBlue(_ f: [UInt8], rows: Range<Int>, cols: [Int]) -> Float {
            var s: Float = 0, n: Float = 0
            for y in rows { for x in cols { s += px(f, x, y).z; n += 1 } }
            return s / n
        }
        let beside = [8, 24, 40, w - 41, w - 25, w - 9]
        for ortho in [true, false] {
            r.camera.orthographic = ortho
            r.camera.setOrientation(azimuth: 0, elevation: 0)
            let name = ortho ? "orthographic" : "lens"
            XCTAssertEqual(r.stageGridForTesting(aspect: Float(w) / Float(h)).plane, 0, "premise: \(name) level")
            let f = try frame()
            // the background above the part and around the horizon (the lens's horizon is the middle row)
            let top = meanBlue(f, rows: 0..<(h / 8), cols: Array(stride(from: 0, to: w, by: 7)))
            let mid = meanBlue(f, rows: (h / 2 - 12)..<(h / 2 - 4), cols: beside)
            print("LEVEL VIEW \(name): top blue \(top), middle blue \(mid)")
            XCTAssertLessThan(top, 20, "★ \(name): the same black background (no blue haze)")
            XCTAssertLessThan(mid, 22, "★ \(name): no haze at the horizon either")
            // the floor's line (orthographic: the floor edge-on), in the columns beside the part: one thin run of brighter
            // rows, at the part's base (the lens sees its floor as a plane below the part, its grid drawn)
            let base = try XCTUnwrap((0..<h).last { px(f, w / 2, $0).sum() > 300 }, "premise: the box's base row")
            for x in ortho ? [24, w - 25] : [] {
                let col = (0..<h).map { px(f, x, $0).z }
                let floorRows = (1..<(h - 1)).filter { col[$0] > col[$0 - 1] + 6 || col[$0] > (col.sorted()[h / 2] + 12) }
                print("  \(name) column \(x): line rows \(floorRows), the part's base row \(base)")
                XCTAssertFalse(floorRows.isEmpty, "★ \(name): the floor's line is drawn")
                XCTAssertLessThanOrEqual(floorRows.count, 4, "★ \(name): one thin line, not a band")
                XCTAssertTrue(floorRows.allSatisfy { abs($0 - base) <= 4 }, "★ \(name): at the part's base")
            }
            // RED CONTROL: the glow as before 11-23 — the level view's blue haze, and no line
            StageFloor.controlHazeAtLevel = true
            let hazy = try frame()
            StageFloor.controlHazeAtLevel = false
            let hazyMid = meanBlue(hazy, rows: (h / 2 - 12)..<(h / 2 - 4), cols: beside)
            print("  RED CONTROL \(name): top blue \(meanBlue(hazy, rows: 0..<(h / 8), cols: Array(stride(from: 0, to: w, by: 7)))), "
                  + "middle \(hazyMid)")
            XCTAssertGreaterThan(hazyMid, mid + 15, "RED CONTROL \(name): the old glow is the blue haze")
            if ortho {
                XCTAssertGreaterThan(meanBlue(hazy, rows: 0..<(h / 8), cols: Array(stride(from: 0, to: w, by: 7))), 35,
                                     "RED CONTROL: orthographic, the haze covered the whole screen (img 49)")
            }
        }
        // looking down (30°): the floor a plane as before, its grid drawn
        r.camera.orthographic = false
        r.camera.setOrientation(azimuth: 0.4, elevation: 0.5)
        XCTAssertEqual(r.stageGridForTesting(aspect: Float(w) / Float(h)).plane, 1, "looking down: the plane, as before")
    }

    // MARK: item 4, on the renderer

    /// The floor seen from 70° up, away from the part, at the framed distance and zoomed in 10 and 100 times: squares at every
    /// zoom (never bare, never a mat of lines), and through a decade of zoom the picture's line light changes smoothly.
    func testZoomingInShowsSmallerSquaresWithoutAPop() throws {
        let r = try renderer()
        r.camera.orthographic = false
        r.camera.minDistance = 1e-4
        let floorY = r.stageGridForTesting(aspect: 1).floorY
        r.camera.target = SIMD3(100 - 250, floorY, 40)   // the floor, 250 mm from the box (well inside the fade)
        r.camera.setOrientation(azimuth: 0.3, elevation: 1.22)
        let n = 256
        let bare = try XCTUnwrap(r.renderOffscreen(width: n, height: n, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                                                   stage: false))
        _ = bare
        func lineLight(_ d: Float) throws -> (light: Float, lit: Float) {
            r.camera.distance = d
            let f = try XCTUnwrap(r.renderOffscreen(width: n, height: n, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                                                    stage: true))
            // the background's blue under no line: the frame's lowest blue in each row
            var light: Float = 0, lit: Float = 0
            for y in 0..<n {
                var lo: Float = 255
                for x in 0..<n { lo = Swift.min(lo, Float(f[4 * (y * n + x)])) }
                for x in 0..<n {
                    let b = Float(f[4 * (y * n + x)]) - lo
                    light += b
                    if b > 8 { lit += 1 }
                }
            }
            return (light / Float(n * n), lit / Float(n * n))
        }
        for zoom: Float in [1, 10, 100] {
            let v = try lineLight(300 / zoom)
            print("GRID zoomed \(zoom)×: line light \(v.light), lines on \(v.lit * 100)% of the floor")
            XCTAssertGreaterThan(v.lit, 0.01, "★ zoomed \(zoom)×: squares are drawn (never bare)")
            XCTAssertLessThan(v.lit, 0.45, "★ zoomed \(zoom)×: never a mat of lines")
        }
        var worst: Float = 0, prev: Float?
        for k in 0...20 {
            let v = try lineLight(300 / powf(10, 1 + Float(k) / 20)).light
            if let p = prev { worst = Swift.max(worst, abs(v - p) / Swift.max(p, 1e-3)) }
            prev = v
        }
        print("GRID through a decade of zoom: the largest step in line light \(worst * 100)%")
        XCTAssertLessThan(worst, 0.3, "★ the levels cross-fade: no pop as he zooms")
    }

    // MARK: helpers

    /// A 200 × 60 × 80 mm box, settled (its floor under it).
    private func renderer() throws -> MeshRenderer {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        guard let r = MeshRenderer(device: d) else { throw XCTSkip("MeshRenderer: \(MeshRenderer.lastInitError ?? "?")") }
        r.setMesh(StageFloorRendererTests.box())
        r.beginSettle(to: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), duration: 0)
        return r
    }
    #endif

    // MARK: item 4, pure (the shader's rule, StageFloor.levels / strength)

    /// Zooming in ten times shows squares ten times smaller; the finest that shows is at least 8 px across; a level finer than
    /// that is hidden (zoomed out, the smallest squares go).
    func testTheSquaresShrinkWithTheZoomAndTheSmallestHideZoomedOut() {
        for e in stride(from: Float(-4.5), through: 2.5, by: 1) {
            let p = powf(10, e)
            let a = StageFloor.levels(pixelMM: p), b = StageFloor.levels(pixelMM: p / 10)
            XCTAssertEqual(b[0].sideMM, a[0].sideMM / 10, accuracy: a[0].sideMM * 1e-3, "★ ten times in: squares ten times smaller")
            XCTAssertGreaterThanOrEqual(a[0].sideMM / p, StageFloor.firstShowsPx * 0.999, "the finest at least 8 px across")
            XCTAssertLessThan(a[0].sideMM / p, StageFloor.firstShowsPx * 10.001)
            XCTAssertGreaterThan(a[2].strength, a[0].strength, "the coarser lines stronger")
        }
        XCTAssertEqual(StageFloor.strength(rank: -0.3), 0, "★ squares under 8 px: hidden")
        XCTAssertEqual(StageFloor.strength(rank: 0), 0, "they fade in from nothing")
        XCTAssertEqual(StageFloor.strength(rank: 0.6), StageFloor.minorAlpha, accuracy: 1e-6)
        XCTAssertEqual(StageFloor.strength(rank: 2), StageFloor.majorAlpha, accuracy: 1e-6, "a major line as release 14's")
        XCTAssertEqual(StageFloor.strength(rank: 7), StageFloor.majorAlpha, accuracy: 1e-6)
    }

    /// At a fixed floor point, the line strength as he zooms through five decades in small steps never jumps (the levels
    /// cross-fade). RED CONTROL: a hard switch between levels jumps.
    func testTheLevelsCrossFadeWithoutAPop() {
        let points: [SIMD2<Double>] = [SIMD2(3.7, 12.15), SIMD2(10, 0.004), SIMD2(0.5, 0.25), SIMD2(100, 37.02), SIMD2(1, 1)]
        func hard(_ px: Float, _ xz: SIMD2<Double>) -> Float {   // RED CONTROL: each level at full strength at once
            let l = log10f(px * StageFloor.firstShowsPx)
            var a: Float = 0
            for k in 0..<3 {
                let s = Double(powf(10, l.rounded(.up) + Float(k)))
                func mask(_ c: Double) -> Double {
                    let f = c / s - 0.5
                    return 1 - Swift.min(abs((f - f.rounded(.down)) - 0.5) / (Double(px) / s), 1)
                }
                a = Swift.max(a, (k == 0 ? StageFloor.minorAlpha : StageFloor.majorAlpha) * Float(Swift.max(mask(xz.x), mask(xz.y))))
            }
            return a
        }
        var worst: Float = 0, worstHard: Float = 0
        for xz in points {
            var px: Float = 1e-3
            var prev = StageFloor.lineStrength(atMM: xz, pixelMM: px), prevHard = hard(px, xz)
            while px < 100 {
                px *= 1.002
                let v = StageFloor.lineStrength(atMM: xz, pixelMM: px), vh = hard(px, xz)
                worst = Swift.max(worst, abs(v - prev)); worstHard = Swift.max(worstHard, abs(vh - prevHard))
                prev = v; prevHard = vh
            }
        }
        print("GRID cross-fade: the largest step at a point \(worst); RED CONTROL (a hard switch) \(worstHard)")
        XCTAssertLessThan(worst, 0.03, "★ no pop as he zooms")
        XCTAssertGreaterThan(worstHard, 0.15, "RED CONTROL: a hard switch between levels pops")
    }

    /// Lines one pixel wide at every level: on a line its full strength, a pixel and a half off it nothing of that level.
    func testTheLinesStayOnePixelWideAtEveryLevel() {
        for e in stride(from: Float(-3), through: 1, by: 0.5) {
            let px = powf(10, e)
            for lv in StageFloor.levels(pixelMM: px) where lv.strength > 0.05 {
                let s = Double(lv.sideMM)
                let on = StageFloor.lineStrength(atMM: SIMD2(7 * s, 0.37 * s), pixelMM: px)
                XCTAssertGreaterThanOrEqual(on, lv.strength - 1e-4, "on a \(lv.sideMM) mm line")
                let off = 1.5 * Double(px)
                // a point 1.5 px from this level's line and away from every finer line's middle: no more than finer levels draw
                let finer = StageFloor.levels(pixelMM: px).filter { $0.sideMM < lv.sideMM }.map(\.strength).max() ?? 0
                let near = StageFloor.lineStrength(atMM: SIMD2(7 * s + off, 0.37 * s), pixelMM: px)
                XCTAssertLessThanOrEqual(near, Swift.max(finer, 0) + 1e-4, "★ \(lv.sideMM) mm lines: one pixel wide")
            }
        }
    }
}
