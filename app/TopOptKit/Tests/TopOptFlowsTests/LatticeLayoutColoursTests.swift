// LatticeLayoutColoursTests — ★ Install 3 (his 11-17 "Implement it as soon as possible"; the old preview retired where the part
// has its model file, every view kept): the new engine's bars wear the old preview's colour key. On core's own 10 mm STEP cube,
// through the app's own LatticeLayoutSession:
//   (1) the bridge carries each laid cell (region, wall, frame, cube) and each bar's cell, aligned; the cell under each bar's
//       middle is found, and it is that bar's own cell size;
//   (2) lightness = material: by stress, the thicker struts are the deeper colour, the thinnest the palest; one density is one
//       lightness;
//   (3) a skin bar (Finish Skin) is the rim blue; grade to shape draws its band's bars toward the grade teal, and the bars past
//       the band are not;
//   (4) the stress view with the lattice paints the stress ramp: the stressed end hot, the quiet end cool;
//   (5) the colours reach the frame: all interior is today's frame byte for byte, another colour changes it;
//   RED CONTROL `controlOneColour`: every bar the one interior colour (before Install 3).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeLayoutColoursTests: XCTestCase {

    override func setUp() { LatticeLayoutColours.controlOneColour = false }
    override func tearDown() { LatticeLayoutColours.controlOneColour = false }

    static var cube: String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core/tests/fixtures/step/cube.step").path
    }

    func box() throws -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let m = try TopOptKit.importMesh(path: Self.cube)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in stride(from: 0, to: m.vertices.count, by: 3) {
            let v = SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2])
            lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        return (lo, hi)
    }

    /// The cube's top face (+z).
    func topFace() throws -> Int32 {
        let m = try TopOptKit.importMesh(path: Self.cube)
        for t in 0..<(m.indices.count / 3) {
            let v = (0..<3).map { k -> SIMD3<Float> in
                let i = Int(m.indices[t * 3 + k]) * 3
                return SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2])
            }
            if simd_normalize(simd_cross(v[1] - v[0], v[2] - v[0])).z > 0.99 { return m.faceIDs[t] }
        }
        throw XCTSkip("no top face")
    }

    /// A stress ramp along x: 0 MPa at the low side, 100 at the high one (LatticeLayoutInstall2BridgeTests').
    func ramp(_ b: (lo: SIMD3<Float>, hi: SIMD3<Float>)) -> LatticeDemandField {
        let spacing = 0.5, pad = 1.0
        let origin = SIMD3<Double>(Double(b.lo.x) - pad, Double(b.lo.y) - pad, Double(b.lo.z) - pad)
        let size = SIMD3<Double>(Double(b.hi.x - b.lo.x), Double(b.hi.y - b.lo.y), Double(b.hi.z - b.lo.z)) + 2 * pad
        let n = SIMD3<Int>(Int((size.x / spacing).rounded(.up)), Int((size.y / spacing).rounded(.up)), Int((size.z / spacing).rounded(.up)))
        var mpa = [Float](repeating: 0, count: n.x * n.y * n.z)
        for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x {
            let x = origin.x + (Double(i) + 0.5) * spacing
            mpa[(k * n.y + j) * n.x + i] = Float(100 * max(0, min(1, (x - Double(b.lo.x)) / Double(b.hi.x - b.lo.x))))
        } } }
        return LatticeDemandField(vonMises: mpa, nx: n.x, ny: n.y, nz: n.z, origin: origin, spacingMM: spacing,
                                  provenance: .solidSim(date: Date(), resolution: 64))
    }

    static func rgb(_ c: RGBAColor) -> SIMD3<Float> { SIMD3(Float(c.r), Float(c.g), Float(c.b)) }
    static func near(_ a: SIMD4<Float>, _ b: SIMD3<Float>) -> Float { simd_length(SIMD3(a.x, a.y, a.z) - b) }
    /// Whether `c` lies on the ramp from the pale end to `hue` (the old key: lightness inside one hue).
    static func onRamp(_ c: SIMD4<Float>, _ hue: SIMD3<Float>) -> Bool {
        let pale = rgb(LatticeStructureColour.pale)
        let d = SIMD3(c.x, c.y, c.z) - pale, h = hue - pale
        guard simd_length(d) > 1e-6 else { return false }
        return simd_dot(simd_normalize(d), simd_normalize(h)) > 0.9999
    }
    static func mid(_ l: LatticeLayoutColours.Laid, _ i: Int) -> SIMD3<Float> {
        let k = 7 * i
        return (SIMD3(l.bars[k], l.bars[k + 1], l.bars[k + 2]) + SIMD3(l.bars[k + 3], l.bars[k + 4], l.bars[k + 5])) / 2
    }

    // MARK: (1)(2)(4) by stress, on the whole cube

    func testTheBarsWearTheOldKeyByMaterialAndByStress() async throws {
        let b = try box()
        let field = ramp(b)
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.beadMM = 0.2; s.minStrutLines = 1
        s.byStress = true; s.dialLight = 0.2; s.dialHeavy = 0.9; s.referenceMPa = 100
        try await session.setDemand(mpa: field.vonMises, nx: field.nx, ny: field.ny, nz: field.nz, origin: field.origin,
                                    spacingMM: field.spacingMM)
        let r = try await session.lay(s)
        let laid = LatticeLayoutColours.Laid(r, token: 1)
        // (1) aligned
        XCTAssertGreaterThan(laid.barCount, 0, "premise: bars")
        XCTAssertEqual(laid.barCell.count, laid.barCount, "★ one cell size per bar")
        XCTAssertEqual(laid.cellCount, r.cells, "premise: cell_info per cell")
        XCTAssertEqual(laid.cellRegion.count, laid.cellCount, "★ one region per cell")
        XCTAssertEqual(laid.cellWall.count, laid.cellCount)
        XCTAssertEqual(laid.cellFrame.count, laid.cellCount)
        XCTAssertEqual(laid.cellLo.count, 3 * laid.cellCount, "★ one cube per cell")
        let look = LatticeLayoutColours.CellLookup(laid)
        var found = 0, same = 0
        for i in 0..<laid.barCount {
            guard let c = look.cell(at: Self.mid(laid, i), tol: 1e-3) else { continue }
            found += 1
            if abs(laid.cellInfo[5 * c] - laid.barCell[i]) < 1e-3 { same += 1 }
        }
        print("COLOURS cube: \(laid.barCount) bars, \(laid.cellCount) cells, \(laid.cells(\.frames)) frames; middles in a cell \(found), its own size \(same)")
        XCTAssertEqual(found, laid.barCount, "★ every bar's middle lies in a laid cell")
        XCTAssertEqual(same, laid.barCount, "★ and that cell is the bar's own size")

        // (2) lightness = material
        let type = LatticeType.named("octet")
        let rho = LatticeLayoutColours.densities(laid, type: type)
        let colours = LatticeLayoutColours.colours(laid, type: type, grade: false)
        let interior = Self.rgb(LatticeStructureColour.interior), pale = Self.rgb(LatticeStructureColour.pale)
        let thick = try XCTUnwrap(rho.indices.max { rho[$0] < rho[$1] }), thin = try XCTUnwrap(rho.indices.min { rho[$0] < rho[$1] })
        XCTAssertGreaterThan(rho[thick], rho[thin] * 1.2, "premise: by stress, the struts differ")
        XCTAssertLessThan(Self.near(colours[thick], interior), 1e-3, "★ the thickest strut is the full interior hue")
        XCTAssertLessThan(Self.near(colours[thin], simd_mix(pale, interior, SIMD3(repeating: 0.25))), 1e-3,
                          "★ the thinnest is the pale end (the old 0.25)")
        // (4) the stress view
        let hot = LatticeLayoutColours.colours(laid, type: type, grade: false, stress: .init(field: field))
        var cool: [Float] = [], warm: [Float] = []
        let cx = (b.lo.x + b.hi.x) / 2
        for i in 0..<laid.barCount {
            let m = Self.mid(laid, i)
            if m.x < cx - 2 { cool.append(hot[i].x - hot[i].z) } else if m.x > cx + 2 { warm.append(hot[i].x - hot[i].z) }
        }
        func mean(_ v: [Float]) -> Float { v.reduce(0, +) / Float(max(1, v.count)) }
        print("COLOURS stress: red-minus-blue quiet \(mean(cool)) stressed \(mean(warm))")
        XCTAssertGreaterThan(mean(warm), mean(cool) + 0.3, "★ the stressed end hot, the quiet end cool")
        // RED CONTROL
        LatticeLayoutColours.controlOneColour = true
        let one = LatticeLayoutColours.colours(laid, type: type, grade: false)
        XCTAssertEqual(Set(one.map { "\($0)" }).count, 1, "RED CONTROL: before Install 3, one colour")
    }

    // MARK: (3) the skin and the grade band

    func testASkinBarIsTheRimBlueAndTheGradeBandLeansTeal() async throws {
        let top = try topFace()
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        let type = LatticeType.named("octet")
        let rim = Self.rgb(LatticeStructureColour.rim), interior = Self.rgb(LatticeStructureColour.interior)
        let teal = Self.rgb(LatticeStructureColour.grade)

        // the skin
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.beadMM = 0.2; s.minStrutLines = 1
        s.skin = true
        let skinned = LatticeLayoutColours.Laid(try await session.lay(s), token: 1)
        let skin = (0..<skinned.barCount).filter { LatticeLayoutColours.isSkin(skinned.barFlags[$0]) }
        let sc = LatticeLayoutColours.colours(skinned, type: type, grade: false)
        print("COLOURS skin: \(skin.count) of \(skinned.barCount) bars")
        XCTAssertFalse(skin.isEmpty, "premise: Finish Skin lays skin bars")
        for i in skin { XCTAssertTrue(Self.onRamp(sc[i], rim), "★ a skin bar is the rim blue (at its own lightness)") }
        for i in (0..<skinned.barCount) where !skin.contains(i) {
            XCTAssertTrue(Self.onRamp(sc[i], interior), "and a fill bar the interior violet")
        }

        // the grade band: a Lattice region under the top face, cells shrinking toward its outline
        var g = LatticeLayoutSession.Settings()
        g.algorithm = "stepped"
        g.cellMaxMM = 4; g.cellMinMM = 0
        g.beadMM = 0.2; g.minStrutLines = 1
        g.gradeToShape = true; g.bandMM = 3
        g.regions = [.init(id: 1, faces: [top], depthMM: 5, expandMM: 0)]
        let graded = LatticeLayoutColours.Laid(try await session.lay(g), token: 2)
        let look = LatticeLayoutColours.CellLookup(graded)
        var inBand: [Int] = [], past: [Int] = []
        for i in 0..<graded.barCount {
            guard !LatticeLayoutColours.isSkin(graded.barFlags[i]), let c = look.cell(at: Self.mid(graded, i)) else { continue }
            if graded.cellInfo[5 * c + 2] < 0.5 { inBand.append(i) } else if graded.cellInfo[5 * c + 2] >= 1 { past.append(i) }
        }
        let gc = LatticeLayoutColours.colours(graded, type: type, grade: true, lookup: look)
        let off = LatticeLayoutColours.colours(graded, type: type, grade: false)
        print("COLOURS grade: \(graded.barCount) bars, \(inBand.count) deep in the band, \(past.count) past it")
        XCTAssertFalse(inBand.isEmpty, "premise: grade to shape lays a band")
        XCTAssertFalse(past.isEmpty, "premise: and cells past it")
        for i in inBand { XCTAssertLessThan(Self.near(gc[i], teal), Self.near(off[i], teal), "★ a band bar leans teal") }
        for i in past { XCTAssertEqual(gc[i], off[i], "★ a bar past the band is untouched") }
    }

    // MARK: (5) the frame

    func testTheColoursReachTheFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")") }
        r.setMesh(LatticeLayoutPreviewTests.cubeMesh(20))
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.5)
        r.setBodyAlpha(0.2)
        let clear = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let bars = LatticeLayoutPreviewTests.grid(400, pitch: 2, from: -8)
        let n = bars.count / 7
        XCTAssertTrue(r.applyLayoutBars(.init(token: 7, bars: bars), device: device))
        let one = try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false))
        let c = LatticeStructureColour.interior
        XCTAssertTrue(r.applyLayoutBars(.init(token: 7, bars: bars, colours: Array(repeating: SIMD4(Float(c.r), Float(c.g), Float(c.b), 1), count: n),
                                              colourKey: 1), device: device), "a new colouring redraws")
        XCTAssertEqual(try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false)), one,
                       "★ every bar the interior colour, per bar: the one-colour frame, byte for byte")
        XCTAssertTrue(r.applyLayoutBars(.init(token: 7, bars: bars, colours: Array(repeating: SIMD4(1, 0.1, 0.1, 1), count: n),
                                              colourKey: 2), device: device))
        let red = try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false))
        let changed = zip(red, one).filter { $0 != $1 }.count / 4
        print("COLOURS frame: \(changed) pixels change colour")
        XCTAssertGreaterThan(changed, 2_000, "★ the bars' own colours reach the frame")
    }
}

private extension LatticeLayoutColours.Laid {
    func cells(_ k: KeyPath<Self, [Float]>) -> Int { self[keyPath: k].count / 12 }
}
#endif
