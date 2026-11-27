// The workspace body must stay small enough for the iPad's main-thread stack (crash 2026-10-25).
//
// His iPad crashed opening any project: SwiftUI copied WorkspacePlaceholder's 47 KB body value through generic
// code on the main thread's stack (and demangled bottomBar's nested type) until the stack guard was hit. macOS
// test hosts have an 8 MB main stack, so no hosted test saw it. H57 type-erases the bottom bar's chain; H58 boxes
// the body's children in heap chunks (AnyView), which brings the body value to a few dozen bytes.
import XCTest
import SwiftUI
@testable import TopOptFlows

@MainActor
final class WorkspaceBodySizeTests: XCTestCase {
    /// The body's own value stays tiny: everything heavy lives in heap-boxed chunks (H58). RED before H58: 46,864 bytes.
    func testTheWorkspaceBodyValueStaysSmallForTheIPadStack() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let body = WorkspacePlaceholder(model: r.app, project: r.project).body
        let size = MemoryLayout.size(ofValue: body)
        XCTAssertLessThan(size, 1024, "the workspace body value is \(size) bytes; keep its children in AnyView chunks (H58)")
    }

    /// ★ 11-20 (his iPad crashed opening any older CarriageArms version, the ones with load scenarios): the workspace VIEW
    /// itself must not grow. Its size is known only at run time (SwiftUI's State is resilient), so every copy of it on the
    /// main thread is a run-time stack allocation of its whole size, and the scenario folders' path makes many: Organic cut 2's
    /// 170-byte `@State certifyWalk` was enough to run off the stack. New state goes in a reference (the app model, a
    /// StateObject), never as another @State here. RED CONTROL: with the walk as @State, this was over the ceiling.
    func testTheWorkspaceViewItselfDoesNotGrow() {
        let size = MemoryLayout<WorkspacePlaceholder>.size
        let results = MemoryLayout<ResultsScreen>.size
        print("WORKSPACE STRUCT: WorkspacePlaceholder \(size) bytes, ResultsScreen \(results) bytes, the walk as @State "
              + "\(MemoryLayout<State<OrganicCertify.Walk?>>.size) bytes, the card as a struct would be about "
              + "\(MemoryLayout<OrganicCertify.Issue>.size + MemoryLayout<OrganicSpotGrid?>.size + 64) bytes")
        XCTAssertLessThanOrEqual(size, Self.workspaceCeiling,
                                 "WorkspacePlaceholder is \(size) bytes: move the new state into a reference, not a @State")
        XCTAssertLessThanOrEqual(results, Self.resultsCeiling,
                                 "ResultsScreen is \(results) bytes: move the new state into a reference, not a @State")
    }
    /// Release (10)'s size, measured on the Mac (it opened every version on his iPad; release (11) at 22,120, the walk's 152
    /// bytes more, did not), and Results' after cut 2 with its additions held by reference. Do not raise these: make room.
    static let workspaceCeiling = 21_968
    static let resultsCeiling = 1_632

    /// H57 and H58 are in place, each its own chunk boundary.
    func testTheChunkHooksArePinned() throws {
        let ws = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/TopOptFlows/WorkspacePlaceholder.swift").standardizedFileURL, encoding: .utf8)
        XCTAssertEqual(ws.components(separatedBy: "AnyView(Group {   // Flexible (PR #362) H58").count - 1, 6, "six heap chunks in the body")
        XCTAssertEqual(ws.components(separatedBy: "})   // Flexible (PR #362) H58").count - 1, 6)
        XCTAssertEqual(ws.components(separatedBy: "AnyView(Group {   // Flexible (PR #362) H57").count - 1, 1, "the bottom bar's chain, erased")
        XCTAssertTrue(ws.contains("AnyView(topologyCornerPair)   // Flexible (PR #362) H57"))
    }
}
