// FlexibleFEPassTests — the lattice pass pulls every sample back through the squish sim's field
// (task 2026-09-29-flexible-screens, round 5 batch G, §5). GPU tests, each with a RED control:
//   * the GPU's inverse (flx_pullback_probe) inverts the forward map, and the Swift twin matches
//     it — RED: one fixed-point iteration;
//   * his project: the lattice and the ghost move by the SAME field (the GPU's pull-back of a
//     heat-plane vertex moved by the mesh's displacement lands on it) — RED: the column dent;
//   * the uniform block echoes feO / feN / feK by name — RED: two fields swapped on the Swift side;
//   * at rest the FE mode is the rest lattice, pixel for pixel — RED: the field applied at rest;
//   * the squish probe (the march's own field) matches the Swift twin through the field — RED:
//     the twin at half the squish.
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleFEPassTests: XCTestCase {

    typealias Fx = FlexibleLatticeFixtures

    /// A smooth synthetic squish over the fixtures' 40 × 40 × 20 box (2 mm nodes): the top sinks
    /// 3 mm in a dome, the sides bulge.
    static func boxField() -> FlexibleFEField {
        let nx = 21, ny = 21, nz = 11
        var u: [SIMD3<Float>] = []
        for c in 0..<nz { for b in 0..<ny { for a in 0..<nx {
            let p = SIMD3<Float>(Float(a), Float(b), Float(c)) * 2
            let dome = 1 - 0.3 * ((p.x - 20) * (p.x - 20) + (p.y - 20) * (p.y - 20)) / 800
            let bulge = 0.3 * sin(.pi * p.z / 20)
            u.append(SIMD3(bulge * (p.x - 20) / 20, bulge * (p.y - 20) / 20, -3 * (p.z / 20) * dome))
        } } }
        return FlexibleFEField(simID: "group-1", generation: 1, nx: nx, ny: ny, nz: nz, origin: .zero, spacing: 2, u: u)
    }

    /// The pass with the box lattice and `f` bound (the loop's swap at a cycle's start).
    static func pass(_ f: FlexibleFEField, device: MTLDevice) throws -> FlexibleLatticePass {
        let pass = try FlexibleLatticePass(device: device)
        var l = Fx.layer(Fx.boxInputs(.gyroid), token: 1)
        l.fe = [f]; l.feMesh = [[]]; l.feSequence = [0]; l.feToken = 11
        pass.upload(l)
        pass.uploadFE(l)
        pass.bindFE(0)
        return pass
    }

    // MARK: the inverse

    func testPullbackInvertsTheForwardMap() async throws {
        let device = try Fx.device()
        // a REAL field: C1's pad (bare), the top pressed, the bottom resting
        let pad = try await FlexibleSquishFixture.pad(self, finish: "none")
        let f = try XCTUnwrap(pad.squish["group-1"]?.field)
        let pass = try Self.pass(f, device: device)
        XCTAssertTrue(pass.feActive)
        let ref = pass.feFields[0]   // the field AS THE GPU READS IT (half-rounded)
        let s = Float(FlexibleShownValues.cappedExaggeration(rule: 10, maxSafeScale: f.maxSafeScale))
        var seed: UInt64 = 0x51ED
        func next() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }
        let p0s = (0..<2000).map { _ in SIMD3<Float>(1 + 98 * next(), 1 + 98 * next(), 1 + 18 * next()) }
        let xs = p0s.map { ref.forward($0, s) }
        let gpu = try XCTUnwrap(pass.probePullback(xs, squish: s))
        var worst: Float = 0, twin: Float = 0
        for i in xs.indices {
            worst = max(worst, simd_distance(SIMD3(gpu[i].x, gpu[i].y, gpu[i].z), p0s[i]))
            twin = max(twin, simd_distance(SIMD3(gpu[i].x, gpu[i].y, gpu[i].z), ref.pullback(xs[i], s)))
        }
        print("FLEX-G PULLBACK at ×\(s) (gmax \(f.gmax)): GPU vs the rest point \(worst) mm · GPU vs the Swift twin \(twin) mm · step scale \(gpu[0].w)")
        XCTAssertLessThanOrEqual(worst, 0.05 * max(1, s))
        XCTAssertLessThanOrEqual(twin, 0.01)
        XCTAssertEqual(gpu[0].w, max(0.2, 1 - s * Float(f.gmax)), accuracy: 1e-3, "a rest step × (1 − s·gmax)")
        // ★ RED CONTROL: one fixed-point iteration is not enough where the field moves most
        pass.controlFEIterations = 1
        let one = try XCTUnwrap(pass.probePullback(xs, squish: s))
        let worstOne = xs.indices.map { simd_distance(SIMD3(one[$0].x, one[$0].y, one[$0].z), p0s[$0]) }.max() ?? 0
        print("FLEX-G PULLBACK control (1 iteration): \(worstOne) mm")
        XCTAssertGreaterThan(worstOne, 0.2, "control: one iteration misses in the deepest zone")
    }

    // MARK: the lattice and the ghost move together

    func testLatticeAndGhostMoveTogether() async throws {
        let device = try Fx.device()
        let (_, m) = try await FlexibleSquishFixture.his(self)
        let info = try XCTUnwrap(m.sceneInfo)
        let h = FlexibleFE.spacing(sceneNX: info.nx, ny: info.ny, nz: info.nz, spacing: info.spacing)
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m, maxEdgeMM: h))
        let f = try XCTUnwrap(m.squish["group-1"]?.field)
        let g = try XCTUnwrap(m.lattice)
        let pass = try Self.pass(f, device: device)
        let s = Float(FlexibleShownValues.cappedExaggeration(rule: 10, maxSafeScale: f.maxSafeScale))
        let mesh = f.meshDisplacements(positions: o.mesh.flat.positions)
        let column = o.displacements(depths: g.columnDepths, stacks: m.stacks, partUVT: m.geometry.mapValues(\.partUVT))
        for face in [5, 3] {
            let k = FlexFaceKey(region: face, rotation: 0)
            let st = try XCTUnwrap(m.stacks[k])
            let start = try XCTUnwrap(o.flatStart[k])
            let vs = Array(stride(from: start, to: start + st.columns.count * 6, by: 5))
            let rest = vs.map { v in SIMD3<Float>(o.mesh.flat.positions[3 * v], o.mesh.flat.positions[3 * v + 1], o.mesh.flat.positions[3 * v + 2]) }
            func moved(_ d: [Float]) -> [SIMD3<Float>] { zip(vs, rest).map { v, p in p + s * SIMD3(d[3 * v], d[3 * v + 1], d[3 * v + 2]) } }
            let back = try XCTUnwrap(pass.probePullback(moved(mesh), squish: s))
            let worst = rest.indices.map { simd_distance(SIMD3(back[$0].x, back[$0].y, back[$0].z), rest[$0]) }.max() ?? 0
            // ★ RED CONTROL: the ghost moved by the column dent, the walls by the field
            let backC = try XCTUnwrap(pass.probePullback(moved(column), squish: s))
            let worstC = rest.indices.map { simd_distance(SIMD3(backC[$0].x, backC[$0].y, backC[$0].z), rest[$0]) }.max() ?? 0
            print("FLEX-G TOGETHER face \(face) at ×\(s): \(vs.count) heat-plane vertices · the walls' pull-back lands \(worst) mm from the ghost's rest point · the column dent: \(worstC) mm")
            XCTAssertLessThanOrEqual(worst, 0.05, "face \(face): the lattice and the ghost move by one field")
            XCTAssertGreaterThan(worstC, 0.5, "control: the column dent tears the side (face \(face))")
        }
    }

    // MARK: the uniform block

    func testUniformLayoutEchoIncludesTheFEBlock() throws {
        let pass = try FlexibleLatticePass(device: try Fx.device())
        var u = FlexibleLatticePass.Uniforms()
        u.feO = SIMD4(1, 2, 3, 4); u.feN = SIMD4(5, 6, 7, 8); u.feK = SIMD4(9, 10, 11, 12); u.tail = SIMD4(13, 14, 15, 16)
        let n = MemoryLayout<FlexibleLatticePass.Uniforms>.stride / 16
        let echo = try XCTUnwrap(pass.echo(u, frame: false, count: n))
        XCTAssertEqual(Array(echo.suffix(4)), [u.feO, u.feN, u.feK, u.tail], "feO / feN / feK by NAME, before the tail")
        // ★ RED CONTROL: feN and feK swapped on the Swift side do not echo back by name
        var s = FlexibleLatticePass.Uniforms()
        s.feO = u.feO; s.feN = u.feK; s.feK = u.feN; s.tail = u.tail
        let bad = try XCTUnwrap(pass.echo(s, frame: false, count: n))
        XCTAssertNotEqual(Array(bad.suffix(4)), [u.feO, u.feN, u.feK, u.tail], "control: a swap is seen")
    }

    // MARK: at rest

    func testRestIsBitIdentical() throws {
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        r.setVertexTints(Fx.xrayTints(box, ghost: nil, dent: nil))
        r.setBodyAlpha(0)
        let inputs = Fx.boxInputs(.gyroid)
        r.applyFlexibleLattice(Fx.layer(inputs, token: 1), device: device)
        r.setFlexScale(0)
        let column = try XCTUnwrap(r.renderOffscreen(size: 320, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)))
        var l = Fx.layer(inputs, token: 1)
        l.fe = [Self.boxField()]; l.feMesh = [[]]; l.feSequence = [0]; l.feToken = 5
        r.applyFlexibleLattice(l, device: device)
        let pass = try XCTUnwrap(r.flexibleLattice)
        pass.bindFE(0)
        XCTAssertTrue(pass.feActive)
        let fe = try XCTUnwrap(r.renderOffscreen(size: 320, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)))
        let d = Fx.differing(column, fe)
        print("FLEX-G REST: FE mode at s = 0 vs the column mode at s = 0: \(d.differ) of \(d.of) pixels differ")
        XCTAssertEqual(d.differ, 0, "at rest the FE mode is the rest lattice, pixel for pixel")
        // ★ RED CONTROL: the field applied at rest (a pull-back that ran even at s = 0)
        pass.controlSquishOverride = 1
        let moved = try XCTUnwrap(r.renderOffscreen(size: 320, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)))
        pass.controlSquishOverride = nil
        let dm = Fx.differing(column, moved)
        print("FLEX-G REST control (the field applied): \(dm.differ) pixels differ")
        XCTAssertGreaterThan(dm.differ, 100, "control: a field applied at rest moves the walls")
    }

    // MARK: the march's own field vs the Swift twin

    func testSquishProbeMatchesTheSwiftPullbackThroughTheFEField() throws {
        let pass = try Self.pass(Self.boxField(), device: try Fx.device())
        let f = try XCTUnwrap(pass.referenceInputs)
        let fe = pass.feFields[0]
        let pts = Fx.probePoints(400)
        let s: Float = 1
        let gpu = try XCTUnwrap(pass.probeSquished(pts, squish: s))
        // ★ TWO PARTS, EACH TO ITS OWN BOUND: the pull-back (the hardware filter's fixed-point
        // weights leave a few µm between the GPU and the twin — ≤ 0.01 mm, as the design allows),
        // then the lattice AT the GPU's own rest point (the column path's 5 µm parity). The whole
        // chain is not held to 5 µm: the gyroid's distance estimate is steep near its sheets and
        // amplifies those µm.
        let back = try XCTUnwrap(pass.probePullback(pts, squish: s))
        var worst: Float = 0, pull: Float = 0, chain: Float = 0, moved = 0, half: Float = 0
        for (i, p) in pts.enumerated() {
            let p0 = SIMD3(back[i].x, back[i].y, back[i].z)
            pull = max(pull, simd_distance(p0, fe.pullback(p, s)))
            worst = max(worst, abs(gpu[i] - FlexibleLatticeField.lattice(at: p0, f)))
            let ref = FlexibleSquishField.lattice(at: p, f, faces: [], squish: s, fe: fe)
            chain = max(chain, abs(gpu[i] - ref))
            if abs(ref - FlexibleLatticeField.lattice(at: p, f)) > 1e-3 { moved += 1 }
            half = max(half, abs(gpu[i] - FlexibleSquishField.lattice(at: p, f, faces: [], squish: s / 2, fe: fe)))
        }
        print("FLEX-G SQUISH-PROBE (FE): the pull-back GPU vs twin \(pull) mm · the lattice at the GPU's rest point \(worst) mm · the whole chain \(chain) mm over \(pts.count) points (\(moved) moved) · control at s/2 \(half)")
        XCTAssertLessThanOrEqual(pull, 0.01)
        XCTAssertLessThanOrEqual(worst, FlexibleLatticePassTests.parityMM)
        XCTAssertGreaterThan(moved, 20)
        XCTAssertGreaterThan(half, 0.1, "control: the probe sees the squish through the field")
    }
}
#endif
