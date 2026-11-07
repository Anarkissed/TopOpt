// LibraryClearPicturesTests — B5 (his "look per screen"): a part's picture sits on its card's own gradient (mockup
// #lib-project), so it is drawn on a CLEAR background. Pictures cached before that were drawn on the dark stage, a black
// square on every card: each still shows until it is redrawn clear (a result from its version's results file, the original
// from its model), then the opaque file goes.

import XCTest
import CoreGraphics
import ImageIO
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LibraryClearPicturesTests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("topopt-lib-clear-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: root)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    // MARK: fixtures

    /// A 60 × 30 × 20 mm box: 8 corners, 12 triangles.
    static func box() -> (vertices: [Float], indices: [Int32]) {
        let (x, y, z): (Float, Float, Float) = (60, 30, 20)
        let v: [Float] = [0, 0, 0, x, 0, 0, x, y, 0, 0, y, 0, 0, 0, z, x, 0, z, x, y, z, 0, y, z]
        let i: [Int32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
                          2, 3, 7, 2, 7, 6, 1, 2, 6, 1, 6, 5, 3, 0, 4, 3, 4, 7]
        return (v, i)
    }

    /// One part, grouped: its STL model, and (optimized) two box results.
    private func part(optimized: Bool) throws -> (LibraryModel, UUID) {
        let src = root.appendingPathComponent("import", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("part.stl")
        try Data("solid box".utf8).write(to: model)
        let snap = ProjectSnapshot(id: UUID(), name: "Carriage Arms", material: "PA12", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "Carriage Arms.stl",
                                   savedAt: Date(timeIntervalSince1970: 1), selection: SelectionModel(),
                                   force: ForceModel(), quality: .fast, optimized: optimized ? true : nil)
        try store.save(snap, modelSource: model)
        try fm.removeItem(at: src)
        if optimized {
            let b = Self.box()
            let variants = [1.0, 0.8].map { f in
                OptimizeVariant(requestedVolumeFraction: f, achievedVolumeFraction: f, massGrams: 10 * f,
                                supportVolumeVoxels: 0, meshTriangleCount: 12, worstCaseMargin: 2, accepted: true,
                                v3Passes: true, meshVertices: b.vertices, meshIndices: b.indices)
            }
            let o = OptimizeOutcome(variants: variants, stoppedOnMargin: false, cancelled: false, acceptedCount: 2,
                                    voxelVolumeMM3: 1, gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
            try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)), id: snap.id)
        }
        let lib = LibraryModel(store: store)
        lib.refresh()
        try lib.group(projectName: "Squish Mechanism", partIDs: nil)
        return (lib, snap.id)
    }

    /// A picture cached before B5: a small square on the dark stage.
    private func writeOpaque(to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// Every pixel's alpha, read through a known RGBA layout: the four corners, and the most solid one.
    nonisolated static func alphas(_ image: CGImage) -> (corners: [UInt8], max: UInt8) {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ([], 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return ([], 0) }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let a = { (i: Int) in px[i * 4 + 3] }
        return ([a(0), a(w - 1), a((h - 1) * w), a(h * w - 1)], (0..<(w * h)).map(a).max() ?? 0)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done(), what)
    }

    private func loadSummaries(_ lib: LibraryModel) {
        let exp = expectation(description: "pictures")
        lib.loadSummaries { exp.fulfill() }
        wait(for: [exp], timeout: 20)
    }

    // MARK: tests

    func testAResultsPictureIsDrawnOnAClearBackground() throws {
        let (lib, folder) = try part(optimized: true)
        loadSummaries(lib)
        let a = Self.alphas(try XCTUnwrap(lib.thumbnails[CompareItem(folder: folder, result: 0)], "v1 a's picture"))
        XCTAssertEqual(a.corners, [0, 0, 0, 0], "★ clear around the part: the card's gradient shows, not a black square")
        XCTAssertEqual(a.max, 255, "the part itself is solid")
    }

    func testAnOldOpaquePictureStillShowsUntilItIsRedrawnClear() throws {
        let (lib, folder) = try part(optimized: true)
        loadSummaries(lib)
        // a Library from before B5: its pictures were cached opaque, under the old name
        for f in try fm.contentsOfDirectory(atPath: lib.cacheDir.path) {
            try fm.removeItem(at: lib.cacheDir.appendingPathComponent(f))
        }
        let old = lib.cacheDir.appendingPathComponent("\(folder.uuidString)-0.png")
        try writeOpaque(to: old)
        let item = CompareItem(folder: folder, result: 0)
        let again = LibraryModel(store: store)
        again.refresh()
        waitUntil("the old picture is read") { again.thumbnails[item] != nil }
        XCTAssertEqual(again.thumbnails[item]?.width, 8, "★ an old picture still shows until it is redrawn (never a blank card)")
        loadSummaries(again)
        let img = try XCTUnwrap(again.thumbnails[item])
        XCTAssertEqual(img.width, 400, "★ redrawn from the version's results")
        XCTAssertEqual(Self.alphas(img).corners, [0, 0, 0, 0], "★ clear")
        XCTAssertNotNil(again.thumbnails[CompareItem(folder: folder, result: 1)], "a picture missing altogether is drawn too")
        XCTAssertFalse(fm.fileExists(atPath: old.path), "the opaque file goes once its clear one is drawn")
    }

    func testAnOldOriginalPictureIsRedrawnClearFromItsModel() throws {
        let (lib, folder) = try part(optimized: false)
        let old = lib.cacheDir.appendingPathComponent("\(folder.uuidString)--1.png")
        try writeOpaque(to: old)
        let item = CompareItem(folder: folder, result: LibraryModel.originalResult)
        let again = LibraryModel(store: store)
        again.refresh()
        waitUntil("the old original is read") { again.thumbnails[item] != nil }
        XCTAssertEqual(again.thumbnails[item]?.width, 8, "★ it still shows until it is redrawn")
        let b = Self.box()
        again.originalMeshLoader = { _ in ViewerMesh(vertices: b.vertices, indices: b.indices, faceIDs: []) }
        again.drawMissingOriginals()
        waitUntil("★ the original is redrawn from its model") { again.thumbnails[item]?.width == 400 }
        if let img = again.thumbnails[item] { XCTAssertEqual(Self.alphas(img).corners, [0, 0, 0, 0], "★ clear") }
        XCTAssertFalse(fm.fileExists(atPath: old.path), "the opaque file goes")
    }
}
