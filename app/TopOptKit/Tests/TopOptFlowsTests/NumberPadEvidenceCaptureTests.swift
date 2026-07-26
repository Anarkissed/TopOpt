// NumberPadEvidenceCaptureTests.swift — visual evidence for the numeric-input handoff.
//
// Same offscreen-ImageRenderer path the round-6 / import-sheet capture tests use (there
// is no live screen capture in this headless environment, and the SIMULATOR raises a REAL
// system keyboard that no screenshot could ever prove absent — a rendered pad is the
// stronger artefact: it shows what the tap opens instead). These are evidence generators,
// not behaviour assertions (behaviour is covered by NumberPadTests); they XCTFail only if
// the render or file write fails. PNGs land in evidence/2026-07-25-numeric-input/.
//
// The authoritative proof of B2 ("no path raises the system keyboard for a number") is the
// grep in the handoff — every numeric TextField is gone — and of B3 ("first keystroke
// replaces") is NumberPadTests.testFirstDigitReplacesTheSeed. These images show the control.

#if os(macOS)
import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import TopOptKit
import TopOptDesign
@testable import TopOptFlows

final class NumberPadEvidenceCaptureTests: XCTestCase {

    /// The compact pad that a single tap opens — keys, a live readout, a Done button; a
    /// popover anchored to the chip, NOT the full system keyboard.
    @MainActor
    func testCaptureTheNumberPad() throws {
        let pad = panel("A single tap opens THIS — a compact pad, not the system keyboard") {
            NumberPad(config: .init(title: "Margin", unit: "mm", allowsDecimal: true),
                      seed: 2.5) { _ in }
        }
        capture(pad, name: "01_number_pad.png", size: CGSize(width: 380, height: 460))
    }

    /// The pad anchored beside the chip it edits (the `.popover` on device), with the load
    /// weight pill it belongs to — "anchored beside that chip".
    @MainActor
    func testCapturePadAnchoredBesideChip() throws {
        let scene = panel("Anchored beside the chip — weight pill (left), its pad (right)") {
            HStack(alignment: .top, spacing: 20) {
                weightChip("2.5 kg")
                NumberPad(config: .init(title: "Weight", unit: "kg", allowsDecimal: true),
                          seed: 2.5) { _ in }
            }
        }
        capture(scene, name: "02_pad_anchored_beside_chip.png", size: CGSize(width: 640, height: 500))
    }

    /// B3, illustrated: the pad opens showing the current value (left); the FIRST keystroke
    /// REPLACES it — pressing "3" leaves "3", never "12.53" (right). (Seeded renders of the
    /// two states; the live transition is asserted in NumberPadTests.)
    @MainActor
    func testCaptureReplaceOnFirstKeystroke() throws {
        let before = panel("On open — shows the current value, 12.5") {
            NumberPad(config: .init(title: "Layer height", unit: "mm", allowsDecimal: true),
                      seed: 12.5) { _ in }
        }
        let after = panel("After the first key \"3\" — the whole value is replaced, not appended") {
            NumberPad(config: .init(title: "Layer height", unit: "mm", allowsDecimal: true),
                      seed: 3) { _ in }
        }
        capture(HStack(spacing: 16) { before; after }.padding(16),
                name: "03_replace_on_first_key.png", size: CGSize(width: 820, height: 500))
    }

    /// The integer pad (no decimal key) used by counts / % / port.
    @MainActor
    func testCaptureIntegerPad() throws {
        let pad = panel("Integer pad (counts, %, port) — no decimal key offered") {
            NumberPad(config: .init(title: "Wall loops", allowsDecimal: false), seed: 3) { _ in }
        }
        capture(pad, name: "04_integer_pad.png", size: CGSize(width: 380, height: 460))
    }

    // MARK: - chip stand-in + layout + capture

    private func weightChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .heavy)).tracking(-0.2)
            .foregroundStyle(DS.Color.accent.color)
            .padding(.vertical, 8).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.dialog.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
    }

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
        dir.appendPathComponent("evidence/2026-07-25-numeric-input", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("could not create destination for \(name)")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(name)")
        print("NUMERIC-INPUT-EVIDENCE wrote \(url.path)")
    }
}
#endif
