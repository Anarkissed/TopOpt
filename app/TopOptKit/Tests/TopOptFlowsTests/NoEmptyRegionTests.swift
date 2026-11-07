// NoEmptyRegionTests — B1, ledger note 38 (the app half) and O1 (approved design 2026-11-02).
//
// His A7C1E0C9: "topopt-cli: job.json: face region 107 …" — core refuses a face region that "declares neither a filter nor
// any "add" faces". Every UNION OF PIECES is such a region on the wire (it owns no faces; core does not know `parts`), and so
// is a piece left with no faces. His "Union of seven which won't lattice … an optimization will fail". Now: a union is named
// by its pieces, an empty region is never sent, and a role holding only a faceless piece is refused on the button before
// anything is sent. The job is read back exactly as the Mac would receive it (RemoteRun.buildJobJSON).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class NoEmptyRegionTests: XCTestCase {

    /// The A1 lookalike: his anchor group (Bottom) holds `regions`; Group C an anchor too (no group left pending).
    func project() throws -> FlexibleHisProject.Restored {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        r.project.lattice.flexible = nil
        r.project.lattice.chooseLatticeType(.structural)
        if let c = r.project.selection.groups.first(where: { $0.name == "Group C" }) { r.project.force.makeAnchor(c.id) }
        return r
    }

    func faceRegions(_ job: [String: Any]) -> [[String: Any]] {
        ((job["loads"] as? [String: Any])?["face_regions"] as? [[String: Any]]) ?? []
    }

    func testAUnionOfPiecesGoesAsItsPiecesAndNoRegionIsSentEmpty() throws {
        let r = try project()
        let p = r.project
        let bottom = try XCTUnwrap(p.selection.groups.first { $0.name == "Bottom" })
        let face = try XCTUnwrap(bottom.faces.first)
        // a face cut in two, and the two pieces made one again (Edit faces' Union of pieces)
        var m = p.faceRegions
        let whole = m.union(faces: [face], named: "Bottom face")
        let pieces = m.splitManual(whole, point: .zero, normal: SIMD3(1, 0, 0))
        XCTAssertEqual(pieces.count, 2)
        let joined = try XCTUnwrap(m.unionOfParts(pieces, named: "Union of two"))
        p.faceRegions = m
        p.selection.addRegions([joined], to: bottom.id)

        let req = try XCTUnwrap(r.app.makeRunRequest())
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(req)) as? [String: Any])
        let sent = faceRegions(job)
        // ★ core's own rule, on every region the Mac would receive
        for e in sent {
            let add = (e["add"] as? [Any]) ?? []
            XCTAssertTrue(!add.isEmpty || e["filter"] != nil, "★ region \(e["id"] ?? "?") declares neither a filter nor any add faces: core refuses it")
        }
        XCTAssertFalse(sent.contains { ($0["id"] as? Int) == joined }, "★ the union itself is never sent")
        let anchors = Set(((job["loads"] as? [String: Any])?["anchor_region_ids"] as? [Int]) ?? [])
        XCTAssertEqual(anchors, Set(pieces), "★ the anchor names the union's pieces (the same surface)")
        XCTAssertTrue(Set(pieces).isSubset(of: Set(sent.compactMap { $0["id"] as? Int })), "the pieces it names are sent")
    }

    func testAnAnchorHoldingOnlyAFacelessPieceIsRefusedOnTheButtonAndNothingIsSent() throws {
        let r = try project()
        let p = r.project
        let bottom = try XCTUnwrap(p.selection.groups.first { $0.name == "Bottom" })
        // a piece left with no faces (what face edits can leave behind), read back as a saved project would hold it
        var m = p.faceRegions
        let keep = m.union(faces: [try XCTUnwrap(bottom.faces.first)], named: "Bottom face")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        var regions = try XCTUnwrap(json["regions"] as? [[String: Any]])
        regions.append(["id": keep + 1, "name": "Empty piece", "filter": regions[0]["filter"] ?? [String: Any](), "filterMatchedAtAuthor": -1,
                        "add": [Int](), "remove": [Int](), "cuts": [Any](), "parentID": keep, "collapsed": true])
        json["regions"] = regions
        m = try JSONDecoder().decode(FaceRegionModel.self, from: JSONSerialization.data(withJSONObject: json))
        p.faceRegions = m
        p.selection.setRegions([keep + 1], for: bottom.id)
        XCTAssertEqual(FaceRegionSend.empty(p.faceRegions.regions), [keep + 1])
        XCTAssertEqual(p.runRegionIDs([keep + 1]), [], "a faceless piece names nothing on the wire")

        // ★ the job never carries it
        let req = try XCTUnwrap(r.app.makeRunRequest())
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(req)) as? [String: Any])
        XCTAssertFalse(faceRegions(job).contains { ($0["id"] as? Int) == keep + 1 }, "★ the empty region is never sent")

        // ★ and Optimize refuses on the button (a real click; nothing runs)
        final class Runs: @unchecked Sendable { var n = 0 }
        let runs = Runs()
        RunModel.hostedTestRunner = { _, _, _ in runs.n += 1; return AppBuildFixtures.outcome() }
        addTeardownBlock { RunModel.hostedTestRunner = nil }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        let f = try h.onScreen("optimizeSplit", "Optimize")
        h.click(CGPoint(x: f.minX + (f.width - 46) / 2, y: f.midY), settle: 1.5)
        XCTAssertEqual(runs.n, 0, "★ nothing was sent")
        XCTAssertEqual(p.run.phase, .idle)
    }
}
#endif
