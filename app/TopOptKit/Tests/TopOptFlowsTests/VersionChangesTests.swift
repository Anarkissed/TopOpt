// VersionChangesTests.swift — what changed between two versions, and the automatic name
// (approved mockup 2026-10-25, DATA-MODEL.md "Naming rule").
//
// Rule: `Part · v<n> · biggest change · next change`, then "+ n more". Order: goal or stage, loads,
// anchors, Keep Clear and Protect, design box, material, plastic, resolution. Faces are named by the
// group's name or by how many faces, NEVER by face number (memory: he doesn't see face ids).

import XCTest
@testable import TopOptFlows

final class VersionChangesTests: XCTestCase {

    private func snapshot(_ edit: (inout SelectionModel, inout ForceModel) -> Void = { _, _ in },
                          material: String = "PA12-CF", quality: RunQuality = .fast,
                          minimizePlastic: Bool? = nil) -> ProjectSnapshot {
        var sel = SelectionModel(), force = ForceModel()
        edit(&sel, &force)
        return ProjectSnapshot(id: UUID(), name: "Carriage Arms", material: material, process: .fdm,
                               modelFileName: "model.step", originalFileName: "Carriage Arms.step",
                               savedAt: Date(timeIntervalSince1970: 0), selection: sel, force: force,
                               minimizePlastic: minimizePlastic, quality: quality)
    }

    /// His Carriage Arms as v5 ran it: bolt holes anchored, a 500 N load on the top pads.
    private func base(_ s: inout SelectionModel, _ f: inout ForceModel) {
        f.unit = .kg
        let a = s.addGroup(); s.addFaces([131, 133, 132], to: a); f.makeAnchor(a)
        let l = s.addGroup(); s.addFaces([18, 34], to: l); f.makeLoad(l); f.setWeight(l, kg: 51)
    }

    private func names(_ c: [VersionChange]) -> [String] { c.map(\.text) }

    func testTheMockupsDraftIsNamedLikeTheMockup() {
        let v5 = snapshot(base)
        let v6 = snapshot({ s, f in
            self.base(&s, &f)
            let k = s.addGroup(); s.addFaces([90, 91], to: k); f.setKeepClear(k, on: true, autoDefault: false)
        }, quality: .fine)
        let c = VersionChanges.between(v5, v6)
        XCTAssertEqual(VersionChanges.autoName(part: "Carriage Arms", number: 6, changes: c, resolution: 128),
                       "Carriage Arms · v6 · Keep Clear on 2 faces · res 128")
        XCTAssertEqual(names(c), ["Keep Clear on 2 faces", "Resolution 64 → 128"])
    }

    func testAFirstVersionIsTheFirstRunAtItsResolution() {
        XCTAssertEqual(VersionChanges.autoName(part: "Carriage Arms", number: 1, changes: [], resolution: 64),
                       "Carriage Arms · v1 · first run · res 64")
    }

    func testTheSameSettingsOnANewerEngineIsAnEngineUpdate() {
        let a = snapshot(base), b = snapshot(base)
        XCTAssertEqual(VersionChanges.between(a, b), [])
        XCTAssertEqual(VersionChanges.autoName(part: "Carriage Arms", number: 5, changes: [], resolution: 64,
                                               engineUpdated: true),
                       "Carriage Arms · v5 · engine update · same settings")
    }

    func testTheBiggestChangeComesFirstAndTheRestCountAsMore() {
        let a = snapshot(base)
        let b = snapshot({ s, f in
            self.base(&s, &f)
            f.setWeight(s.groups[1].id, kg: 60)
            let p = s.addGroup(); s.addFaces([4, 146], to: p); f.setProtected(p, true)
        }, material: "PETG", quality: .fine)
        let c = VersionChanges.between(a, b)
        XCTAssertEqual(c.first?.rank, VersionChange.Rank.load)
        XCTAssertEqual(c.map(\.rank), c.map(\.rank).sorted(), "ordered by the naming rule")
        XCTAssertEqual(VersionChanges.autoName(part: "Carriage Arms", number: 6, changes: c, resolution: 128),
                       "Carriage Arms · v6 · Load 51 → 60 kg · Protect on 2 faces · +2 more")
    }

    func testAGroupHeNamedIsCalledByItsName() {
        let a = snapshot(base)
        let b = snapshot({ s, f in
            self.base(&s, &f)
            let k = s.addGroup(); s.addFaces([90, 91], to: k); s.rename(k, to: "Cable path")
            f.setKeepClear(k, on: true, autoDefault: false)
        })
        XCTAssertEqual(names(VersionChanges.between(a, b)), ["Keep Clear on Cable path"])
    }

    func testNoChangeLineEverNamesAFaceNumber() {
        let a = snapshot(base)
        let b = snapshot({ s, f in
            let a = s.addGroup(); s.addFaces([131, 133, 132, 134], to: a); f.makeAnchor(a)
            let l = s.addGroup(); s.addFaces([18, 34], to: l); f.makeLoad(l); f.setWeight(l, kg: 51)
            let k = s.addGroup(); s.addFaces([146], to: k); f.setKeepClear(k, on: true, autoDefault: false)
        })
        let text = names(VersionChanges.between(a, b)).joined(separator: " ")
        for id in ["131", "133", "134", "146", "18", "34"] { XCTAssertFalse(text.contains(id), "\(id) in “\(text)”") }
        XCTAssertTrue(text.contains("Anchor 3 → 4 faces"), text)
        XCTAssertTrue(text.contains("Keep Clear on 1 face"), text)
    }

    func testTurningOffMinimizePlasticIsTheGoalAndComesFirst() {
        let a = snapshot(base)
        let b = snapshot(base, material: "PETG", minimizePlastic: false)
        let c = VersionChanges.between(a, b)
        XCTAssertEqual(names(c), ["Goal: Strengthen", "Material PA12-CF → PETG"])
        XCTAssertEqual(c.first?.phrase, "Strengthen")
    }

    func testRemovingAGroupSaysSo() {
        let a = snapshot(base)
        let b = snapshot({ s, f in
            let x = s.addGroup(); s.addFaces([131, 133, 132], to: x); f.makeAnchor(x)
        })
        XCTAssertEqual(names(VersionChanges.between(a, b)), ["No load on 2 faces"])
    }
}
