// FlexibleU21BendTests, fix round 1 of batch G (the checker's findings of 2026-10-22).
//   BLOCKER  the legend line lost its type and colour: U21's comment, pasted mid-line in FlexibleLegend, swallowed the line's
//            .font(.system(size: 12, weight: .semibold)).foregroundStyle(textPrimary) — every page that shows the legend drew it in
//            the default body type. RED CONTROL `FlexibleLegendLine.controlBareLegendLine` (the line as U21 drew it).
//   EDGE OUTLINE  his Img2: "The bend view doesn't bend the edges/corners" — with Bend on, an edge press's stamp outline (and its
//            indent) stayed at rest while the edge preview dented the edge under it. RED CONTROLS
//            `FlexiblePressStampHandle.controlEdgeOutlineAtRest` (batch G) and `FlexibleBendPose.controlNearestVertexEdges` (fix 1's
//            first try, posed by the nearest drawn vertex: jagged).
//   CACHE    `liveDesignTarget` ran FlexiblePinch.core on every refresh of a stale lattice; now once per design run.
//            RED CONTROL `FlexibleStageModel.controlNoLiveDesignCache`.
import XCTest
import simd
#if canImport(AppKit)
import AppKit
import SwiftUI
import TopOptDesign
#endif
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleU21BendTests {

    // MARK: the legend line's type and colour

    #if canImport(AppKit)
    /// Renders `v` offscreen on the legend's dark panel; its pixels and its size.
    private func render<V: View>(_ v: V) throws -> (size: CGSize, bytes: [UInt8]) {
        let host = v.fixedSize().padding(4).background(Color.black).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: host)
        r.scale = 2
        let img = try XCTUnwrap(r.cgImage, "rendered")
        let w = img.width, h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (CGSize(width: w, height: h), bytes)
    }

    func testTheLegendLineKeepsItsTypeAndColour() throws {
        for line in [FlexibleRowCopy.pressHeatLine(tuned: true), FlexibleRowCopy.pressHeatLine(tuned: false), "Squish depth · what you drew"] {
            // the line as it was before U21 (FlexibleStagePage, round 7): 12 pt semibold, textPrimary
            let reference = try render(Text(line).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.8))
            let now = try render(FlexibleLegendLine(text: line))
            FlexibleLegendLine.controlBareLegendLine = true
            let red = try render(FlexibleLegendLine(text: line))
            FlexibleLegendLine.controlBareLegendLine = false
            log.append("'\(line)': reference \(Int(reference.size.width))×\(Int(reference.size.height)) px · now \(Int(now.size.width))×\(Int(now.size.height)) px, pixels \(now.bytes == reference.bytes ? "identical" : "DIFFER") · RED bare line \(Int(red.size.width))×\(Int(red.size.height)) px, pixels \(red.bytes == reference.bytes ? "identical" : "differ")")
            XCTAssertEqual(now.size, reference.size, "\(line): 12 pt semibold")
            XCTAssertEqual(now.bytes, reference.bytes, "\(line): the same type and colour, pixel for pixel")
            XCTAssertTrue(red.size != reference.size || red.bytes != reference.bytes, "RED CONTROL: U21's line (no font, no colour) draws differently")
        }
        flush("U21G_fix1_lines_legend_type.txt")
    }
    #endif

    /// No comment pasted mid-line swallows a modifier anywhere in the Flexible sources (U21's `// ★ U21.font(…)…`).
    func testNoTrailingCommentSwallowsAModifier() throws {
        let dir = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let modifier = try NSRegularExpression(pattern: #"[A-Za-z0-9_)\]]\.(font|foregroundStyle|foregroundColor|lineLimit|minimumScaleFactor|padding|frame|background|overlay|opacity|offset|position|accessibilityIdentifier|accessibilityLabel|allowsHitTesting|gesture|onTapGesture|tracking|monospacedDigit)\("#)
        func hits(_ src: String) -> [String] {
            src.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
                let line = String(raw)
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), let r = line.range(of: "//"), !line[..<r.lowerBound].hasSuffix(":") else { return nil }
                // (a `//` inside a string literal: an odd count of quotes before it)
                guard line[..<r.lowerBound].filter({ $0 == "\"" }).count % 2 == 0 else { return nil }
                let comment = String(line[r.upperBound...])
                return modifier.firstMatch(in: comment, range: NSRange(comment.startIndex..., in: comment)) != nil ? line : nil
            }
        }
        var found: [String] = []
        for f in files { found += hits(try String(contentsOf: f, encoding: .utf8)).map { "\(f.lastPathComponent): \($0.trimmingCharacters(in: .whitespaces))" } }
        log.append("\(files.count) files · trailing comments holding a modifier: \(found.count)")
        XCTAssertEqual(found, [], "a modifier commented out at the end of a line")
        // RED CONTROL: U21's line as committed in 26c82b30
        let u21 = #"                Text(pressHeatTopMM == nil ? shown.legendLine : FlexibleRowCopy.pressHeatLine(tuned: model.playingPressSimTuned))   // ★ U21.font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)"#
        XCTAssertEqual(hits(u21).count, 1, "RED CONTROL: U21's legend line is caught")
        flush("U21G_fix1_lines_no_swallowed_modifier.txt")
    }

    // MARK: an edge press's outline on the bent edge (his Img2)

    /// His Img2: with Bend on, Edge 12's stamp outline sits on the edge preview's dent — smoothly. Fix 1's first try posed it by the
    /// nearest drawn vertex: on the bent edge the outline went jagged (seen in that try's U21G_09), because a stamp's push is 1 under
    /// it and 0 past it and the outline lies exactly on that step. It sits on the pocket's floor now (`EdgePush.whole`).
    func testTheEdgeStampOutlineSitsOnTheEdgePreview() async throws {
        let (_, m, g, _) = try await padEdges(build: false)
        let e12 = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" })
        m.selectedPress = e12.id
        var v = m.views; v.remove(.play); v.insert(.bend); m.views = v
        let st = try XCTUnwrap(e12.strip), stamp = try XCTUnwrap(e12.settings.designStamp, "premise: Edge 12 is a Stamp (his 12.png)")
        let c = try XCTUnwrap(m.flatCut(e12.id))
        let edge = FlexibleSettingsSquish.pageEdge(model: m)
        let o = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0, maxTriangles: FlexibleSettingsSquish.columnMaxTriangles) }
                              ?? FlexiblePageChannels.overlay(model: m))
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: FlexibleStagePage.composeTints(model: m, overlay: o), feCache: &cache)
        XCTAssertFalse(sq.fe, "premise: no lattice — the edge preview")
        XCTAssertEqual(sq.poseEdges.count, 2, "premise: Edge 12 and Edge 9's pushes reach the pose")
        let pose = try XCTUnwrap(FlexibleStagePage.bendPose(views: m.views, overlay: o, dents: sq.dents, k: sq.exaggeration, faces: sq.poseFaces,
                                                            field: sq.field, edges: sq.poseEdges))
        let rest = FlexiblePressStamp.outline(st, stamp, direction: c.direction)
        XCTAssertGreaterThan(rest.count, 10)
        func along(_ pts: [SIMD3<Double>]) -> [Double] { zip(pts, rest).map { simd_dot($0 - $1, c.direction) } }
        // the dent under each outline point read straight from the page's buffer (its nearest drawn vertex, brute force)
        let pos = o.mesh.flat.positions, d = try XCTUnwrap(sq.dents)
        let under = rest.map { q -> Double in
            var best = Double.infinity, at = -1
            for i in 0..<(pos.count / 3) {
                let e = simd_distance_squared(SIMD3<Double>(Double(pos[3 * i]), Double(pos[3 * i + 1]), Double(pos[3 * i + 2])), q)
                if e < best { best = e; at = i }
            }
            guard at >= 0 else { return 0 }
            return simd_dot(SIMD3<Double>(Double(d[3 * at]), Double(d[3 * at + 1]), Double(d[3 * at + 2])), c.direction) * sq.exaggeration
        }
        // a spike (zig-zag): a point that jumps one way from its neighbour and back the other way to the next — the smaller of the
        // two jumps (the outline is closed: first = last). A one-way step (the pocket's wall at the prism's floor) is no spike.
        func spike(_ a: [Double]) -> Double {
            let n = a.count - 1
            guard n > 2 else { return 0 }
            return (0..<n).map { i -> Double in
                let l = a[i] - a[(i + n - 1) % n], r = a[(i + 1) % n] - a[i]
                return l * r < 0 ? Swift.min(abs(l), abs(r)) : 0
            }.max() ?? 0
        }
        func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        let now = along(FlexiblePressStampHandle.drawnOutline(st, stamp, cut: c, pose: pose))
        FlexibleBendPose.controlNearestVertexEdges = true
        let nearestPose = try XCTUnwrap(FlexibleStagePage.bendPose(views: m.views, overlay: o, dents: sq.dents, k: sq.exaggeration, faces: sq.poseFaces,
                                                                   field: sq.field, edges: sq.poseEdges))
        let jagged = along(FlexiblePressStampHandle.drawnOutline(st, stamp, cut: c, pose: nearestPose))
        FlexibleBendPose.controlNearestVertexEdges = false
        FlexiblePressStampHandle.controlEdgeOutlineAtRest = true
        let red = along(FlexiblePressStampHandle.drawnOutline(st, stamp, cut: c, pose: pose))
        FlexiblePressStampHandle.controlEdgeOutlineAtRest = false
        let gapNow = zip(now, under).map { abs($0 - $1) }
        let moving = under.filter { $0 > 0.5 }.count
        log.append(String(format: "Edge 12's stamp outline, %d points, Bend on, no lattice (edge preview): the dent under them (nearest drawn vertex) up to %.2f mm, mean %.2f mm (%d points over 0.5 mm)",
                          rest.count, under.max() ?? 0, mean(under), moving))
        // in the prism above its last millimetre the outline sits on the pocket's floor: exactly the press's depth, the deepest dent
        let depth = try XCTUnwrap(sq.poseEdges.first { $0.cut == c }?.depthMM)
        let deep = rest.indices.filter { let h = c.height(rest[$0]); return h > -0.25 && h < c.depthMM - 1 }
        let offFloor = deep.map { abs(now[$0] - depth) }.max() ?? .infinity
        log.append(String(format: "now (on the pocket's floor): %d points in the prism move %.2f mm (the press's depth %.2f; worst off it %.3f mm), up to %.2f mm · worst spike %.2f mm · mean gap to the nearest vertex's dent %.2f mm (the dent is a step at the stamp's rim)",
                          deep.count, deep.isEmpty ? 0 : mean(deep.map { now[$0] }), depth, offFloor, now.max() ?? 0, spike(now), mean(gapNow)))
        log.append(String(format: "RED controlNearestVertexEdges (fix 1's first try): worst spike %.2f mm · RED controlEdgeOutlineAtRest (batch G): moves up to %.2f mm", spike(jagged), red.max() ?? 0))
        XCTAssertGreaterThan(moving, rest.count / 4, "premise: the edge preview dents the edge under the outline")
        XCTAssertGreaterThan(deep.count, rest.count / 4, "premise: much of the outline lies in the prism")
        XCTAssertEqual((under.max() ?? 0), depth, accuracy: 0.05, "premise: the deepest dent under the outline is the press's depth")
        XCTAssertLessThan(offFloor, 0.01, "the outline sits on the pocket's floor")
        XCTAssertLessThan(spike(now), 1.0, "no spike: the outline stays a smooth line")
        XCTAssertGreaterThan(spike(jagged), 2, "RED CONTROL: the nearest vertex makes it jagged")
        XCTAssertEqual(red.max() ?? 0, 0, accuracy: 1e-9, "RED CONTROL: the outline at rest over the dent")
        XCTAssertEqual(m.playingGroup?.number, g.number)
        flush("U21G_fix1_lines_edge_outline.txt")
    }

    // MARK: core's live design worked out once per design run

    func testTheLiveDesignTargetIsWorkedOutOncePerDesignRun() async throws {
        let (_, m, _, _) = try await padEdges(build: false)
        let e12 = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" })
        try await FlexibleHisProject.waitFor(240, "core's design of Edge 12") { !m.designsInFlight && m.liveDesignTarget(e12.id) != nil }
        let first = try XCTUnwrap(m.liveDesignTarget(e12.id))
        func count(_ n: Int) -> Int {
            let c0 = FlexibleStageModel.liveDesignTargetComputations
            for _ in 0..<n { XCTAssertEqual(m.liveDesignTarget(e12.id)?.depthsMM, first.depthsMM) }
            return FlexibleStageModel.liveDesignTargetComputations - c0
        }
        let now = count(20)
        FlexibleStageModel.controlNoLiveDesignCache = true
        let red = count(20)
        FlexibleStageModel.controlNoLiveDesignCache = false
        // a new design run (his edit: Edge 12 pressed half as hard again) works it out again
        m.edit { s in guard var p = s.press(e12.id) else { return }; p.settings.weightKg *= 1.5; s.setPress(p) }
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(240, "the new designs") { !m.designsInFlight && m.liveDesignTarget(e12.id) != nil }
        let edited = try XCTUnwrap(m.liveDesignTarget(e12.id))
        let changed = zip(first.depthsMM, edited.depthsMM).filter { abs(($0 ?? 0) - ($1 ?? 0)) > 1e-6 }.count
        log.append("20 refreshes: worked out \(now) times now · RED no cache \(red) times · after his edit (Edge 12 × 1.5) a new design: \(changed) of \(edited.depthsMM.count) columns changed")
        XCTAssertEqual(now, 0, "the same design run: from the cache")
        XCTAssertEqual(red, 20, "RED CONTROL: every refresh ran FlexiblePinch.core")
        XCTAssertGreaterThan(changed, 0, "a new design run is never answered from the old one")
        flush("U21G_fix1_lines_live_design_cache.txt")
    }
}
