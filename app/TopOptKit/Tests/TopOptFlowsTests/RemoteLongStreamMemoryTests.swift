// RemoteLongStreamMemoryTests — the handoff-119 long-stream retention audit, in CI.
//
// A 7-hour remote run's client was Jetsam-killed; the unproven half of that incident
// was what the client RETAINS across a multi-hour stream. We cannot reproduce a
// 7-hour run in-session, so this proves the property that matters SYNTHETICALLY:
// drive THOUSANDS of `progress` events (a 7-hour run emits thousands of these but
// only ~4 variants) through the REAL SSE parse + dedupe delegate path and assert the
// retained collections stay FLAT — retention is O(1)+O(ladder), never O(events).
//
// This is the honest bound the retention-audit block in RemoteRunner.swift documents;
// the per-rung os_signpost checkpoint added alongside it proves the same on the NEXT
// real long run in Instruments. It exercises no network (progress events fetch no
// mesh), so it runs in the normal `xcodebuild test` suite.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RemoteLongStreamMemoryTests: XCTestCase {

    private func makeRun(onProgress: @escaping () -> Void) -> RemoteRun {
        let config = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "fp")
        let request = RunRequest(modelPath: "/tmp/x.step", material: "PLA",
                                 materialsPath: "", rulesPath: "", resolution: 32,
                                 projectName: "Long")
        return RemoteRun(config: config, request: request,
                         progress: { _, _, _ in onProgress(); return true },
                         onVariant: { _ in })
    }

    /// A non-resumed data task — a stable identity token for the delegate's
    /// per-connection replay bookkeeping (never touches the network).
    private func dummyTask() -> URLSessionDataTask {
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1/x")!)
    }

    private func progressFrame(rung: Int, rungs: Int, iter: Int) -> Data {
        Data("data: {\"type\":\"progress\",\"rung\":\(rung),\"rungs\":\(rungs),\"iter\":\(iter)}\n\n".utf8)
    }

    /// The core assertion: across thousands of progress events, the client retains
    /// only an integer high-water mark — the dedupe never accumulates event bodies,
    /// no variant meshes are held for a progress-only stream, and the parse buffer is
    /// fully drained. The retained collections do NOT grow with the event count.
    func testThousandsOfProgressEventsRetainOnlyABoundedHighWaterMark() {
        var progressCalls = 0
        let run = makeRun { progressCalls += 1 }
        let task = dummyTask()

        let N = 5_000
        for i in 1...N { run.testFeedSSE(progressFrame(rung: 0, rungs: 4, iter: i), task: task) }

        XCTAssertEqual(progressCalls, N, "every progress event reached the callback")
        XCTAssertEqual(run.testDeliveredEventCount, N, "dedup high-water == events seen (an Int)")
        XCTAssertEqual(run.testStreamedVariantCount, 0, "no variant meshes retained by a progress stream")
        XCTAssertEqual(run.testSeenMeshCount, 0, "no mesh basenames retained")
        XCTAssertEqual(run.testRetainedBufferBytes, 0, "the SSE buffer is drained frame-by-frame")
    }

    /// A reconnect replays every event from index 0 (worker behaviour, handoff 093).
    /// The dedupe must swallow the ENTIRE replay: no event re-delivered, no collection
    /// grows a second time — the property that keeps a flaky multi-hour run bounded.
    func testReconnectReplayIsDedupedAndAddsNoRetention() {
        var progressCalls = 0
        let run = makeRun { progressCalls += 1 }

        let N = 3_000
        let first = dummyTask()
        for i in 1...N { run.testFeedSSE(progressFrame(rung: 0, rungs: 4, iter: i), task: first) }
        XCTAssertEqual(progressCalls, N)
        XCTAssertEqual(run.testDeliveredEventCount, N)

        // Reconnect: a NEW task replays the same N events from the start.
        let second = dummyTask()
        for i in 1...N { run.testFeedSSE(progressFrame(rung: 0, rungs: 4, iter: i), task: second) }

        XCTAssertEqual(progressCalls, N, "the replay was fully deduped — no double-delivery")
        XCTAssertEqual(run.testDeliveredEventCount, N, "high-water unchanged across the reconnect")
        XCTAssertEqual(run.testRetainedBufferBytes, 0)
    }

    /// A frame split across two chunks (TCP does not respect SSE frame boundaries) is
    /// buffered then parsed once complete — the buffer holds at most a partial frame,
    /// never the stream.
    func testPartialFrameIsBufferedThenParsedNotLeaked() {
        var progressCalls = 0
        let run = makeRun { progressCalls += 1 }
        let task = dummyTask()

        let whole = progressFrame(rung: 1, rungs: 4, iter: 7)
        let split = whole.count / 2
        run.testFeedSSE(whole.prefix(split), task: task)
        XCTAssertEqual(progressCalls, 0, "an incomplete frame is not yet delivered")
        XCTAssertGreaterThan(run.testRetainedBufferBytes, 0, "the partial frame is buffered")

        run.testFeedSSE(whole.suffix(from: whole.startIndex.advanced(by: split)), task: task)
        XCTAssertEqual(progressCalls, 1, "the completed frame is delivered exactly once")
        XCTAssertEqual(run.testRetainedBufferBytes, 0, "buffer drained after the frame completes")
    }

    /// The per-rung checkpoint's footprint reader returns a real number on the test
    /// host (Darwin), so the os_signpost markers a long run emits carry live data.
    func testResidentFootprintReaderReturnsALiveValue() {
        XCTAssertGreaterThan(RemoteRun.residentFootprintBytes(), 0,
                             "phys_footprint feeds the per-rung memory signpost")
    }
}
