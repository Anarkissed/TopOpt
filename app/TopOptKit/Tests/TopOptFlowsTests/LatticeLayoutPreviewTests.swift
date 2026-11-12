// LatticeLayoutPreviewTests — the new engine's preview (the lattice rebuild, stage E; his blitz 2026-11-12, the reviewer's go
// 20:21Z) behind "New engine (test)":
//   * the switch is OFF by default (off, the page is today's: the full suite is the proof of that);
//   * P7: the bars are ONE buffer — his stand's 37,233 bars are 1.2 MB, far past Metal's 4 KB inline limit (his 11-11 crash);
//     the only inline bytes are one fixed frame (RED CONTROL: the bars inline would be 290 times the limit);
//   * the pass packs a bar's width as its radius;
//   * the bars DRAW (a frame with them is not the frame without), and taking them away gives today's frame back exactly;
//   * the page's settings for core: two-line struts always, its face rows as regions (his pad's Group C, faces 3 and 5).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeLayoutPreviewTests: XCTestCase {

    func testTheSwitchIsOffByDefault() throws {
        let suite = "LatticeLayoutPreviewTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(s.newEngineTest, "★ New engine (test) is OFF until he turns it on")
        s.newEngineTest = true
        XCTAssertTrue(AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).newEngineTest, "it is remembered")
    }

    func testPackHalvesTheWidthAndKeepsTheEnds() {
        let p = LatticeLayoutBarsPass.pack([0, 0, 0, 1, 2, 3, 0.9, 4, 5, 6, 7, 8, 9, 1.2])
        XCTAssertEqual(p, [SIMD4(0, 0, 0, 0.45), SIMD4(1, 2, 3, 0), SIMD4(4, 5, 6, 0.6), SIMD4(7, 8, 9, 0)])
    }

    /// ★ P7 (18c0b0e0): his stand's 37,233 bars in ONE buffer; the only inline bytes are a fixed frame under 4 KB.
    func testTheBarsAreOneBufferAndTheInlineBytesAreFixed() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pass = try LatticeLayoutBarsPass(device: device)
        let n = 37_233
        pass.upload(.init(token: 1, bars: Self.grid(n)))
        XCTAssertEqual(pass.count, n)
        XCTAssertEqual(pass.buffer?.length, n * 2 * MemoryLayout<SIMD4<Float>>.stride, "★ every bar in one buffer")
        XCTAssertLessThan(MemoryLayout<LatticeLayoutBarsPass.Frame>.stride, 4096, "★ the only inline bytes: one fixed frame")
        XCTAssertGreaterThan(n * 2 * MemoryLayout<SIMD4<Float>>.stride, 4096 * 200, "RED CONTROL: inline, they'd be ~290× Metal's 4 KB")
    }

    /// ★ The bars draw, inside a see-through cube; taking them away gives today's frame back, byte for byte.
    func testTheBarsDrawAndOffIsTodaysFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")") }
        r.setMesh(Self.cubeMesh(20))
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.5)
        r.setBodyAlpha(0.2)
        let clear = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let today = try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false))
        XCTAssertFalse(r.applyLayoutBars(nil, device: device), "no bars, no pass: nothing to redraw")
        XCTAssertEqual(try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false)), today,
                       "★ OFF: the frame is today's")
        XCTAssertTrue(r.applyLayoutBars(.init(token: 7, bars: Self.grid(400, pitch: 2, from: -8)), device: device))
        XCTAssertTrue(r.layoutBarsInFrame, "premise: the bars are in the frame")
        let withBars = try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false))
        let changed = zip(withBars, today).filter { $0 != $1 }.count
        print("NEW-ENGINE bars drawn: \(changed / 4) pixels differ")
        XCTAssertGreaterThan(changed / 4, 2_000, "★ the bars are drawn")
        XCTAssertTrue(r.applyLayoutBars(nil, device: device))
        XCTAssertEqual(try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false)), today,
                       "★ taken away: today's frame again")
    }

    /// ★ The page's settings for core: two-line struts; his pad's Group C face rows (faces 3 and 5) as two regions.
    func testTheSettingsReadThePagesFaceRows() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let bare = LatticeLayoutPreview.settings(p)
        XCTAssertEqual(bare.minStrutLines, 2, "★ two-line struts (the reviewer's ruling 11-12)")
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let s = LatticeLayoutPreview.settings(p)
        print("NEW-ENGINE settings on his pad: \(s.regions.map { "\($0.faces) \($0.noLattice ? "no lattice" : "lattice") \($0.depthMM) mm" })")
        XCTAssertEqual(s.minStrutLines, 2)
        XCTAssertEqual(Set(s.regions.filter { !$0.noLattice }.flatMap(\.faces)), [3, 5], "★ Group C's two face rows")
        XCTAssertEqual(Set(s.regions.filter { !$0.noLattice }.map(\.depthMM)), [25], "★ each with its face row's depth (his Group C: 25 mm)")
        XCTAssertFalse(s.allLattice, "a face asks for lattice: All solid with regions")
    }

    // MARK: fixtures

    /// `n` bars on a grid: a 0.8 mm bar along x from each point.
    static func grid(_ n: Int, pitch: Float = 1, from: Float = 0) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(7 * n)
        let side = Int(ceil(cbrt(Double(n))))
        for i in 0..<n {
            let x = from + Float(i % side) * pitch, y = from + Float(i / side % side) * pitch, z = from + Float(i / (side * side)) * pitch
            out += [x, y, z, x + 0.8 * pitch, y, z, 0.25 * pitch]
        }
        return out
    }

    /// A closed cube of side `s`, centred on the origin, one face id per side.
    static func cubeMesh(_ s: Float) -> ViewerMesh {
        let h = s / 2
        let c: [SIMD3<Float>] = [[-h, -h, -h], [h, -h, -h], [h, h, -h], [-h, h, -h], [-h, -h, h], [h, -h, h], [h, h, h], [-h, h, h]]
        let quads: [[Int]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
        var v: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        for (f, q) in quads.enumerated() {
            let base = Int32(v.count / 3)
            for k in q { v += [c[k].x, c[k].y, c[k].z] }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            fid += [Int32(f), Int32(f)]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fid, faceGeometry: [])
    }
}
#endif
