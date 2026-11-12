// FlexibleNewModelRefindTests — "Upload new version" on a Flexible part, step B (his pick 2 of 2026-11-12): an edge or corner
// press drawn on the old model is RE-FOUND on the new model where the faces it joined still meet, else it waits for a face.
// On his pad (A1_0003) with a real edges group picked (SquishHost.pad, edges: true: the edge of the top and the front): the
// press re-found on the page's own edge list, its settings kept; RED CONTROL: its faces matched to two faces that do not meet
// (the top and the underside) — it waits in the lost list.
#if canImport(AppKit)
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleNewModelRefindTests: XCTestCase {

    func match(_ m: [Int: [Int]]) -> FaceMatch {
        FaceMatch(map: Dictionary(uniqueKeysWithValues: m.map { (FaceID($0.key), $0.value.map { FaceID($0) }) }))
    }

    /// The pure rule: a found strip goes in (an arrow on the halfway takes the new halfway); one not found waits; the list empties.
    func testFoundStripsGoInAndTheRestWait() {
        let a = UUID(), b = UUID()
        let old = FlexibleStrip(kind: .edge, label: "Edge 9", order: 1,
                                members: [.init(face: 1, root: 1, origin: .zero, away: [SIMD3(1, 0, 0)], capMM: 5)],
                                halfway: SIMD3(0, 0, -1))
        var s = FlexibleStageSettings()
        s.presses = [FlexiblePress(id: a, regions: [2_000_001], direction: SIMD3(0, 0, -1), snap: FlexiblePress.Snap.halfway.raw,
                                   settings: FlexibleFaceSettings(faceRegionID: 2_000_001, weightKg: 8), strip: old),
                     FlexiblePress(id: b, regions: [2_000_003], direction: SIMD3(1, 0, 0),
                                   settings: FlexibleFaceSettings(faceRegionID: 2_000_003), strip: old)]
        s.newModel = FlexibleNewModelState(refind: [a, b])
        var new = old
        new.label = "Edge 4"
        new.halfway = SIMD3(0, -0.6, -0.8)
        FlexibleStageModel.applyRefind(&s, held: s.presses ?? [], found: [a: new])
        XCTAssertEqual(s.presses?.map(\.id), [a])
        XCTAssertEqual(s.presses?.first?.strip?.label, "Edge 4", "★ its strip made again on the new model")
        XCTAssertEqual(s.presses?.first?.direction, SIMD3(0, -0.6, -0.8), "★ an arrow on the halfway takes the new halfway")
        XCTAssertEqual(s.presses?.first?.settings.weightKg, 8, "every setting kept")
        XCTAssertEqual(s.newModel?.lostPresses.map(\.id), [b], "★ one not re-found waits for a face")
        XCTAssertEqual(s.newModel?.refind, [], "the list is done")
    }

    /// The re-find, run to its end with the run loop pumped (SquishHost's way: a synchronous test, so the page's own main-actor
    /// work can run while it waits — an async test would hold the main actor and the scene would never open).
    func refind(_ m: FlexibleStageModel) {
        FlexibleStageModel.traceRefind = true
        defer { FlexibleStageModel.traceRefind = false }
        var done = false
        Task { @MainActor in await m.refindNewModelPresses(); done = true }
        XCTAssertTrue(SquishHost.pumpUntil(240) { done }, "the re-find ran")
        SquishHost.pump(0.3)
    }

    /// ★ His pad with an edges group: re-found on the page's own edge list (RED CONTROL: two faces that do not meet → lost).
    func testHisPadsEdgeIsReFoundWhereItsFacesMeet() throws {
        let (_, m) = try SquishHost.pad(self, edges: true)
        let before = try XCTUnwrap(m.settings.presses?.first { $0.strip != nil }, "premise: the edges group's press")
        let faces = Set(try XCTUnwrap(before.strip).members.map(\.face))
        XCTAssertEqual(faces, [1, 2], "premise: the top and the front")
        let ids = (0..<6).reduce(into: [Int: [Int]]()) { $0[$1] = [$1] }

        // the same faces (the new model is the old one): re-found, its settings kept
        m.edit({ s in s = FlexibleNewModel.carry(s, match: self.match(ids), faceRegions: m.project.faceRegions) }, recompute: false)
        XCTAssertEqual(m.settings.newModel?.refind, [before.id], "premise: listed to re-find")
        refind(m)
        let after = try XCTUnwrap(m.settings.press(before.id), "★ the press is still there")
        XCTAssertEqual(Set(try XCTUnwrap(after.strip).members.map(\.face)), faces, "★ on the same two faces")
        XCTAssertEqual(after.settings, before.settings, "★ every setting kept")
        XCTAssertNil(m.settings.newModel, "nothing waits")
        print("FLEX-UPLOAD re-found: \(before.strip?.label ?? "-") → \(after.strip?.label ?? "-")")

        // ★ RED CONTROL: the front matched to the underside — the top and the underside do not meet: the press waits
        var lost = ids
        lost[2] = [0]
        m.edit({ s in s = FlexibleNewModel.carry(s, match: self.match(lost), faceRegions: m.project.faceRegions) }, recompute: false)
        refind(m)
        XCTAssertNil(m.settings.press(before.id), "RED CONTROL: not on the page")
        XCTAssertEqual(m.settings.newModel?.lostPresses.map(\.id), [before.id], "★ it waits for its edge, settings and all")
    }
}
#endif
