// Tests for the optimization-playback video export. The frame render
// (renderOffscreen) + AVAssetWriter encode both work headlessly on macOS, so the
// exporter is validated end-to-end (a real .mp4 with a video track is produced);
// the export state machine is driven through injected synchronous seams.
import XCTest
import AVFoundation
@testable import TopOptFlows

@MainActor
final class PlaybackVideoTests: XCTestCase {

    private func triangle(scale: Float) -> ViewerMesh {
        ViewerMesh(vertices: [0, 0, 0, scale, 0, 0, 0, scale, 0], indices: [0, 1, 2], faceIDs: [])
    }

    func testExporterProducesAValidMP4() throws {
        let keyframes = [triangle(scale: 10), triangle(scale: 8), triangle(scale: 6)]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-playbacktest-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        try VideoExporter(size: 64, fps: 30, framesPerKeyframe: 3).export(keyframes: keyframes, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "the .mp4 is non-empty")
        // A real video: one video track, non-zero duration.
        let asset = AVAsset(url: url)
        XCTAssertFalse(asset.tracks(withMediaType: .video).isEmpty, "has a video track")
        XCTAssertGreaterThan(asset.duration.seconds, 0, "non-zero duration")
    }

    func testExporterRejectsEmptyKeyframes() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x.mp4")
        XCTAssertThrowsError(try VideoExporter().export(keyframes: [], to: url)) { err in
            XCTAssertEqual(err as? VideoExportError, .noFrames)
        }
    }

    func testExportModelSucceeds() {
        var captured: (count: Int, url: URL)?
        let m = VideoExportModel(
            encode: { kf, url in captured = (kf.count, url) },
            runInBackground: { $0() }, runOnMain: { $0() })   // synchronous
        XCTAssertEqual(m.state, .idle)

        m.export(keyframes: [triangle(scale: 1), triangle(scale: 1)], name: "Wall Bracket")
        guard case let .ready(url) = m.state else { return XCTFail("expected .ready") }
        XCTAssertEqual(captured?.count, 2)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".mp4"))
        XCTAssertTrue(url.lastPathComponent.contains("Wall_Bracket"), "spaces sanitized into the name")

        m.reset()
        XCTAssertEqual(m.state, .idle)
    }

    func testExportModelSurfacesFailures() {
        let fail = VideoExportModel(
            encode: { _, _ in throw VideoExportError.encodeFailed },
            runInBackground: { $0() }, runOnMain: { $0() })
        fail.export(keyframes: [triangle(scale: 1)], name: "X")
        guard case .failed = fail.state else { return XCTFail("expected .failed") }

        // No keyframes → a failure, no encode attempted.
        var encodeCalled = false
        let empty = VideoExportModel(
            encode: { _, _ in encodeCalled = true },
            runInBackground: { $0() }, runOnMain: { $0() })
        empty.export(keyframes: [], name: "X")
        guard case .failed = empty.state else { return XCTFail("expected .failed for no frames") }
        XCTAssertFalse(encodeCalled)
    }
}
