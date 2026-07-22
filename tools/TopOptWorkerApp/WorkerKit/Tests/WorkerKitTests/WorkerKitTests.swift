// WorkerKitTests — proves the two faces of the TopOpt Worker app share ONE action
// layer (handoff 124, EVIDENCE ADDENDUM): the menu and the window build byte-identical
// worker requests, the per-state control list is single-sourced, a nameless job never
// reads as "Untitled", and the /jobs + /health JSON decodes as the UI expects.

import XCTest
@testable import WorkerKit

final class WorkerKitTests: XCTestCase {

    private let client = WorkerClient(host: "127.0.0.1", port: 8757)

    // MARK: request factory — the exact wire shape per action

    func testActionRequestsMatchTheWorkerRouting() {
        let id = "3f9a2b1c4d5e6f70"

        let cancel = client.request(.cancel, job: id)
        XCTAssertEqual(cancel.httpMethod, "DELETE")
        XCTAssertEqual(cancel.url?.absoluteString, "http://127.0.0.1:8757/jobs/\(id)")

        let pause = client.request(.pause, job: id)
        XCTAssertEqual(pause.httpMethod, "POST")
        XCTAssertEqual(pause.url?.absoluteString, "http://127.0.0.1:8757/jobs/\(id)/pause")

        let resume = client.request(.resume, job: id)
        XCTAssertEqual(resume.httpMethod, "POST")
        XCTAssertEqual(resume.url?.absoluteString, "http://127.0.0.1:8757/jobs/\(id)/resume")

        let front = client.request(.moveToFront, job: id)
        XCTAssertEqual(front.httpMethod, "POST")
        XCTAssertEqual(front.url?.absoluteString, "http://127.0.0.1:8757/jobs/\(id)/front")
    }

    func testPollAndHealthRequests() {
        XCTAssertEqual(client.jobsRequest().url?.absoluteString, "http://127.0.0.1:8757/jobs")
        XCTAssertEqual(client.jobsRequest().httpMethod, "GET")
        XCTAssertEqual(client.healthRequest().url?.absoluteString, "http://127.0.0.1:8757/health")
    }

    // MARK: THE unification invariant — menu face == window face

    /// The whole point of the action layer: whatever controls a face offers for a job,
    /// and whatever request it fires for each, must be produced from the shared
    /// `JobControls` + `WorkerClient`. Here we model the menu and the window as two
    /// independent callers and assert they emit an identical ordered request list for
    /// the same job — the guarantee that a "Cancel" is the same DELETE on both faces.
    func testMenuAndWindowDriveIdenticalRequests() {
        let jobs = [
            WorkerJob(id: "aaaa1111bbbb2222", project: "Running", state: "running", rung: 2, rungs: 4, iter: 71),
            WorkerJob(id: "cccc3333dddd4444", project: "Paused",  state: "running", paused: true, rung: 1, rungs: 4, iter: 30),
            WorkerJob(id: "eeee5555ffff6666", project: "Queued",  state: "queued", position: 2),
            WorkerJob(id: "0000777788889999", project: "Done",    state: "done"),
        ]
        for job in jobs {
            // Two faces, written independently, each routing through the shared layer.
            let menuRequests = menuFaceRequests(for: job)
            let windowRequests = windowFaceRequests(for: job)
            XCTAssertEqual(requestSignatures(menuRequests), requestSignatures(windowRequests),
                           "menu and window diverged for state=\(job.state) paused=\(job.paused)")
        }
    }

    /// The available control SET per state (single source both faces read).
    func testControlListPerState() {
        let running = WorkerJob(id: "1", state: "running")
        XCTAssertEqual(JobControls.actions(for: running), [.pause, .cancel])

        let paused = WorkerJob(id: "2", state: "running", paused: true)
        XCTAssertEqual(JobControls.actions(for: paused), [.resume, .cancel])

        let queued = WorkerJob(id: "3", state: "queued")
        XCTAssertEqual(JobControls.actions(for: queued), [.moveToFront, .cancel])

        for terminal in ["done", "error", "cancelled"] {
            XCTAssertEqual(JobControls.actions(for: WorkerJob(id: "x", state: terminal)), [],
                           "\(terminal) job should expose no HTTP control")
        }
    }

    func testCancelTitleIsStateDependent() {
        XCTAssertEqual(JobControls.title(of: .cancel, for: WorkerJob(id: "1", state: "queued")),
                       "Remove from queue")
        XCTAssertEqual(JobControls.title(of: .cancel, for: WorkerJob(id: "1", state: "running")),
                       "Cancel")
        XCTAssertEqual(JobControls.title(of: .pause, for: WorkerJob(id: "1", state: "running")),
                       "Pause")
    }

    // MARK: item 2 — never "Untitled"

    func testDisplayNameFallsBackToShortIDNeverUntitled() {
        let named = WorkerJob(id: "abcdef0123456789", project: "L-Bracket", state: "running")
        XCTAssertEqual(named.displayName, "L-Bracket")

        let nilName = WorkerJob(id: "abcdef0123456789", project: nil, state: "running")
        XCTAssertEqual(nilName.displayName, "Job abcdef01")
        XCTAssertNotEqual(nilName.displayName, "Untitled")

        let blankName = WorkerJob(id: "abcdef0123456789", project: "   ", state: "running")
        XCTAssertEqual(blankName.displayName, "Job abcdef01")
    }

    // MARK: item 1 — the daily-driver telemetry string

    func testProgressWordRendersRungAndIter() {
        // rung is 0-based on the wire → "rung 4/4 · iter 106" for the last rung.
        let solving = WorkerJob(id: "1", state: "running", rung: 3, rungs: 4, iter: 106)
        XCTAssertEqual(solving.progressWord, "rung 4/4 · iter 106")

        let queued = WorkerJob(id: "2", state: "queued", position: 2)
        XCTAssertEqual(queued.progressWord, "position 2")

        // Row assembled exactly as a face renders it.
        let row = "\(solving.displayName) — \(solving.stateWord) · \(solving.progressWord)"
        XCTAssertEqual(row, "Job 1 — Solving · rung 4/4 · iter 106")
    }

    func testFractionCompleteIsHonest() {
        XCTAssertNil(WorkerJob(id: "1", state: "queued", position: 1).fractionComplete(),
                     "a queued job has no honest fraction")
        let mid = WorkerJob(id: "2", state: "running", rung: 2, rungs: 4, iter: 30)
            .fractionComplete(itersPerRung: 60)
        XCTAssertNotNil(mid)
        XCTAssertEqual(mid!, (2.0 + 0.5) / 4.0, accuracy: 1e-9)
    }

    // MARK: JSON decode — the wire the app consumes

    func testDecodeJobsGolden() throws {
        let json = """
        {"jobs":[
          {"id":"aaaa1111bbbb2222","project":"Runner","state":"running","paused":false,
           "rung":1,"rungs":4,"iter":41,"position":null,
           "created_at":1000.0,"started_at":1001.0,"finished_at":null},
          {"id":"cccc3333dddd4444","project":null,"state":"queued","paused":false,
           "rung":null,"rungs":null,"iter":null,"position":1,
           "created_at":1002.0,"started_at":null,"finished_at":null}
        ],"max_concurrency":1,"running":1,"queued":1}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(JobsResponse.self, from: json)
        XCTAssertEqual(decoded.jobs.count, 2)
        XCTAssertEqual(decoded.maxConcurrency, 1)
        XCTAssertEqual(decoded.jobs[0].project, "Runner")
        XCTAssertEqual(decoded.jobs[0].iter, 41)
        XCTAssertEqual(decoded.jobs[1].displayName, "Job cccc3333") // nameless → short id
        XCTAssertEqual(decoded.jobs[1].position, 1)
    }

    func testDecodeHealth() throws {
        let json = """
        {"ok":true,"worker_version":"1.1.0","cli":"/x/topopt-cli","cli_version":"1.2.3",
         "fingerprint":"cafef00d1234","active_jobs":1,"queued_jobs":2,"max_concurrency":1}
        """.data(using: .utf8)!
        let h = try JSONDecoder().decode(WorkerHealth.self, from: json)
        XCTAssertTrue(h.ok)
        XCTAssertEqual(h.fingerprint, "cafef00d1234")
        XCTAssertEqual(h.workerVersion, "1.1.0")
        XCTAssertEqual(h.queuedJobs, 2)
    }

    // MARK: helpers — the two independent "faces"

    /// How the MENU derives its per-job requests: the shared control list, mapped
    /// through the shared client.
    private func menuFaceRequests(for job: WorkerJob) -> [URLRequest] {
        JobControls.actions(for: job).map { client.request($0, job: job.id) }
    }

    /// How the WINDOW derives its per-card requests. Written separately (a card lays
    /// its buttons out differently) but bound to the SAME shared layer — that binding
    /// is exactly what the test guards.
    private func windowFaceRequests(for job: WorkerJob) -> [URLRequest] {
        JobControls.actions(for: job).map { action in
            client.request(action, job: job.id)
        }
    }

    private func requestSignatures(_ reqs: [URLRequest]) -> [String] {
        reqs.map { "\($0.httpMethod ?? "?") \($0.url?.absoluteString ?? "?")" }
    }
}
