// Notes23SampleTimerTests — his iPad notes 2026-11-22 (afternoon, on release 13), img 46: the Lattice settings' sample said
// "Building the sample…" with no sense of how long. The caption now counts the time once a second while it builds ("Building
// the sample · 12 s", that line alone re-drawn), and once built says how long it took beside it, quieter ("Built in 14 s"):
// on the sample's own caption, never a line of the screen.
import XCTest
import SwiftUI
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

final class Notes23SampleTimerTests: XCTestCase {

    /// The words: the time so far, then how long it took; five words at most (the time counts as one).
    func testTheSampleSaysItsTimeInFewWords() {
        XCTAssertEqual(LatticeSampleView.buildingLine(elapsed: 0.4), "Building the sample\u{2026}", "under a second: as before")
        XCTAssertEqual(LatticeSampleView.buildingLine(elapsed: 12.7), "Building the sample \u{00B7} 12 s")
        XCTAssertEqual(LatticeSampleView.buildingLine(elapsed: 65), "Building the sample \u{00B7} 1:05")
        XCTAssertEqual(LatticeSampleView.builtLabel(seconds: 1.73), "Built in 1.7 s")
        XCTAssertEqual(LatticeSampleView.builtLabel(seconds: 14.2), "Built in 14 s")
        XCTAssertEqual(LatticeSampleView.builtLabel(seconds: 546.2), "Built in 9:06")
        for s in [0.5, 3.0, 14.0, 59.9, 546.0, 3261.0] {
            for line in [LatticeSampleView.buildingLine(elapsed: s), LatticeSampleView.builtLabel(seconds: s)] {
                let words = line.replacingOccurrences(of: " s", with: "").split(separator: " ").filter { $0 != "\u{00B7}" }
                XCTAssertLessThanOrEqual(words.count, 5, "★ five words at most: \(line)")
            }
        }
    }

    /// Only the caption ticks (a TimelineView, once a second, around that one Text), and nothing is detached.
    func testOnlyTheCaptionTicks() throws {
        let src = try FlexibleSource.code("LatticeSampleView.swift")
        let r = try XCTUnwrap(src.range(of: "@ViewBuilder private var captionLine: some View {"))
        let body = String(src[r.upperBound...].prefix(700))
        XCTAssertTrue(body.contains("TimelineView(.periodic(from: start, by: 1))"), "★ once a second, this line only")
        XCTAssertTrue(src.contains("captionLine\n                    .font(.system(size: 12.5))"), "the caption's own capsule")
        XCTAssertFalse(src.contains("Task.detached"))
    }

    #if canImport(AppKit) && canImport(MetalKit)
    private final class Probe { var all: [String: CGRect] = [:] }

    /// ★ Hosted, both of his sizes: the sample builds, then "Built in …" stays on its caption, inside the caption's capsule at
    /// the sample's foot (never across the screen).
    @MainActor
    func testTheSampleThenSaysHowLongItTook() throws {
        let was = FlexibleSaid.recording, logDir = GenerationTimingLog.shared.directory
        FlexibleSaid.recording = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("timing-\(UUID().uuidString)")
        GenerationTimingLog.shared.directory = dir
        defer { FlexibleSaid.recording = was; GenerationTimingLog.shared.directory = logDir; try? FileManager.default.removeItem(at: dir) }
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            LatticeSampleView.recordedBuilt = []
            let pr = Probe()
            let inputs = LatticeSampleView.Inputs(shape: .cells, topology: "octet", typeName: "Octet truss", cellMM: 8, beadMM: 0.45)
            let h = AppBuildHost(LatticeSampleView(inputs: inputs).onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 },
                                 size: size, test: self)
            let end = Date().addingTimeInterval(90)
            while LatticeSampleView.recordedBuilt.isEmpty, Date() < end { h.pump(0.5) }
            h.pump(0.5)
            XCTAssertEqual(LatticeSampleView.recordedBuilt.count, 1, "\(size): ★ built once, and said: \(LatticeSampleView.recordedBuilt)")
            XCTAssertTrue(LatticeSampleView.recordedBuilt.first?.hasPrefix("Built in ") ?? false)
            let cap = try XCTUnwrap(pr.all["lattice-sample-caption"], "\(size): the caption")
            let built = try XCTUnwrap(pr.all["lattice-sample-built"], "\(size): ★ the time it took, on the sample")
            XCTAssertTrue(cap.insetBy(dx: -0.5, dy: -0.5).contains(built), "\(size): ★ inside the caption's capsule \(built) \(cap)")
            XCTAssertLessThan(cap.width, size.width - 2 * DS.Space.l, "\(size): never a line across the screen")
        }
        // ★ his 11-22 (GenerationTimingLog): each sample built is one "sample" line, done, with what it was built from
        GenerationTimingLog.shared.flush()
        let lines = GenerationTimingLog.shared.records().filter { $0["kind"] as? String == "sample" }
        XCTAssertEqual(lines.count, 2, "★ one line per sample built: \(lines.map { $0["outcome"] ?? "?" })")
        XCTAssertTrue(lines.allSatisfy { $0["outcome"] as? String == "done" })
        XCTAssertEqual(((lines.first?["inputs"] as? [String: Any])?["values"] as? [String: Any])?["topology"] as? String, "octet")
        // ★ RE-PINNED (notes26): the sample is laid now (LatticeSampleLay), so its steps are the lay's, not the coupon's triangles
        XCTAssertNotNil((lines.first?["stages"] as? [String: Any])?["layMS"])
    }
    #endif
}
