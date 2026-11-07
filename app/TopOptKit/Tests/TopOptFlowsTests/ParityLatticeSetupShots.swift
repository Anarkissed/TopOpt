// ParityLatticeSetupShots — B6 (his go 11-05; the reviewer's rule A, 11-04 02:56Z): Lattice Setup's states, offscreen, next to
// mockup v5's same state (scratchpad/parity/mockshot.py). Opt-in: PARITY_SHOT_DIR=<dir>; skipped otherwise. ParityTopologyShots'
// pad (three scenarios, two anchors, the 51 kg push, Protect) on Structural, with the mockup's Group 1: three faces latticed.
// The 3D view draws nothing offscreen (Metal) — the chrome is what's judged.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ParityLatticeSetupShots: XCTestCase {

    /// The pad on Structural; the lattice list's Group 1 (Lattice) holding `faces` faces, the first from his Top (also in a
    /// Topology group, as the mockup's "also in Group A"), open. Nothing saved on the Lattice page yet (the mockup's state).
    func page(_ size: CGSize, faces: Int = 3) throws -> (AppBuildHost, ProjectModel) {
        let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): Topology's ● menu")
        h.pump(1)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" }, "his Top")
        let others = Set(mesh.faceIDs).subtracting(top.faces).sorted()
        for f in (top.faces.prefix(1) + others.prefix(faces - 1)) {
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID { p.lattice.groupRoles[g] = .include }
        }
        h.pump(1)
        return (h, p)
    }

    func testLatticeSetupStates() throws {
        guard ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] != nil else { throw XCTSkip("PARITY_SHOT_DIR not set") }
        for (name, size) in ParityTopologyShots.sizes {
            let (h, p) = try page(size)
            try ParityTopologyShots.shot(h, "lat-setup", name)
            // a face row picked (mockup #lat-setup-face-row): its depth field and its own role
            if let g = p.latticeGroups.first, let ref = p.latticeSelectableRefs(g).first {
                p.latticeList.setActive(g.id)
                h.pump(0.5)
                if h.frames.all["latticeFace-\(ref.key)"] != nil {
                    try h.tap("latticeFace-\(ref.key)", "the first face row")
                    try ParityTopologyShots.shot(h, "lat-setup-face-row", name)
                    try h.tap("latticeFace-\(ref.key)", "the first face row again")
                }
            }
            // the Topology panel open, its first scenario open (mockup #lat-setup-topo-open)
            if h.frames.all["latticeTopologyPanelHeader"] != nil {
                try h.tap("latticeTopologyPanelHeader", "Topology's header")
                if let s = p.force.scenarioList.first, h.frames.all["latticeTopoFolder-\(s.id.uuidString)"] != nil {
                    try h.tap("latticeTopoFolder-\(s.id.uuidString)", "the first scenario")
                }
                h.pump(0.5)
                try ParityTopologyShots.shot(h, "lat-setup-topo-open", name)
                try h.tap("latticeTopologyPanelHeader", "Topology's header again")
            }
            // a zone added and picked (mockup #lat-zone-sel); then off again
            if h.frames.all["latticeZonesSectionAction"] != nil {
                try h.tap("latticeZonesSectionAction", "+ Add zone")
                try ParityTopologyShots.shot(h, "lat-zone-sel", name)
                if let z = p.latticeZones.first { p.removeLatticeZone(z.id) }
                h.pump(0.5)
            }
            // Start from's ask (mockup #lat-latmode-ask)
            if h.frames.all["latticeStartFrom"] != nil {
                try h.pickFromMenu("latticeStartFrom", "All lattice", what: "Start from")
                h.pump(0.5)
                try ParityTopologyShots.shot(h, "lat-latmode-ask", name)
                if h.frames.all["latticeModeCancel"] != nil { try h.tap("latticeModeCancel", "Cancel") }
            }
            // a tap that starts a new group: the role picker at the face (mockup #lat-setup-face-pick)
            p.latticeList.clearActive()
            let held = Set(p.latticeGroups.flatMap(\.faces))
            if let mesh = p.viewerMesh, let f = mesh.faceIDs.first(where: { !held.contains($0) }) {
                _ = p.latticeStageTap(face: f, loop: [f])
                h.pump(1)
                try ParityTopologyShots.shot(h, "lat-setup-face-pick", name)
            }
            if h.frames.all["setupChip"] != nil {
                try h.tap("setupChip", "Settings")
                h.pump(0.5)
                try ParityTopologyShots.shot(h, "lat-settings-above", name)
            }
        }
    }

    /// ★ B6 N2 / N3 (the reviewer's rule, 11-06 09:41Z: "From N2/N3 on, shoot with the fixture part loaded, showing the lit
    /// faces, the zone box and the handles"): a face picked (its prism, lit, and its end handle), the eyes showing the other
    /// prisms, a Box zone picked (its handles), a Cylinder zone. The page's 3D view draws nothing in an offscreen window, so
    /// the page's OWN renderer (the MTKView's MeshRenderer, as the page set it up: its mesh, tints, prisms, camera, stage)
    /// draws the frame offscreen at the page's size, and the page's chrome goes over it ("over", by the page's alpha).
    func testHandleShots() throws {
        guard ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] != nil else { throw XCTSkip("PARITY_SHOT_DIR not set") }
        for (name, size) in ParityTopologyShots.sizes {
            let (h, p) = try page(size)
            let g = try XCTUnwrap(p.latticeGroups.first, "Group 1")   // (no lattice saved: as his iPad had it)
            p.latticeList.setActive(g.id)
            h.pump(1)
            let refs = p.latticeSelectableRefs(g)
            let first = try XCTUnwrap(refs.first)
            try h.tap("latticeFace-\(first.key)", "\(name): the first face row")
            try Self.partShot(h, "lat-face-prism", name)
            for r in refs.dropFirst() where h.frames.all["latticeFaceEye-\(r.key)"] != nil {
                try h.tap("latticeFaceEye-\(r.key)", "\(name): its eye")
            }
            try Self.partShot(h, "lat-prisms-eye", name)
            try h.tap("latticeZonesSectionAction", "\(name): + Add zone")
            try Self.partShot(h, "lat-zone-sel", name)
            if let z = p.latticeZones.first, let shape = h.frames.all["latticeZoneShape-\(z.id.uuidString)"] {
                h.click(CGPoint(x: shape.maxX - shape.width / 4, y: shape.midY))
                try Self.partShot(h, "lat-zone-cyl", name)
            }
        }
    }

    /// The page's MTKViews (its 3D view is the largest whose delegate is the MeshRenderer).
    static func mtkViews(_ v: NSView) -> [MTKView] { ((v as? MTKView).map { [$0] } ?? []) + v.subviews.flatMap(mtkViews) }

    /// The page with the fixture part drawn under its chrome: the page's own renderer, offscreen, at the page's pixel size,
    /// then the page's bitmap over it by its alpha. Also writes the two layers (…_part.png, …_chrome.png) beside it.
    static func partShot(_ h: AppBuildHost, _ state: String, _ size: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] else { return }
        h.pump(0.6)
        h.view.layoutSubtreeIfNeeded()
        let cached = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: cached)
        let W = cached.pixelsWide, H = cached.pixelsHigh
        func rgba(_ w: Int, _ hh: Int) throws -> NSBitmapImageRep {
            try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: hh, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32))
        }
        // the chrome in a known layout: RGBA, 8 bits, premultiplied
        let chrome = try rgba(W, H)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: chrome)
        NSColor.clear.set()
        CGRect(x: 0, y: 0, width: W, height: H).fill()
        cached.draw(in: CGRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.restoreGraphicsState()
        let mtk = try XCTUnwrap(mtkViews(h.view).filter { $0.delegate is MeshRenderer }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }, "the page's 3D view")
        let mr = try XCTUnwrap(mtk.delegate as? MeshRenderer)
        let f = mtk.convert(mtk.bounds, to: h.view)   // (AppKit: origin bottom-left)
        let sx = CGFloat(W) / h.view.bounds.width, sy = CGFloat(H) / h.view.bounds.height
        let pw = Int((f.width * sx).rounded()), ph = Int((f.height * sy).rounded())
        let bg = DS.Color.background
        let part = try XCTUnwrap(mr.renderOffscreen(width: pw, height: ph,
                                                    clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)),
                                 "the page's renderer drew the part")
        let x0 = Int((f.minX * sx).rounded()), yTop = Int(((h.view.bounds.height - f.maxY) * sy).rounded())
        let out = try rgba(W, H), partRep = try rgba(pw, ph)
        let c = try XCTUnwrap(chrome.bitmapData), o = try XCTUnwrap(out.bitmapData), q = try XCTUnwrap(partRep.bitmapData)
        for y in 0..<ph { for x in 0..<pw {   // BGRA → RGBA
            let s = (y * pw + x) * 4
            q[s] = part[s + 2]; q[s + 1] = part[s + 1]; q[s + 2] = part[s]; q[s + 3] = 255
        } }
        let back = (Int(bg.r * 255), Int(bg.g * 255), Int(bg.b * 255))
        for y in 0..<H { for x in 0..<W {
            let i = (y * W + x) * 4
            let a = Int(c[i + 3])
            let px = x - x0, py = y - yTop
            var under = back
            if px >= 0, py >= 0, px < pw, py < ph { let s = (py * pw + px) * 4; under = (Int(q[s]), Int(q[s + 1]), Int(q[s + 2])) }
            // premultiplied "over": out = chrome + under · (1 − α)
            o[i] = UInt8(min(255, Int(c[i]) + under.0 * (255 - a) / 255))
            o[i + 1] = UInt8(min(255, Int(c[i + 1]) + under.1 * (255 - a) / 255))
            o[i + 2] = UInt8(min(255, Int(c[i + 2]) + under.2 * (255 - a) / 255))
            o[i + 3] = 255
        } }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: dir)
        try XCTUnwrap(out.representation(using: .png, properties: [:])).write(to: base.appendingPathComponent("app_\(state)_\(size).png"))
        try XCTUnwrap(partRep.representation(using: .png, properties: [:])).write(to: base.appendingPathComponent("app_\(state)_\(size)_part.png"))
        try XCTUnwrap(chrome.representation(using: .png, properties: [:])).write(to: base.appendingPathComponent("app_\(state)_\(size)_chrome.png"))
    }
}
#endif
