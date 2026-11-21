// UploadNewVersionHostedTests — his ask 2026-11-11 (DATA-MODEL.md decision 12): "Upload new version" on a part. The part page
// offers it beside Compare, in the same glass (the Library keeps its look, his 11-04 ruling: a button added, nothing restyled),
// a 44 pt target wholly in the window at all six windows, over nothing and under nothing.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class UploadNewVersionHostedTests: XCTestCase {

    func testThePartPageOffersUploadNewVersionAtEveryWindow() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var placed: [String: String] = [:]   // "1376×1032" → where
        for (i, size) in AppBuildHost.sweep.enumerated() {
            let (app, f) = try LibraryPartRowsHostedTests.arms(root: tmp.appendingPathComponent("\(i)", isDirectory: true))
            let part = try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"])), "the lookalike's part")
            app.library.route = .part(part.id)
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(2.5)
            let up = try h.probe("library-upload", "\(size): ★ Upload new version",
                                 covers: ["library-compare", "library-open", "library-open-menu"])
            for k in ["library-compare", "library-open", "library-open-menu"] {
                guard let other = h.frames.all[k] else { continue }
                XCTAssertFalse(up.insetBy(dx: 0.5, dy: 0.5).intersects(other), "\(size): Upload new version runs into \(k): \(up) vs \(other)")
            }
            // beside Compare when the top row has room; else it leads the filter row, under the top row (which stays as it was)
            let compare = try XCTUnwrap(h.frames.all["library-compare"], "\(size): Compare")
            if up.midY > compare.minY && up.midY < compare.maxY {
                XCTAssertLessThanOrEqual(up.maxX, compare.minX + 0.5, "\(size): it sits just before Compare")
            } else {
                XCTAssertGreaterThanOrEqual(up.minY, compare.maxY - 0.5, "\(size): under the top row")
                if let sort = h.frames.all["library-sort"] {
                    XCTAssertLessThan(up.maxX, sort.minX, "\(size): at the filter row's left end")
                    XCTAssertTrue(up.midY > sort.minY && up.midY < sort.maxY, "\(size): in the filter row")
                }
            }
            placed["\(Int(size.width))×\(Int(size.height))"] = up.midY > compare.minY && up.midY < compare.maxY ? "beside Compare" : "leads the filter row"
        }
        // every window offers it; where the top row has room, it is beside Compare (13″ landscape at least)
        XCTAssertEqual(placed["1376×1032"], "beside Compare")
        print("★ Upload new version, where: \(placed.map { "\($0.key) \($0.value)" }.sorted())")
    }
}
#endif
