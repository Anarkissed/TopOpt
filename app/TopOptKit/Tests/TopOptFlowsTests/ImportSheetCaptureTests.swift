// ImportSheetCaptureTests.swift — renders the handoff-134 import sheets to PNG
// so the refusal copy can be READ rather than described.
//
// macOS-only and ImageRenderer-based (there is no screen-capture in this
// environment; the same approach the worker app's QA capture uses). The
// rendered glass reads flatter offscreen than it does on device — the point of
// these captures is the COPY and the layout, not the material.

#if os(macOS)
import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import TopOptKit
@testable import TopOptFlows

final class ImportSheetCaptureTests: XCTestCase {

    /// The deliberately broken mesh the refusal sheet is captured against: the
    /// committed open-cube fixture (a cube missing a side).
    private static let brokenSTL: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("core/tests/fixtures/stl/broken_open_cube.stl").path
    }()

    @MainActor
    func testCaptureRefusalSheetForABrokenMesh() throws {
        let model = AppModel(materialsPath: nil)
        model.pickedFile(atPath: Self.brokenSTL, displayName: "broken_open_cube.stl")

        let refusal = try XCTUnwrap(model.importRefusal,
                                    "the broken fixture must produce a refusal to capture")
        // The capture is only meaningful if it is the real verdict.
        XCTAssertEqual(refusal.diagnostics?.defects, [.openBoundary])

        capture(ImportRefusalSheet(model: model, refusal: refusal),
                name: "134_refusal_sheet_open_mesh.png")
    }

    @MainActor
    func testCaptureUnitPromptForAUnitlessMesh() throws {
        let model = AppModel(materialsPath: nil)
        // An inch-unit export: 4.72 units across. Both readings are plausible,
        // so the sheet shows both numbers and makes no recommendation — the
        // honest case, and the one worth showing.
        let prompt = ImportUnitPrompt(fileName: "bracket.stl", largestDimension: 4.72)
        model.pendingUnitPrompt = prompt
        capture(ImportUnitSheet(model: model, prompt: prompt),
                name: "134_unit_prompt.png")
    }

    // MARK: capture helper

    @MainActor
    private func capture<V: View>(_ view: V, name: String) {
        let host = ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09)
            view
        }
        .frame(width: 700, height: 620)
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
        print("IMPORT-SHEET-CAPTURE wrote \(url.path)")
    }
}
#endif
