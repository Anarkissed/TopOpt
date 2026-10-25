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
