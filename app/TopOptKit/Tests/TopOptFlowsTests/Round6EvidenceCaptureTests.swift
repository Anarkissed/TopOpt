// Round6EvidenceCaptureTests.swift — before/after evidence for the round-6 UI batch
// (items 1–3). ImageRenderer offscreen PNGs (there is no screen-capture in this environment;
// the same path ImportSheetCaptureTests / the worker QA capture use). Glass/material reads
// flatter offscreen than on device — the point of these captures is LAYOUT and OVERLAP, not
// the material finish. Written to docs/handoffs/assets/round6_*.png.
//
// These are evidence generators, not behaviour assertions (the behaviour is covered by
// UndoHistoryTests + the existing gizmo/clearance suites); they XCTFail only if the render or
// the file write fails.

#if os(macOS)
import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import TopOptKit
import TopOptDesign
@testable import TopOptFlows

final class Round6EvidenceCaptureTests: XCTestCase {

    // MARK: item 1 + 2 — chips off the drag knobs, number-only in the viewport

    @MainActor
    func testCaptureViewportChipBeforeAfter() throws {
        let before = labeledPanel("BEFORE — chip centred on the knob (overlaps the grab target)") {
            knobStage { KnobWithHalo() }
                .overlay(alignment: .topLeading) {
                    // Old rule: the titled + chrome pill CENTRED at knobX + 46 → its left edge rides
                    // back onto the ~50 pt knob hit target.
                    oldChip
                        .fixedSize()
                        .position(x: Self.knobX + 46, y: Self.knobY)
                }
        }
        let after = labeledPanel("AFTER — number-only chip, leading edge clear of the knob") {
            knobStage { KnobWithHalo() }
                .overlay(alignment: .topLeading) {
                    // New rule: number-only pill, LEADING edge anchored at knobX + 40 (clears the
                    // 25 pt active hit radius with room to spare).
                    HStack(spacing: 0) {
                        newChip.fixedSize()
                        Spacer(minLength: 0)
                    }
                    .frame(width: 360 - (Self.knobX + 40), alignment: .leading)
                    .position(x: (Self.knobX + 40) + (360 - (Self.knobX + 40)) / 2, y: Self.knobY)
                }
        }
        capture(sideBySide(before, after), name: "round6_1_chips_off_handles.png", size: CGSize(width: 900, height: 320))
    }

    // MARK: item 2 — Selections-panel: label outside, one metric per row (no mid-word wrap)

    @MainActor
    func testCapturePanelRowBeforeAfter() throws {
        // The panel is 300 pt wide; a bore row sits right-aligned below the trash icon.
        let before = labeledPanel("BEFORE — captioned Margin + Axial pills on one line → wraps") {
            HStack(spacing: DS.Space.xs) {
                Text("Bore").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textQuaternary.color)
                GlassValuePill(title: "Margin", valueMM: 1.5, autoMM: 1.5) { _ in }
                GlassValuePill(title: "Axial", valueMM: 3.0, autoMM: 3.0) { _ in }
            }
            .frame(width: 260, alignment: .trailing)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.Surface.panel.color))
        }
        let after = labeledPanel("AFTER — caption text OUTSIDE a number-only chip, one metric per row") {
            VStack(alignment: .trailing, spacing: 4) {
                Text("Bore").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textQuaternary.color)
                metricRow("Margin", GlassValuePill(title: "Margin", valueMM: 1.5, autoMM: 1.5, showTitle: false) { _ in })
                metricRow("Axial", GlassValuePill(title: "Axial", valueMM: 3.0, autoMM: 3.0, showTitle: false) { _ in })
            }
            .frame(width: 260, alignment: .trailing)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.Surface.panel.color))
        }
        capture(sideBySide(before, after), name: "round6_2_panel_no_wrap.png", size: CGSize(width: 900, height: 340))
    }

    // MARK: item 3 — the roll arrows now rotate the view the way they point

    @MainActor
    func testCaptureGizmoRotationDirection() throws {
        // A +roll rotates the image CLOCKWISE in the y-down screen space (OrbitCamera `up`/`orbit`
        // comments), and SwiftUI's `.rotationEffect(+angle)` is likewise clockwise — so a marker
        // rotated by the value the LEFT (⟲, counter-clockwise) arrow SENDS depicts what the view
        // actually did. Old: +rollStep (CW, mirrored). New: −rollStep (CCW, matches the glyph).
        let step = Double.pi / 4
        let before = labeledPanel("BEFORE — left ⟲ arrow sent +rollStep → view spun CW (mirrored)") {
            arrowVsMarker(system: "arrow.counterclockwise", markerRoll: step)
        }
        let after = labeledPanel("AFTER — left ⟲ arrow sends −rollStep → view spins CCW (matches)") {
            arrowVsMarker(system: "arrow.counterclockwise", markerRoll: -step)
        }
        capture(sideBySide(before, after), name: "round6_3_gizmo_rotation.png", size: CGSize(width: 900, height: 320))
    }

    // MARK: - little building blocks

    private static let knobX: CGFloat = 80
    private static let knobY: CGFloat = 110

    /// The red clearance knob with its ~46 pt grab halo drawn faintly, so an overlapping chip is
    /// visibly on the grab target.
    private struct KnobWithHalo: View {
        var body: some View {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 50, height: 50)                       // the hit target (~radius 25)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(red: 0.90, green: 0.28, blue: 0.26)))
            }
            .position(x: knobX, y: knobY)
        }
    }

    private func knobStage<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ZStack(alignment: .topLeading) { Color.clear; content() }
            .frame(width: 360, height: 200)
    }

    /// The OLD viewport chip: caption + number + Auto/reset chrome.
    private var oldChip: some View { GlassValuePill(title: "Margin", valueMM: 1.5, autoMM: 1.5, compact: true) { _ in } }
    /// The NEW viewport chip: number only.
    private var newChip: some View {
        GlassValuePill(title: "Margin", valueMM: 1.5, autoMM: 1.5, compact: true,
                       showTitle: false, showChrome: false) { _ in }
    }

    private func metricRow(_ label: String, _ pill: GlassValuePill) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text("\(label):").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
            pill
        }
        .fixedSize()
    }

    /// The ⟲/⟳ arrow next to a bright asymmetric marker rotated by `markerRoll` radians — showing
    /// which way the VIEW turns when that arrow is tapped.
    private func arrowVsMarker(system: String, markerRoll: Double) -> some View {
        HStack(spacing: 34) {
            Image(systemName: system)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Color(red: 0.82, green: 0.88, blue: 1.0))
            marker.rotationEffect(.radians(markerRoll))
        }
    }

    /// An up-pointing chevron over a horizon line — asymmetric, so its rotation is unmistakable.
    private var marker: some View {
        VStack(spacing: 4) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.30))
            Rectangle().fill(Color.white.opacity(0.55)).frame(width: 70, height: 2)
        }
    }

    // MARK: - layout + capture

    private func labeledPanel<V: View>(_ caption: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 12) {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(caption)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
        .padding(16)
        .frame(width: 430, height: 280)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.10, green: 0.10, blue: 0.13)))
    }

    private func sideBySide<A: View, B: View>(_ a: A, _ b: B) -> some View {
        HStack(spacing: 16) { a; b }.padding(16)
    }

    @MainActor
    private func capture<V: View>(_ view: V, name: String, size: CGSize) {
        let host = ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
            view
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: host)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            XCTFail("ImageRenderer produced no image for \(name)")
            return
        }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        dir.appendPathComponent("docs/handoffs/assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("could not create destination for \(name)")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(name)")
        print("ROUND6-EVIDENCE wrote \(url.path)")
    }
}
#endif
