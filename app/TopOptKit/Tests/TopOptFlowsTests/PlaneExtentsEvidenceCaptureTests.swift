// PlaneExtentsEvidenceCaptureTests.swift — visual evidence for the manual-plane
// Length/Width exposure (handoff 2026-07-26-plane-extents).
//
// Same offscreen-ImageRenderer path the numeric-input / round-6 / import-sheet capture
// tests use (there is no live screen capture in this headless environment — see
// NumberPadEvidenceCaptureTests). These render the REAL production control — the
// `GlassValuePill` composed exactly as `WorkspacePlaceholder.manualPrimitiveLine` lays
// a manual PLANE row out — so the image is proof of the shipped view, not a mock. They
// are evidence generators, not behaviour assertions (behaviour is ManualPrimitiveTests /
// ManualPrimitiveJobTests); they XCTFail only if the render or file write fails. PNGs
// land in evidence/2026-07-26-plane-extents/.
//
// The values shown mirror the tests: a 40 × 24 mm slab 3 mm deep, i.e. full Length 40
// (halfU 20) × full Width 24 (halfW 12) — the UI shows FULL extents (what calipers
// measure); the ÷2 to the core's centred half-extents happens once, in ProjectModel.

#if os(macOS)
import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import TopOptKit
import TopOptDesign
@testable import TopOptFlows

final class PlaneExtentsEvidenceCaptureTests: XCTestCase {

    private static let tint = DS.Color.clearance.color

    /// The manual-plane row AS SHIPPED: a "Plane · manual" header over Length / Width /
    /// Depth, each caption OUTSIDE its number-only pill on its OWN row (P6 — no chip two
    /// rows high). Length/Width are the new controls; Depth was already there.
    @MainActor
    func testCaptureManualPlaneRowWithLengthWidthDepth() throws {
        let row = panel("A manually placed PLANE now exposes Length × Width (its footprint) alongside Depth (how far it sticks out)") {
            manualPlaneRow(lengthMM: 40, widthMM: 24, depthMM: 3)
        }
        capture(row, name: "01_plane_row_length_width_depth.png", size: CGSize(width: 460, height: 380))
    }

    /// Before → after: the plane row USED to carry Depth only (a slab with no in-plane
    /// size — useless as a keep-out); it now carries Length × Width × Depth.
    @MainActor
    func testCaptureBeforeAfter() throws {
        let before = panel("BEFORE — Depth only: no way to say how big the slab is") {
            VStack(alignment: .trailing, spacing: 4) {
                header
                extentless(depthMM: 3)
            }
        }
        let after = panel("AFTER — Length × Width × Depth: a fully sized keep-out slab") {
            manualPlaneRow(lengthMM: 40, widthMM: 24, depthMM: 3)
        }
        capture(HStack(alignment: .top, spacing: 18) { before; after }.padding(16),
                name: "02_before_after.png", size: CGSize(width: 940, height: 400))
    }

    // MARK: - the REAL row, reconstructed from production components

    private var header: some View {
        Text("Plane · manual")
            .dsStyle(DS.TypeScale.caption)
            .foregroundStyle(Self.tint)
    }

    /// The exact composition `manualPrimitiveLine` uses for a `.face`: header + three
    /// captioned rows. Length/Width are FULL-extent number-only pills (`showChrome:false`,
    /// no Auto — an extent has none); Depth is the Auto-aware metric pill.
    private func manualPlaneRow(lengthMM: Double, widthMM: Double, depthMM: Double) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            header
            metricRow("Length", extentPill(lengthMM))
            metricRow("Width", extentPill(widthMM))
            metricRow("Depth", GlassValuePill(title: "Depth", valueMM: depthMM, autoMM: depthMM,
                                              compact: true, showTitle: false) { _ in })
        }
    }

    /// The pre-feature row: header + Depth only.
    private func extentless(depthMM: Double) -> some View {
        metricRow("Depth", GlassValuePill(title: "Depth", valueMM: depthMM, autoMM: depthMM,
                                          compact: true, showTitle: false) { _ in })
    }

    /// The production extent pill: FULL extent, number-only, no Auto/reset (`showChrome:false`).
    private func extentPill(_ fullMM: Double) -> GlassValuePill {
        GlassValuePill(title: "extent", valueMM: fullMM, autoMM: nil,
                       compact: true, showTitle: false, showChrome: false) { _ in }
    }

    /// `WorkspacePlaceholder.clearanceMetricRow`, mirrored: caption text OUTSIDE the pill,
    /// on one `.fixedSize` line so nothing wraps.
    private func metricRow(_ label: String, _ pill: GlassValuePill) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text("\(label):")
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textTertiary.color)
            pill
        }
        .fixedSize()
    }

    // MARK: - layout + capture (same as NumberPadEvidenceCaptureTests)

    private func panel<V: View>(_ caption: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 14) {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(caption)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.10, green: 0.10, blue: 0.13)))
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
        for _ in 0..<5 { dir.deleteLastPathComponent() }   // → worktree root
        dir.appendPathComponent("evidence/2026-07-26-plane-extents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("could not create destination for \(name)")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(name)")
        print("PLANE-EXTENTS-EVIDENCE wrote \(url.path)")
    }
}
#endif
