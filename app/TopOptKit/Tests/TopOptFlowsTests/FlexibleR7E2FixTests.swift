// FlexibleR7E2FixTests — round 7, R7-E2 FIX: the two verifies' confirmed blocker and majors on E2 (after E1b), each with its RED
// CONTROL run inside the test.
//   F1 (blocker) a press grades the lattice only inside its flat prism (core's press column ran 140 mm through the part)
//   F2 the groups' estimate counts the presses, over their flat prisms only (an edges group halved Group 1, unsaid before Exit)
//   F3 the press card says core's "can't reach" and how far off the shape is for ANY press past 2 %
//   F4 a press kept out of the job is a blocker in the top line, with its card's fixes
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleR7E2Tests {

    /// F1, pure: a press's voxels past its plane are under no face; another owner's are untouched. RED CONTROL: E2 as built.
    func testFixAPressFieldIsClippedToItsFlatPrism() {
        let f = FlexDensityField(nx: 4, ny: 1, nz: 1, spacing: 1, origin: .zero, density: [0.3, 0.3, 0.3, 0.2], owner: [7, 7, 7, 3])
        let cut = FlexibleFlatPrism.Cut(apex: .zero, direction: SIMD3(1, 0, 0), depthMM: 1.5)
        let c = FlexibleGroupField.clipToPresses(f, cuts: [7: cut, 3: cut].filter { $0.key == 7 })
        XCTAssertEqual(c.density, [0.3, 0.3, 0, 0.2], "★ x 2.5 is past h 1.5: under no face; owner 3 untouched")
        XCTAssertEqual(c.owner, [7, 7, -1, 3])
        FlexibleGroupField.controlPressFieldWhole = true
        defer { FlexibleGroupField.controlPressFieldWhole = false }
        XCTAssertEqual(FlexibleGroupField.clipToPresses(f, cuts: [7: cut]).density, f.density, "★ RED CONTROL: the whole column")
    }

    /// F2 + F3 + F4 on HIS pad (Faces 2–5 resting): his Top corner at 3 mm (then removed); Edge 16 at 5 kg sent; then Face 3 pressed
    /// again.
    func testFixThePressCardEstimateAndKeptOutBlockerOnHisPad() async throws {
        let (_, m) = try await F.hisPad(self)
        for f in [2, 3, 4, 5] { m.rest(f) }
        try await FlexibleSquishFixture.settle(m, "his pad, 2–5 resting")

        // F3: his Top corner at 3 mm, untipped — how far off core's map is, said
        let pick = try await F.M2.pickMode(m)
        let cc = try XCTUnwrap(F.corner(m, pick, faces: [1, 2, 3]), "his Top corner")
        let corner = try await F.commit(m, cc)
        _ = try await settled(m, corner.id, "the corner")
        let cOff = try XCTUnwrap(m.pressOffPercent(corner.id))
        let cLine = m.pressWarning(corner.id)?.line
        print("FLEX-E2F-3 corner 3 mm: off \(cOff)% · card '\(cLine ?? "-")'")
        XCTAssertGreaterThan(cOff, FlexiblePressShape.warnPercent, "premise (the verify: 54 %)")
        XCTAssertTrue(cLine?.contains("\(Int(cOff.rounded()))% off") ?? false, "★ the untipped corner says how far off it is")
        FlexibleStageModel.controlPressLineAsBuilt = true
        let cAsBuilt = m.pressWarning(corner.id)?.line
        FlexibleStageModel.controlPressLineAsBuilt = false
        XCTAssertFalse(cAsBuilt?.contains("% off") ?? false, "★ RED CONTROL: E2 said nothing for an untipped corner")
        _ = await m.removeStripPresses([corner.id])
        try await FlexibleSquishFixture.settle(m, "the corner removed")

        let press = try await F.commit(m, try await F.edge16(m).c, kg: 5)
        let v0 = try await settled(m, press.id, "Edge 16")
        XCTAssertTrue(v0.inJob, "premise: Edge 16 in the job")

        // F3: core's unreached columns on the card
        let d = try XCTUnwrap(m.pressDesign(press.id))
        let n = d.tooFirm + d.tooSoft + d.beyondData
        let off = m.pressOffPercent(press.id) ?? 0
        let line = m.pressWarning(press.id)?.line
        print("FLEX-E2F-3 Edge 16: unreached \(n) of \(d.columns.count) · off \(off)% · card '\(line ?? "-")'")
        XCTAssertGreaterThan(n, 0, "premise (the verify: 52 too soft on his pad)")
        let want = off > FlexiblePressShape.warnPercent ? FlexibleRowCopy.pressUnreached(n, offPercent: off) : FlexibleRowCopy.pressUnreached(n)
        XCTAssertEqual(line, want, "★ the card says core can't reach it")
        XCTAssertLessThanOrEqual(line?.count ?? 99, 44)
        FlexibleStageModel.controlPressLineAsBuilt = true
        let asBuilt = m.pressWarning(press.id)?.line
        FlexibleStageModel.controlPressLineAsBuilt = false
        XCTAssertFalse(asBuilt?.hasPrefix("Can't reach") ?? false, "★ RED CONTROL: E2's card hid it ('\(asBuilt ?? "-")')")

        // F2: the estimate reads the press over its flat prism only
        let e = try XCTUnwrap(m.pressEstimates[press.id], "★ the pipeline hands the estimate Edge 16")
        let cut = try XCTUnwrap(e.cut)
        let st = e.stack
        let c = try XCTUnwrap(st.columns.indices.max { st.columns[$0].exitT - st.columns[$0].entryT < st.columns[$1].exitT - st.columns[$1].entryT })
        let far = FlexibleStackMembership.point(st, column: c, t: st.columns[c].exitT - 0.25)
        XCTAssertGreaterThan(cut.height(far), cut.depthMM, "premise: core's column runs past the flat prism")
        var face = FlexibleGroupEstimate.Face(region: e.key.region, stack: st, cuts: [], segments: FlexiblePinch.core(d, stack: st),
                                              pressureMPa: d.columns.map(\.pressureMPa))
        let whole = FlexibleGroupEstimate.density(of: .init(id: 9, number: 2, faces: [face]), at: far)
        face.wedge = cut
        let clipped = FlexibleGroupEstimate.density(of: .init(id: 9, number: 2, faces: [face]), at: far)
        print("FLEX-E2F-2 Edge 16 column \(c): t past h by \(cut.height(far) - cut.depthMM) mm · ρ whole \(whole ?? -1) · clipped \(clipped ?? -1)")
        XCTAssertNil(clipped, "★ past the flat prism the press gives no material")
        XCTAssertNotNil(whole, "★ RED CONTROL: without the wedge core's whole column counted")

        // F4: Face 3 pressed whole again — the shared surface keeps Edge 16 out: a blocker with the card's fixes
        m.edit { s in var f = FlexibleFaceSettings(faceRegionID: 3); f.weightKg = 5; s.setFace(f) }
        try await FlexibleHisProject.waitFor(60, "the pre-check") { m.pressSupport[press.id]?.inJob == false }
        await m.waitForIdle()
        let r = m.readiness
        let issue = try XCTUnwrap(r.issues.first { $0.kind == .pressKeptOut }, "★ the kept-out press is an issue")
        print("FLEX-E2F-4 top line '\(r.oneLine)' · pill '\(issue.pill)' · fixes \(issue.fixes.map { $0.title { m.displayName($0) } })")
        XCTAssertTrue(issue.blocking, "★ a blocker: Exit would build without it")
        XCTAssertFalse(r.isReady)
        XCTAssertFalse(r.oneLine.hasPrefix("Ready"), "★ the top line is not 'Ready'")
        XCTAssertEqual(issue.fixes, (m.pressWarning(press.id)?.fixes ?? []).map { .pressFix($0) }, "★ the card's fixes")
        XCTAssertTrue((1...3).contains(issue.fixes.count))
        XCTAssertLessThanOrEqual(issue.pill.count, 44)
        FlexibleStageModel.controlKeptOutUnsaid = true
        let silent = m.readiness
        FlexibleStageModel.controlKeptOutUnsaid = false
        XCTAssertFalse(silent.issues.contains { $0.kind == .pressKeptOut }, "★ RED CONTROL: E2 said it only on the card")
    }
}
