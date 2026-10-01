// FlexibleSettingsVerifyD1Tests — the verification pass of round 4 batch D1 (task
// 2026-09-29-flexible-screens). A verifier read D1 on HIS project 0004 (headless renders, the
// page hosted in a window, clicks); each finding confirmed here carries a test that is RED on
// the code D1 left — an inline control on the old rule, and a mutation run in the handoff:
//   * BLOCKER: the selected face's rows sat below the panel on every iPad (the face list pushed
//     them down) — now an accordion card scrolled into view; measured on HIS project hosted at
//     11" / 13", both orientations, with the page's own frames;
//   * the curves drew (and took no touch) under the translucent panel / legend / player;
//   * a Stamp face's dent was a row of TEETH and its prism a sawtooth staircase;
//   * Settings and the main page showed different squishes for a Stamp face, said nowhere;
//   * Rim / Skin print as None, said only behind the (i); the finish was invisible on Settings;
//   * the stamp handle sat on the depth chip seen from above;
//   * small ones: a lattice landing flipped the Settings map to "What can be built"; Stamp
//     before the stack put a palm on the corner; the hole is 3 mm ACROSS; re-tapping Curves
//     staled the lattice; the folded legend was taller than the open one.
import XCTest
import SwiftUI
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleSettingsVerifyD1Tests: XCTestCase {

    // MARK: - a lattice landing leaves the Settings map on HIS drawing (finding 1)

    @MainActor
    func testAFreshLatticeLeavesTheSettingsMapOnHisDrawing() throws {
        // nothing in the Flexible sources flips the map to the buildable estimate any more
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let code = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("Flexible") && $0.hasSuffix(".swift") }
            .map { try FlexibleSource.code($0) }.joined()
        XCTAssertFalse(code.contains("showBuildable = true"), "no lattice on Settings: its map stays 'What you drew'")
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        let handler = try XCTUnwrap(page.range(of: ".onChange(of: FlexibleLatticePreview.freshKey(model.lattice))"))
        let body = String(page[handler.upperBound...].prefix(260))
        XCTAssertFalse(body.contains("model.tab = .face"), "a lattice landing does not switch his tab")
        // ★ RED CONTROL: the flag, once set, took the map off his drawing (and nothing reset it)
        let p = try FlexibleSquishTests.pad()
        let face = FlexibleFaceSettings(faceRegionID: 101, weightKg: 30, deepestMM: 3)
        var inp = FlexibleShownValues.Inputs(loadedFaces: [face], stacks: [p.key: p.stack], designs: [p.key: p.design],
                                             liveS: [:], checks: [:], checkStamps: [], checkStampShown: nil, showBuildable: false)
        XCTAssertEqual(FlexibleShownValues(inp, drawnLattice: nil).label, "What you drew")
        inp.showBuildable = true
        XCTAssertEqual(FlexibleShownValues(inp, drawnLattice: nil).label, "What can be built (estimate)",
                       "control: the flag the page used to set relabels the map")
    }

    // MARK: - Stamp before the face's stack: seeded when it lands, centred, fitting (finding 2)

    @MainActor
    func testStampChosenBeforeTheStackIsSeededCentredWhenItLands() async throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top, weightKg: 10, deepestMM: 3))
        let project = try FlexibleHisProject.padProject(s)
        let m = FlexibleStageModel(project: project, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        XCTAssertNil(m.stack(top), "the scene is not open: no stack yet")
        m.setShape(top, "stamp")
        let early = try XCTUnwrap(m.settings.face(top))
        XCTAssertTrue(early.isStampShape, "Stamp at once")
        XCTAssertNil(early.designStamp, "…but no stamp without the face's size and centre")
        // ★ RED CONTROL: the old seed read a missing stack as 0 × 0 — the palm, at the corner
        let lib = try XCTUnwrap(m.library)
        let old = FlexibleStamps.place(try XCTUnwrap(lib.shape("palm")), uExtentMM: 0, vExtentMM: 0, weightKg: 10)
        XCTAssertEqual(old.centreU, 0, "control: centred on the corner")
        XCTAssertGreaterThan(old.lengthMM, 0.9 * 100, "control: …and the palm does not fit the 100 mm pad")
        // the stack lands: the stamp is seeded, centred, and fits
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "the stack and the seeded stamp") {
            m.stack(top) != nil && m.settings.face(top)?.designStamp != nil
        }
        let st = try XCTUnwrap(m.stack(top))
        let p = try XCTUnwrap(m.settings.face(top)?.activeStamp)
        print("FLEX-SEED pad top \(st.uExtentMM) × \(st.vExtentMM) mm: \(m.stampName(p)) \(p.widthMM) × \(p.lengthMM) mm at (\(p.centreU), \(p.centreV)), turned \(p.rotationDeg)°")
        XCTAssertEqual(p.centreU, st.uExtentMM / 2, accuracy: 1e-6)
        XCTAssertEqual(p.centreV, st.vExtentMM / 2, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(max(p.widthMM, p.lengthMM), 0.9 * max(st.uExtentMM, st.vExtentMM), "it fits the face")
        XCTAssertNotEqual(m.stampName(p), "Palm", "the palm (80 × 95 mm) does not fit a 100 mm face")
        // ★ AND BOTH TURNS: a long stamp along a long face fits turned a quarter
        XCTAssertEqual(FlexibleStageModel.stampTurnThatFits((20, 60), uExtentMM: 70, vExtentMM: 40), 90)
        XCTAssertEqual(FlexibleStageModel.stampTurnThatFits((20, 30), uExtentMM: 70, vExtentMM: 40), 0)
        XCTAssertNil(FlexibleStageModel.stampTurnThatFits((80, 95), uExtentMM: 100, vExtentMM: 100))
        let oldFits = 20 <= 0.9 * 70 && 60 <= 0.9 * 40
        XCTAssertFalse(oldFits, "control: the old rule tried one turn only")
    }

    // MARK: - the hole is 3 mm ACROSS (finding 3)

    func testTheSkinsHolesAreThreeMillimetresAcross() throws {
        let c = FlexibleFinish.holeCentreNear(SIMD2<Float>(50, 50))
        func d(_ r: Float, radius: Float = FlexibleFinish.holeRadiusMM) -> Float {
            FlexibleFinish.holeDistance(SIMD3<Float>(c.x + r, c.y, 20), normal: SIMD3(0, 0, 1), radius: radius)
        }
        XCTAssertLessThan(d(1.2), 0, "1.2 mm from a hole's centre is inside it: the hole is 3 mm across")
        XCTAssertGreaterThan(d(1.6), 0)
        XCTAssertEqual(FlexibleFinish.holeDiameterMM, 3)
        XCTAssertEqual(FlexibleFinish.openFraction, 0.326, accuracy: 0.002, "a third of the skin open")
        // ★ RED CONTROL: holes "1.5 mm" across (the prose) would leave that point covered
        XCTAssertGreaterThan(d(1.2, radius: 0.75), 0, "control: a 1.5 mm hole does not reach 1.2 mm out")
        // the prose now says what the code draws
        let docs = FlexibleHisProject.repoRoot.appendingPathComponent("docs")
        let decisions = try String(contentsOf: docs.appendingPathComponent("design/flexibles/00-decisions.md"), encoding: .utf8)
        let row = try XCTUnwrap(decisions.components(separatedBy: "\n").first { $0.hasPrefix("| D-R4-4 |") })
        XCTAssertTrue(row.contains("3 mm holes (1.5 mm radius)"), row)
        XCTAssertFalse(row.contains("round 1.5 mm holes"))
    }

    // MARK: - Rim and Skin say, ON the row, that they print as None (findings 4 / ux)

    func testRimAndSkinSayOnTheRowThatTheyPrintAsNone() throws {
        for f in FlexibleFinish.allCases {
            let note = FlexibleRowCopy.finishPreviewOnly(f)
            XCTAssertEqual(note != nil, f == .rim || f == .skin, "\(f)")
            if let n = note { XCTAssertLessThanOrEqual(n.count, FlexibleRowCopy.maxChars, n) }
        }
        let panel = try FlexibleSource.code("FlexibleFacePanel.swift")
        XCTAssertTrue(panel.contains("if let note = FlexibleRowCopy.finishPreviewOnly(finish) {"))
        XCTAssertTrue(panel.contains("FlexWarningLine(text: note, id: \"flexible-row-finish-preview-only\")"), "a visible line, not the (i)")
        // ★ RED CONTROL (the line is true): Rim and Skin reach core exactly as None
        var s = FlexibleStageTests.settings()
        func skins(_ f: FlexibleFinish) throws -> [Bool] {
            s.finish = f.rawValue
            return try FlexibleCore.parseJobBlock(try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(s))).faces.map(\.skinOn)
        }
        XCTAssertEqual(try skins(.rim), try skins(.none), "control: Rim's job is None's")
        XCTAssertEqual(try skins(.skin), try skins(.none), "control: Skin's job is None's")
        XCTAssertNotEqual(try skins(.covered), try skins(.none))
    }

    // MARK: - the finish is a picture on its row (ux: invisible where he taps)

    #if canImport(AppKit)
    @MainActor
    func testTheFinishRowShowsAPictureOfTheChosenFinish() throws {
        func solid(_ f: FlexibleFinish) throws -> Int {
            let r = ImageRenderer(content: FlexibleFinishSwatch(finish: f).environment(\.colorScheme, .dark))
            r.scale = 4
            let img = try XCTUnwrap(r.cgImage)
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            // the solid part: textPrimary at 85 % (the hatch is textTertiary, 45 %)
            var n = 0
            for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 180 { n += 1 }
            return n
        }
        let c = try solid(.covered), sk = try solid(.skin), rim = try solid(.rim), none = try solid(.none)
        print("FLEX-SWATCH solid pixels: covered \(c) · skin \(sk) · rim \(rim) · none \(none)")
        XCTAssertGreaterThan(c, sk, "Covered is solid all over; Skin has holes")
        XCTAssertGreaterThan(sk, rim, "Skin covers more than Rim's band")
        XCTAssertGreaterThan(rim, none, "Rim has a band; None has none")
        XCTAssertEqual(none, 0, "None: lattice to the edge (the hatch alone)")
        let panel = try FlexibleSource.code("FlexibleFacePanel.swift")
        XCTAssertTrue(panel.contains("FlexibleFinishSwatch(finish: finish)"), "the panel draws it, under the chips")
        // ★ the picture and its line fit the panel; beside the chips it cut "Finish" to "Fin…"
        let content = FlexibleSettingsPanel.contentWidth   // ★ RE-PINNED (round 5, S8): the tab beside the rail
        for f in FlexibleFinish.allCases {
            let line = FlexibleRowCopy.finishPreviewOnly(f) ?? FlexibleRowCopy.finishLine(f)
            XCTAssertLessThanOrEqual(line.count, FlexibleRowCopy.maxChars, line)
            let w = FlexibleRowCopyTests.width(HStack(spacing: DS.Space.s) {
                FlexibleFinishSwatch(finish: f)
                Text(line).font(.system(size: 12, weight: .semibold))
            })
            XCTAssertLessThanOrEqual(w, content, "\(f): \(w) pt")
        }
        let chipsAndSwatch = FlexibleRowCopyTests.width(FlexRow(FlexibleRowCopy.finish, info: "") {
            FlexibleFinishSwatch(finish: .covered)
            FlexChips(options: FlexibleRowCopy.finishOptions, selection: "covered", equalWidths: false) { _ in }.fixedSize()
        })
        XCTAssertGreaterThan(chipsAndSwatch, content - 8, "control: beside the chips the picture left the row no room")
    }
    #endif

    // MARK: - re-tapping the shape already chosen changes nothing (finding 6a)

    @MainActor
    func testReTappingTheChosenShapeChangesNothing() throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top, weightKg: 10, deepestMM: 3))
        let m = FlexibleStageModel(project: try FlexibleHisProject.padProject(s), materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        let before = m.settings
        XCTAssertNil(before.face(top)?.shape, "a face that never chose")
        m.setShape(top, "curves")
        XCTAssertEqual(m.settings, before, "the chip already chosen: nothing changes")
        XCTAssertEqual(m.settings.hashValue, before.hashValue, "…so the main page's lattice stays current")
        // ★ RED CONTROL: the old write ("curves" over nil) changed the settings (a stale lattice)
        var old = before
        var f = try XCTUnwrap(old.face(top)); f.shape = "curves"; old.setFace(f)
        XCTAssertNotEqual(old, before, "control: the old tap changed the settings")
    }

    // MARK: - the stamp handle keeps clear of the depth chip (findings 6b / ux)

    @MainActor
    func testTheStampHandleKeepsClearOfTheDepthChip() async throws {
        // pure: coincident, near, far
        let chip = CGPoint(x: 400, y: 300)
        for c in [chip, CGPoint(x: 405, y: 300), CGPoint(x: 400, y: 330)] {
            let h = FlexibleFaceStampHandle.handlePoint(centre: c, chip: chip)
            XCTAssertGreaterThanOrEqual(hypot(h.x - chip.x, h.y - chip.y), 44 + 1e-6, "two 44 pt targets never meet")
        }
        let far = CGPoint(x: 500, y: 300)
        XCTAssertEqual(FlexibleFaceStampHandle.handlePoint(centre: far, chip: chip), far, "clear already: at the stamp's centre")
        // on the pad's top, seen from straight above: the stamp's centre and the chip's anchor
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top, weightKg: 10, deepestMM: 3))
        let m = try await FlexibleHisProject.openedModel(try FlexibleHisProject.padProject(s), test: self)
        m.selectedRegion = top
        m.setShape(top, "stamp")
        try await FlexibleHisProject.waitFor(30, "the stamp's grid") { m.stampFootprint(top) != nil }
        let key = try XCTUnwrap(m.key(top)), st = try XCTUnwrap(m.stacks[key]), g = try XCTUnwrap(m.geometry[key])
        let p = try XCTUnwrap(m.settings.face(top)?.activeStamp)
        let k = FlexibleShownValues(model: m).exaggeration
        let anchor = try XCTUnwrap(FlexibleDepthChips.handle(model: m, k: k)).anchor
        // the page's own projection: the camera × the settle about the part's centre (gravity down)
        let bounds = try XCTUnwrap(probe.viewerMesh).bounds
        var cam = OrbitCamera()
        cam.frame(bounds)
        cam.setOrientation(azimuth: .pi / 4, elevation: 1.5)
        let base = CameraProjection(camera: cam, viewportSize: CGSize(width: 900, height: 900))
        let settle = m.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let proj = CameraProjection(viewProjection: base.viewProjection * ViewerModelFrame.matrix(centre: bounds.center, rotation: settle),
                                    viewportSize: base.viewportSize)
        let w = g.corner + st.xAxis * p.centreU + st.yAxis * p.centreV - st.load * 0.5
        let centre = try XCTUnwrap(proj.project(SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))))
        let chipAt = try XCTUnwrap(proj.project(anchor))
        let handle = FlexibleFaceStampHandle.handlePoint(centre: centre, chip: chipAt)
        let old = hypot(centre.x - chipAt.x, centre.y - chipAt.y), now = hypot(handle.x - chipAt.x, handle.y - chipAt.y)
        print(String(format: "FLEX-HANDLE pad top from above (el 1.5): stamp centre ↔ chip %.1f pt (old handle) → handle ↔ chip %.1f pt", old, now))
        XCTAssertLessThan(old, 44, "control: from above the old handle sat on the chip")
        XCTAssertGreaterThanOrEqual(now, 44)
        let src = try FlexibleSource.code("FlexibleFaceStamp.swift")
        XCTAssertTrue(src.contains("case let q = Self.handlePoint(centre: c, chip: chip)"), "the handle is mounted there")
    }

    // MARK: - a Stamp face's dent has no teeth; its prism stands on a smooth outline (ux)

    /// The spread of the drawn dent among quad corners at ONE distance from the stamp's edge
    /// (the ellipse's first-order signed distance f / |∇f|, in bins of `rimBin` mm within ±5 mm —
    /// narrow, so the wall's own slope adds little), over the deepest shown. Teeth ⇒ corners
    /// equally far from the edge sink ¼ vs ¾.
    static let rimBin = 0.2
    @MainActor
    static func rimSpread(model m: FlexibleStageModel, region r: Int, depths: [Double?]) throws -> (spread: Double, corners: Int) {
        let key = try XCTUnwrap(m.key(r)), st = try XCTUnwrap(m.stacks[key]), g = try XCTUnwrap(m.geometry[key])
        let p = try XCTUnwrap(m.settings.face(r)?.activeStamp)
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let dents = overlay.displacements(depths: [key: depths], stacks: m.stacks, partUVT: m.geometry.mapValues(\.partUVT))
        let start = try XCTUnwrap(overlay.flatStart[key])
        let pos = overlay.mesh.flat.positions
        let th = p.rotationDeg * .pi / 180
        var bins: [Int: (lo: Double, hi: Double)] = [:]
        var corners = 0
        let deepest = depths.compactMap { $0 }.max() ?? 0
        guard deepest > 0 else { return (0, 0) }
        for v in start..<(start + st.columns.count * 6) {
            let q = SIMD3<Double>(Double(pos[3 * v]), Double(pos[3 * v + 1]), Double(pos[3 * v + 2])) - g.corner
            let u = simd_dot(q, st.xAxis) - p.centreU, w = simd_dot(q, st.yAxis) - p.centreV
            let x = u * cos(th) + w * sin(th), y = -u * sin(th) + w * cos(th)
            let ea = p.widthMM / 2, eb = p.lengthMM / 2
            let fx = (x / ea) * (x / ea) + (y / eb) * (y / eb) - 1
            let grad = (4 * x * x / (ea * ea * ea * ea) + 4 * y * y / (eb * eb * eb * eb)).squareRoot()
            guard grad > 1e-9 else { continue }
            let dist = fx / grad   // mm, signed, first order (exact on the edge)
            guard abs(dist) < 5 else { continue }
            let d = simd_length(SIMD3<Double>(Double(dents[3 * v]), Double(dents[3 * v + 1]), Double(dents[3 * v + 2])))
            let b = Int((dist / Self.rimBin).rounded(.down))
            let e = bins[b] ?? (d, d)
            bins[b] = (min(e.lo, d), max(e.hi, d))
            corners += 1
        }
        return ((bins.values.map { $0.hi - $0.lo }.max() ?? 0) / deepest, corners)
    }

    /// D1's footprint (the rule the verifier rendered): the stamp's grid at each column CENTRE,
    /// over its peak — a step one column wide.
    @MainActor
    static func d1Footprint(model m: FlexibleStageModel, region r: Int) throws -> [Double] {
        let p = try XCTUnwrap(m.settings.face(r)?.activeStamp), g = try XCTUnwrap(m.stampGrids[p.id]), st = try XCTUnwrap(m.stack(r))
        let peak = try XCTUnwrap(g.valuesMPa.max())
        return st.columns.map { c in
            let iu = Int(((c.uMM - g.originU) / g.cellMM).rounded(.down)), iv = Int(((c.vMM - g.originV) / g.cellMM).rounded(.down))
            guard iu >= 0, iv >= 0, iu < g.nu, iv < g.nv else { return 0 }
            return g.valuesMPa[iv * g.nu + iu] / peak
        }
    }

    @MainActor
    func testAStampDentHasNoTeethAndItsPrismStandsOnASmoothOutline() async throws {
        let his = try FlexibleHisProject.restore()
        defer { his.cleanup() }
        let m = try await FlexibleHisProject.openedModel(his.project, test: self)
        let a = FlexibleHisProject.topA
        m.select(a)
        m.setShape(a, "stamp")
        try await FlexibleHisProject.waitFor(30, "the stamp's grid") { m.stampFootprint(a) != nil }
        let f = try XCTUnwrap(m.settings.face(a))
        let key = try XCTUnwrap(m.key(a)), st = try XCTUnwrap(m.stacks[key]), g = try XCTUnwrap(m.geometry[key])
        // the page's own map for the face (FlexibleShownValues → the dent)
        let shown = FlexibleShownValues(model: m).values[key] ?? []
        let smooth: [Double?] = shown.map { if case .depth(let d) = $0 { return d } else { return nil } }
        let d1 = try Self.d1Footprint(model: m, region: a)
        let now = try Self.rimSpread(model: m, region: a, depths: smooth)
        let old = try Self.rimSpread(model: m, region: a, depths: d1.map { Optional($0 * f.deepestMM) })
        print(String(format: "FLEX-TEETH his top A, %@: dent spread among corners at one distance from the stamp's edge — D1's footprint %.2f of the deepest (%d corners) · smoothed %.2f (%d)",
                     m.stampName(try XCTUnwrap(f.activeStamp)), old.spread, old.corners, now.spread, now.corners))
        XCTAssertGreaterThan(old.corners, 50)
        XCTAssertGreaterThan(old.spread, 0.25, "control: D1's footprint — corners at one distance sink ¼ vs ¾: the teeth")
        XCTAssertLessThan(now.spread, 0.2, "smoothed: corners at one distance from the edge sink alike")
        // the deepest squish is still reached under the stamp
        XCTAssertEqual(smooth.compactMap { $0 }.max() ?? 0, f.deepestMM, accuracy: 1e-6)
        // ★ THE PRISM: on the ½ contour — its outline is not a staircase along the grid
        func axisAligned(_ s: FaceOffsetShell) -> (Double, Int) {
            var use: [UInt64: Int] = [:]
            var t = 0
            while t + 2 < s.indices.count {
                for e in 0..<3 {
                    let i = s.indices[t + e], j = s.indices[t + (e + 1) % 3]
                    use[i < j ? (UInt64(i) << 32 | UInt64(j)) : (UInt64(j) << 32 | UInt64(i)), default: 0] += 1
                }
                t += 3
            }
            let edges = use.filter { $0.value == 1 }.keys.map { (Int($0 >> 32), Int($0 & 0xFFFF_FFFF)) }
            let aligned = edges.filter { i, j in
                let d = simd_normalize(SIMD3<Double>(s.base[j] - s.base[i]))
                return abs(simd_dot(d, st.xAxis)) > 0.999 || abs(simd_dot(d, st.yAxis)) > 0.999
            }.count
            return (Double(aligned) / Double(max(1, edges.count)), edges.count)
        }
        let foot = try XCTUnwrap(m.prismFootprint(a))
        let contour = try XCTUnwrap(FlexibleDepthPrism.stampShell(stack: st, centres: g.centres, footprint: foot, depthMM: f.deepestMM, k: 2))
        let stairs = try XCTUnwrap(FlexibleDepthPrism.shell(stack: st, centres: g.centres, depthMM: f.deepestMM, k: 2,
                                                            columns: Set(d1.indices.filter { d1[$0] >= 0.5 })))
        let (c, cn) = axisAligned(contour), (s, sn) = axisAligned(stairs)
        print(String(format: "FLEX-PRISM-STAMP his top A: outline edges along the grid — columns (old) %.0f%% of %d · contour %.0f%% of %d",
                     s * 100, sn, c * 100, cn))
        XCTAssertGreaterThan(s, 0.95, "control: the columns' outline is a staircase along the grid")
        XCTAssertLessThan(c, 0.4, "the contour's outline follows the stamp, not the grid")
        // same place and size: the contour's area is the ≥ ½ columns' within a pitch round
        let ca = FlexibleDepthPrismTests.area(contour), sa = FlexibleDepthPrismTests.area(stairs)
        XCTAssertEqual(ca, sa, accuracy: sa * 0.25, "the same footprint, smoothed")
        // the page draws that prism, and the chip reads it
        let prism = try FlexibleSource.code("FlexibleDepthPrism.swift")
        XCTAssertTrue(prism.contains("footprint: model.prismFootprint(r)) else { return [] }"))
        let chips = try FlexibleSource.code("FlexibleDepthChips.swift")
        XCTAssertTrue(chips.contains("footprint: model.prismFootprint(r))"))
    }

    // MARK: - Settings and the main page say which squish a Stamp face shows (ux)

    @MainActor
    func testBothPagesSayAStampFaceSinksWholeOnTheMainPage() throws {
        XCTAssertLessThanOrEqual(FlexibleRowCopy.stampMainPage.count, FlexibleRowCopy.maxChars)
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        s.setFace(FlexibleFaceSettings(faceRegionID: 7, weightKg: 10, deepestMM: 3, shape: "stamp"))
        s.setFace(FlexibleFaceSettings(faceRegionID: 8, weightKg: 10, deepestMM: 3))
        XCTAssertTrue(FlexibleMainStage.showsStampFace(squished: [7, 8], settings: s))
        XCTAssertFalse(FlexibleMainStage.showsStampFace(squished: [8], settings: s), "a stamp face whose squish is not shown")
        // ★ RED CONTROL: under Curves the main page's title is its own
        var curves = s
        var f = try XCTUnwrap(curves.face(7)); f.shape = "curves"; curves.setFace(f)
        XCTAssertFalse(FlexibleMainStage.showsStampFace(squished: [7, 8], settings: curves), "control")
        let src = try FlexibleSource.code("FlexibleFaceStamp.swift")
        XCTAssertTrue(src.contains("Text(FlexibleRowCopy.stampMainPage)"), "said on the Stamp rows")
        let views = try FlexibleSource.code("FlexibleMainStage+Views.swift")
        XCTAssertTrue(views.contains("return FlexibleRowCopy.stampMainLegend"), "…and on the main page's dent legend")
        #if canImport(AppKit)
        // the legend line fits the main legend beside its "×k"
        let w = FlexibleRowCopyTests.width(Text(FlexibleRowCopy.stampMainLegend).font(.system(size: 12, weight: .semibold)))
        XCTAssertLessThanOrEqual(w, FlexibleMainLegendLayout.width - 2 * DS.Space.ml - 30, "\(w) pt")
        #endif
    }

    // MARK: - the curves keep out of the page's chrome (ux: img 6's class)

    #if canImport(AppKit)
    @MainActor
    func testTheCurvesAreNeitherDrawnNorTouchedUnderThePanel() throws {
        // a flat face 100 mm wide seen face-on: world (x, y) → 4 pt per mm
        let vp = CGSize(width: 400, height: 400)
        var m = matrix_identity_float4x4
        m.columns.0.x = 1 / 50; m.columns.1.y = 1 / 50; m.columns.3.x = -1; m.columns.3.y = -1
        let proj = CameraProjection(viewProjection: m, viewportSize: vp)
        let base = FlexibleCurveBaseline(points: (0...30).map { SIMD3(Double($0) * 100 / 30, 50, 0) },
                                         up: SIMD3(0, 1, 0), amplitudeMM: 20)
        let curve = FlexCurve(x: [0, 0.5, 1], y: [0.2, 0.9, 0.2])
        let panel = CGRect(x: 0, y: 0, width: 200, height: 400)        // the left half: the curve's first half runs under it
        func render(_ keep: [CGRect]) throws -> Int {
            let v = FlexibleCurveEditor(projection: proj, baseline: base, curve: curve, label: "X", tint: .white,
                                        selected: .constant(nil), onChange: { _ in }, onCommit: {}, keepOut: keep)
                .frame(width: vp.width, height: vp.height).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: v)
            let img = try XCTUnwrap(r.cgImage)
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let sx = CGFloat(w) / vp.width
            var n = 0
            for y in 0..<h { for x in 0..<Int(panel.maxX * sx) where px[(y * w + x) * 4 + 3] > 40 { n += 1 } }
            return n
        }
        let clipped = try render([panel]), open = try render([])
        print("FLEX-CURVE-KEEPOUT pixels drawn under the panel: \(clipped) (without the keep-out \(open))")
        XCTAssertGreaterThan(open, 200, "control: without the keep-out the curve draws under the panel")
        XCTAssertEqual(clipped, 0, "nothing of the curve under the panel")
        // …and no touch there: the tap band runs only outside it; a point under it is not mounted
        let line = (0...60).compactMap { proj.project(SIMD3<Float>(Float($0) * 100 / 60, 50 + 10, 0)) }
        let inside = CGPoint(x: 100, y: line[15].y)
        let band = FlexibleCurveBand(runs: FlexibleCurveEditor.runsOutside(line, keepOut: [panel], margin: 12), width: 24)
        XCTAssertFalse(band.path(in: CGRect(origin: .zero, size: vp)).contains(inside), "no band under the panel")
        XCTAssertTrue(band.path(in: CGRect(origin: .zero, size: vp)).contains(CGPoint(x: 300, y: line[45].y)), "the band outside it")
        XCTAssertTrue(FlexibleCurveBand(points: line, width: 24).path(in: CGRect(origin: .zero, size: vp)).contains(inside),
                      "control: the old band ran under the panel")
        XCTAssertFalse(FlexibleCurveEditor.reachable(CGPoint(x: 100, y: 200), keepOut: [panel]))
        XCTAssertTrue(FlexibleCurveEditor.reachable(CGPoint(x: 300, y: 200), keepOut: [panel]))
        // the page hands the editors its keep-outs (the panel, the legend, the player)
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("keepOut: keepOut)\n                }"), "the curve editors get the page's keep-outs")
    }
    #endif
}
