// Notes24StandHostedTests — ★ his words 2026-11-23, after release 16, on HIS 2040 Extrusion Stand (read in place, never copied):
//   (a) "start an animation by removing the walls, allowing that animation to run for 2-3 seconds and THEN starting the growing
//       animation … the recording of the vine growth … at about 10-12frames per second";
//   (b) "Make sure that looking INTO the part actually looks shaded and as if you're looking INTO A PART."
// His front face latticed, Organic Grown, the solid view, laid through the preview as the Lattice page lays it (Print-accurate
// preview as the host has it), hosted at his 13″ landscape and 11″ portrait windows. The first lay has no map before it: the
// part fades to X-ray, then the replay grows inside it. The second (11″ portrait) is handed the first one's map as the engine
// will make it ahead (362's gridAhead): its walls dissolve away first, then the replay grows inside the opened part, and it
// lands opened by that very map. Pictures (VIEWER_SHOT_DIR) of each stage, and of the landed lattice with the inside's light
// off (the picture before) and on.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes24StandHostedTests: XCTestCase {

    override func tearDown() {
        LatticeLayoutPreview.mapAheadForTesting = nil
        LatticeInsideShade.controlOff = false
        super.tearDown()
    }

    func testHisStandWallsFirstThenTheReplayThenTheLandedLatticeSeenInside() throws {
        let path = HisStandChipsHostedTests.standPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("his 2040 Extrusion Stand STEP is not on this Mac (\(path))")
        }
        let p = try FlexiblePressFixtures.project(path: path, name: "2040 Extrusion Stand")
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = false
        p.lattice.enabled = true
        let mesh = try XCTUnwrap(p.viewerMesh)
        guard let front = Self.largestFlatFace(mesh) else { XCTFail("premise: his stand's front face"); return }
        guard let gid: UUID = HisStandNotes1109HostedTests.group(p, mesh, [front.id]) else { XCTFail("the front face's group"); return }
        p.lattice.groupRoles[gid] = LatticeGroupRole.include
        p.writeGroupDepthMM(gid, mm: 12)
        var look = LatticeOrganicLook(); look.mode = .grown; look.lookPercent = 20   // (dense enough that each lay takes a while)
        p.lattice.organicLook = look
        let st = try Self.stress(p)
        // looking into the front face, from above it (his stand's up is its model's +z) and a little aside
        let up = SIMD3<Float>(0, 0, 1)
        let d = simd_normalize(front.normal + up * 0.7 + simd_normalize(simd_cross(front.normal, up)) * 0.4)
        let shotDir = ProcessInfo.processInfo.environment["VIEWER_SHOT_DIR"]
        var firstMap: LatticeLayoutSolidGrid?
        for (name, size) in [("13L", AppBuildHost.landscape13), ("11P", CGSize(width: 820, height: 1180))] {
            let preview = LatticeLayoutPreview()
            defer { preview.clear() }
            if name == "11P", let m = firstMap { LatticeLayoutPreview.mapAheadForTesting = { _ in m } }
            let h = AppBuildHost(LatticeGrowthHostedTests.Stage(preview: preview, mesh: mesh, bodyAlpha: 1), size: size, test: self)
            h.pump(1)
            let r = try renderer(h)
            let (w, hh) = (Int(size.width), Int(size.height))
            func aim() { r.camera.setOrientation(azimuth: atan2(d.x, d.z), elevation: asin(Swift.min(d.y, 0.95))) }
            func shoot(_ what: String) throws {
                aim()
                guard let dir = shotDir,
                      let f = r.renderOffscreen(width: w, height: hh, clear: MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1),
                                                stage: false)
                else { return }
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try LatticeLayoutStandProbe.png(f, w, hh, to: (dir as NSString).appendingPathComponent("stand-\(name)-\(what).png"))
            }
            preview.update(project: p, on: true, solid: true, stress: st)
            XCTAssertTrue(preview.laying, "\(name): premise: laying")
            var shot = Set<String>(), sawWalls = false, sawDissolve = false, sawReplay = false, sawXray = false
            var behind = true, stepsSeen = 0, lastShown = -1
            let end = Date().addingTimeInterval(900)
            while preview.laying, Date() < end {
                h.pump(0.05)
                aim()
                guard r.renderOffscreen(width: 320, height: 240, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                                        stage: true) != nil else { continue }
                let g = preview.growth, f = r.growthFrame
                guard f.active, !g.sealed else { continue }
                if f.walls < 1 {
                    sawWalls = true
                    sawDissolve = sawDissolve || f.ownMap
                    if f.walls > 0.35, f.walls < 0.75, !shot.contains("walls") { shot.insert("walls"); try shoot("1-walls") }
                }
                sawXray = sawXray || r.growthXraysBody
                if f.shown > 0 {
                    sawReplay = true
                    behind = behind && f.shown <= g.count
                    if f.shown != lastShown { stepsSeen += 1; lastShown = f.shown }
                    if f.shown > g.count / 3, !shot.contains("growing-\(preview.layProgress?.quality == .draft ? "d" : "e")") {
                        let q = preview.layProgress?.quality == .draft ? "d" : "e"
                        shot.insert("growing-\(q)"); try shoot("2-growing-\(q == "d" ? "draft" : "exact")")
                    }
                }
            }
            XCTAssertFalse(preview.laying, "\(name): laid within 15 min")
            h.pump(LatticeGrowth.landingS + 0.8)
            print("STAND \(name): walls first \(sawWalls) (dissolved by the map ahead \(sawDissolve), X-ray \(sawXray)); "
                  + "the replay \(sawReplay), \(stepsSeen) steps seen, never ahead \(behind); \(preview.organicNumbers?.segments ?? -1) struts")
            XCTAssertTrue(sawWalls, "★ \(name): the walls first")
            XCTAssertTrue(sawReplay, "★ \(name): then the vines grow (the replay)")
            XCTAssertTrue(behind)
            if name == "11P" {
                XCTAssertTrue(sawDissolve, "★ the map made before the lay: the walls dissolve away")
                XCTAssertFalse(sawXray, "★ never X-ray with that map")
                XCTAssertEqual(preview.bars?.solid?.rg, firstMap?.rg, "★ it lands opened by that very map (no second one)")
            } else {
                XCTAssertTrue(sawXray, "the first lay, no map before it: the X-ray stand-in")
            }
            XCTAssertNotNil(preview.bars?.solid, "\(name): landed opened by its map")
            try shoot("3-landed-after")
            LatticeInsideShade.controlOff = true
            try shoot("3-landed-before")
            LatticeInsideShade.controlOff = false
            try h.picture("stand-\(name)-landed.png")
            if firstMap == nil { firstMap = preview.bars?.solid }
        }
    }

    // MARK: helpers

    /// His stand's largest flat face (by area): its id and outward normal.
    static func largestFlatFace(_ m: ViewerMesh) -> (id: Int32, normal: SIMD3<Float>)? {
        var area: [Int32: Float] = [:], normal: [Int32: SIMD3<Float>] = [:]
        for t in 0..<(m.indices.count / 3) where t < m.faceIDs.count {
            let f = m.faceIDs[t]
            guard let g = m.faceGeometry(f), g.isPlane else { continue }
            func v(_ k: Int) -> SIMD3<Float> {
                let i = Int(m.indices[3 * t + k])
                return SIMD3(m.positions[3 * i], m.positions[3 * i + 1], m.positions[3 * i + 2])
            }
            let c = simd_cross(v(1) - v(0), v(2) - v(0))
            area[f, default: 0] += 0.5 * simd_length(c)
            normal[f, default: .zero] += c
        }
        guard let best = area.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, simd_normalize(normal[best.key] ?? SIMD3(0, 0, 1)))
    }

    /// The 3D view's renderer (the largest MTKView's).
    private func renderer(_ h: AppBuildHost) throws -> MeshRenderer {
        var found: [MTKView] = []
        func walk(_ v: NSView) { if let m = v as? MTKView { found.append(m) }; v.subviews.forEach(walk) }
        walk(h.view)
        let mtk = try XCTUnwrap(found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }, "the 3D view")
        return try XCTUnwrap(mtk.delegate as? MeshRenderer, "the 3D view's renderer")
    }

    /// A compression down the stand's height over its box (PreviewSpeedStage1Tests' kind of field).
    static func stress(_ p: ProjectModel) throws -> LatticeLayoutPreview.Stress {
        let b = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let h = 3.0
        let lo = SIMD3<Double>(b.lo) - 2, size = SIMD3<Double>(b.hi - b.lo) + 4
        let n = SIMD3<Int>(Int((size.x / h).rounded(.up)) + 1, Int((size.y / h).rounded(.up)) + 1, Int((size.z / h).rounded(.up)) + 1)
        let count = n.x * n.y * n.z
        var t = [Double](repeating: 0, count: 6 * count)
        for i in 0..<count { t[6 * i + 2] = -10; t[6 * i] = -1; t[6 * i + 1] = -1 }
        let f = LatticeDemandField(vonMises: [Float](repeating: 10, count: count), stressTensor: t, nx: n.x, ny: n.y, nz: n.z,
                                   origin: lo, spacingMM: h, provenance: .solidSim(date: Date(), resolution: 64))
        return .init(key: 91, field: f, referenceMPa: 20)
    }
}
#endif
