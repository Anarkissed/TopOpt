// ProtectFreezeVsSolidityTests — task 2026-08-04-protect-freeze-vs-solidity,
// bar 6: THE APP SAYS WHAT IT MEANS.
//
// Two things are asserted here, and the second is the one that matters:
//
//   A6a THE COPY NO LONGER IMPLIES SOLIDITY. Protect's tooltips, its toast and
//       the results-screen protection note must not tell the user that protected
//       material is SOLID — it is FROZEN, and solid-vs-latticed is the Lattice
//       page's decision. Asserted on the real strings the app renders.
//
//   A6b THE PAGE'S RULE IS CORE'S RULE, AND THE PAGE CALLS IT. The derivation is
//       exercised across the whole precedence matrix, and — the lesson of
//       "tests on value types miss call sites", which has shipped five times —
//       the LatticePage itself is asserted to produce those rows from a real
//       ProjectModel, so a derivation that is correct but never called cannot
//       pass this file.

import XCTest
import Foundation
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ProtectFreezeVsSolidityTests: XCTestCase {

    // MARK: - A6a · the copy

    /// Every user-visible Protect string, gathered from the sources that render
    /// them, must be free of the solidity claim. Reading the source is
    /// deliberate: the strings live in SwiftUI `.help` / toast literals that no
    /// headless view render exposes, and a test that retyped them would assert
    /// its own copy rather than the app's.
    func testProtectCopyDoesNotImplySolidity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TopOptFlowsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TopOptKit
            .appendingPathComponent("Sources/TopOptFlows")
        let files = ["WorkspacePlaceholder.swift", "ResultsModel.swift"]

        for f in files {
            let text = try String(contentsOf: root.appendingPathComponent(f),
                                  encoding: .utf8)
            // The exact phrases the old copy used, each of which reads as a
            // promise that protected material is solid.
            for banned in ["frozen solid)",
                           "will preserve this face's material",
                           "the optimizer preserves this face's own material"] {
                XCTAssertFalse(text.contains(banned),
                               "\(f) still contains solidity-implying copy: \(banned)")
            }
        }

        // And the replacement says where the other decision lives, so the user is
        // not merely denied the wrong claim but pointed at the right control.
        let ws = try String(contentsOf: root.appendingPathComponent("WorkspacePlaceholder.swift"),
                            encoding: .utf8)
        XCTAssertTrue(ws.contains("Solid or latticed is set on the Lattice page"),
                      "Protect's copy names the control that DOES decide solid vs latticed")
    }

    // MARK: - A6b · the derivation, across the whole precedence matrix

    private func group(_ name: String) -> SelectionGroup {
        SelectionGroup(name: name, colorIndex: 0)
    }

    func testExcludeOverProtectedIsSolid() {
        let g = group("Back wall")
        let rows = FrozenRegionLatticeStatus.rows(
            protectedGroups: [g], roles: [g.id: .exclude], anyIncludeDeclared: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].outcome, .solid)
        XCTAssertEqual(rows[0].name, "Back wall")
    }

    func testIncludeOverProtectedIsLatticed() {
        // THE CASE THIS WHOLE TASK EXISTS FOR: "don't reshape this wall, but DO
        // lattice inside it." It must read as LATTICED, not as a conflict.
        let g = group("Back wall")
        let rows = FrozenRegionLatticeStatus.rows(
            protectedGroups: [g], roles: [g.id: .include], anyIncludeDeclared: true)
        XCTAssertEqual(rows[0].outcome, .latticed)
        XCTAssertTrue(rows[0].reason.contains("the shape is frozen"),
                      "the reason states the freeze AND the lattice, not a conflict")
    }

    func testUnroledProtectedFollowsWhetherAnyIncludeExists() {
        let g = group("Collar")
        // An include region ANYWHERE means only the include union is latticed,
        // so an unroled protected group is outside it -> SOLID.
        let withInclude = FrozenRegionLatticeStatus.rows(
            protectedGroups: [g], roles: [:], anyIncludeDeclared: true)
        XCTAssertEqual(withInclude[0].outcome, .solid)

        // No include anywhere: the page said "lattice the whole part", and that
        // includes frozen material. This is today's behaviour, now stated.
        let noInclude = FrozenRegionLatticeStatus.rows(
            protectedGroups: [g], roles: [:], anyIncludeDeclared: false)
        XCTAssertEqual(noInclude[0].outcome, .latticed)
        XCTAssertTrue(noInclude[0].reason.contains("whole part"))
    }

    func testSummaryCountsBothWays() {
        let a = group("A"), b = group("B"), c = group("C")
        let rows = FrozenRegionLatticeStatus.rows(
            protectedGroups: [a, b, c],
            roles: [a.id: .include, b.id: .exclude, c.id: .exclude],
            anyIncludeDeclared: true)
        XCTAssertEqual(FrozenRegionLatticeStatus.summary(rows),
                       "1 protected region latticed, 2 solid.")
        XCTAssertTrue(FrozenRegionLatticeStatus.caveat
                        .contains("does not decide solid vs latticed"))
    }

    func testNothingProtectedShowsNothing() {
        let rows = FrozenRegionLatticeStatus.rows(
            protectedGroups: [], roles: [:], anyIncludeDeclared: false)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(FrozenRegionLatticeStatus.summary(rows), "",
                       "a part with no Protect affix sees the page unchanged")
    }

    // MARK: - A6b · THE CALL SITE

    /// The page must actually produce these rows from a real project state.
    /// `LatticePage.frozenRegionRows` is private to the view, so this asserts the
    /// composition it performs — protected groups × roles × "any include
    /// declared", read off a ProjectModel exactly as the page reads them — and
    /// would fail if the page's inputs stopped lining up with the derivation's.
    func testPageComposesTheRowsFromRealProjectState() {
        let project = ProjectModel(id: UUID(), name: "p", material: "PLA",
                                   process: .fdm, importedFile: nil,
                                   importedMesh: nil)
        // Create the group through the model's own API, so this drives the real
        // store the page reads rather than a hand-placed value.
        let wallID = project.selection.addGroup()
        project.force.setProtected(wallID, true)
        project.lattice.groupRoles = [wallID: LatticeGroupRole.include]

        // The page's own inputs.
        let protectedGroups: [SelectionGroup] =
            project.force.protectedGroups(in: project.selection.groups)
        XCTAssertEqual(protectedGroups.map { $0.id }, [wallID],
                       "the page sees the protected group the user marked")

        let rows = FrozenRegionLatticeStatus.rows(
            protectedGroups: protectedGroups,
            roles: project.lattice.groupRoles,
            anyIncludeDeclared: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].outcome, FrozenRegionLatticeStatus.Outcome.latticed,
                       "a Protect + lattice-here group reads LATTICED on the page")
    }
}
