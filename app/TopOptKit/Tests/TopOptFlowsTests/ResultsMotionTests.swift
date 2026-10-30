import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// ★ His iPad 2026-10-27: the Results views MOVE again (Load paths, Bend, Break), never wiggle, pause and scrub by hand,
/// and a Scenario pick says plainly which scenario the views show.
@MainActor
final class ResultsMotionTests: XCTestCase {
    private func model(load: Double = 0) throws -> ResultsModel {
        ResultsModel(projectName: "CarriageArms", outcome: try ResultsRedesignTests.strengthenOutcome(),
                     yieldStrengthMPa: 21, appliedLoadKg: load)
    }

    func testTheMovingViewsAreBackAndHiddenWhenTheRunCannotShowThem() {
        XCTAssertEqual(ResultsViewMode.shown(hasStress: true, hasDisplacement: true, canBreak: true),
                       [.stress, .solid, .xray, .loadPaths, .bend, .breakIt])
        XCTAssertEqual(ResultsViewMode.shown(hasStress: false, hasDisplacement: false, canBreak: false), [.solid, .xray],
                       "a view the run cannot show is hidden, never greyed")
        XCTAssertEqual(ResultsViewMode.allCases.filter(\.moves), [.loadPaths, .bend, .breakIt])
    }

    func testBreakClimbsToTheBreakingLoadHoldsThenClimbsAgain() {
        XCTAssertEqual(ResultsMotion.breakPosition(time: 0), 0)
        XCTAssertEqual(ResultsMotion.breakPosition(time: ResultsMotion.breakRampSeconds / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ResultsMotion.breakPosition(time: ResultsMotion.breakRampSeconds + 0.5), 1, "held at the break")
        let cycle = ResultsMotion.breakRampSeconds + ResultsMotion.breakHoldSeconds
        XCTAssertEqual(ResultsMotion.breakPosition(time: cycle + 1), 0.25, accuracy: 1e-9, "and climbs again")
        XCTAssertEqual(ResultsMotion.pushFactor(position: 0, multiplier: 4), 1, "today's load")
        XCTAssertEqual(ResultsMotion.pushFactor(position: 1, multiplier: 4), 4, "the load that breaks it")
        XCTAssertEqual(ResultsMotion.breakPosition(pushFactor: 2.5, multiplier: 4), 0.5, accuracy: 1e-9)
    }

    /// ★ "remove the fucking wiggling": with the shipped setting every arrow body lies ON its path — no sideways offset.
    func testTheArrowsTravelTheirPathStraightNeverWiggling() throws {
        let rm = try model()
        XCTAssertEqual(rm.flowWiggle, 0, "★ the arrows never wiggle")
        let pts = (0..<40).map { SIMD3<Float>(Float($0), sin(Float($0) * 0.2) * 3, 0) }
        let curve = FlowCurve.resample(pts, wobblePhase: 0.7)
        for clock: Float in [0, 0.7, 1.9, 3.3] {
            let f = CometArrow.frame(curve: curve, style: .sine, clock: clock, loopPeriod: 3.6, speed: 1,
                                     wiggle: rm.flowWiggle, reduced: false, baseRadius: 0.3, color: .one)
            for c in f.centers {
                let nearest = pts.indices.dropLast().map { i -> Float in
                    let a = pts[i], b = pts[i + 1], ab = b - a
                    let t = max(0, min(1, simd_dot(c - a, ab) / simd_length_squared(ab)))
                    return simd_distance(c, a + ab * t)
                }.min() ?? 0
                XCTAssertLessThan(nearest, 0.02, "★ clock \(clock): an arrow's body left its path by \(nearest) mm")
            }
        }
        // a positive control: the old setting DID push the body off the path
        let old = CometArrow.frame(curve: curve, style: .sine, clock: 0.7, loopPeriod: 3.6, speed: 1,
                                   wiggle: 1, reduced: false, baseRadius: 0.3, color: .one)
        let offPath = old.centers.contains { c in
            pts.indices.dropLast().map { i -> Float in
                let a = pts[i], b = pts[i + 1], ab = b - a
                let t = max(0, min(1, simd_dot(c - a, ab) / simd_length_squared(ab)))
                return simd_distance(c, a + ab * t)
            }.min()! > 0.5
        }
        XCTAssertTrue(offPath, "control: wiggle 1 is what he saw")
    }

    func testEveryMovingViewScrubsByHand() throws {
        let rm = try model(load: 5)
        rm.flexOn = true
        rm.setFlexPhase(0.4)
        XCTAssertEqual(rm.flexPhase, 0.4, accuracy: 1e-9)
        XCTAssertGreaterThan(rm.flexScale(reduceMotion: false), 0, "the bend shows at the scrubbed place")
        rm.toggleLoadPath()
        rm.setFlowLoopPosition(0.75)
        XCTAssertEqual(rm.flowLoopPosition, 0.75, accuracy: 1e-9)
        rm.advanceFlowClock(ResultsModel.flowLoopPeriod)
        XCTAssertEqual(rm.flowLoopPosition, 0.75, accuracy: 1e-6, "one loop later, the same place")
        let fp = try XCTUnwrap(rm.failurePrediction, "premise: a load and a yield make a breaking load")
        rm.failureOn = true
        rm.setPush(factor: ResultsMotion.pushFactor(position: 1, multiplier: fp.multiplier))
        XCTAssertTrue(rm.atFailure, "the slider's end is the load that breaks it")
    }

    func testAScenarioPickSaysWhichScenarioTheViewsShow() {
        let sc = [ScenarioResult(name: "Scenario 1", margin: 4, governs: true, unheld: false),
                  ScenarioResult(name: "Scenario 3", margin: 20, governs: false, unheld: false)]
        XCTAssertNil(ResultsScenarioViews.note(pick: nil, scenarios: sc), "worst case: the views ARE its own")
        XCTAssertNil(ResultsScenarioViews.note(pick: "Scenario 1", scenarios: sc))
        XCTAssertEqual(ResultsScenarioViews.note(pick: "Scenario 3", scenarios: sc),
                       "The views show Scenario 1, the worst case — this run sent its fields only.")
    }

    /// ★ His iPad 2026-10-28: Stress / Solid / X-ray are LAYERS on any motion; Bend and Break turn Stress on; Load paths
    /// turns X-ray on and Stress can be added; Stress and X-ray combine; Solid is the plain grey.
    func testTheViewsAreLayersOnOneMotion() {
        var l = ResultsLayers(stress: false)
        l.tap(.bend, hasStress: true)
        XCTAssertTrue(l.isOn(.bend) && l.isOn(.stress), "★ Bend turns Stress on")
        l.tap(.xray, hasStress: true)
        XCTAssertTrue(l.isOn(.stress) && l.isOn(.xray) && l.isOn(.bend), "★ Stress + X-ray on top of Bend")
        l.tap(.solid, hasStress: true)
        XCTAssertTrue(l.isOn(.solid) && !l.isOn(.stress) && l.isOn(.xray), "Solid replaces Stress; X-ray stays")
        l.tap(.breakIt, hasStress: true)
        XCTAssertTrue(l.isOn(.breakIt) && !l.isOn(.bend) && l.isOn(.stress), "★ one motion at a time; Break turns Stress on")
        l.tap(.solid, hasStress: true); l.xray = false
        l.tap(.loadPaths, hasStress: true)
        XCTAssertTrue(l.isOn(.loadPaths) && l.isOn(.xray) && l.isOn(.solid), "★ Load paths turns X-ray on, not Stress")
        l.tap(.stress, hasStress: true)
        XCTAssertTrue(l.isOn(.stress) && l.isOn(.loadPaths), "Stress can be added to Load paths")
        l.tap(.loadPaths, hasStress: true)
        XCTAssertNil(l.motion, "tapped again: no motion")
        var none = ResultsLayers(stress: false); none.tap(.bend, hasStress: false)
        XCTAssertFalse(none.isOn(.stress), "no stress field: no Stress to turn on")
    }

    /// ★ A tap on the BENT part finds the spot on the bent surface and the same spot of the real part.
    func testATapOnTheBentPartFindsItsSpot() {
        // one triangle in z = 0, bent up by 1 mm × scale 10 = z 10
        let flat = ViewerMesh(vertices: [0, 0, 0, 10, 0, 0, 0, 10, 0], indices: [0, 1, 2], faceIDs: [0]).flat
        let disp = [Float](repeating: 0, count: 9).enumerated().map { $0.offset % 3 == 2 ? 1 : 0 } as [Float]
        let p = MetalMeshView.Coordinator.restPointOnBentSurface(flat, disp: disp, scale: 10, origin: SIMD3(2, 2, 50), dir: SIMD3(0, 0, -1))
        XCTAssertEqual(p?.x ?? -1, 2, accuracy: 1e-4); XCTAssertEqual(p?.z ?? -1, 0, accuracy: 1e-4, "the real part's spot (z 0)")
        XCTAssertNil(MetalMeshView.Coordinator.restPointOnBentSurface(flat, disp: disp, scale: 10, origin: SIMD3(20, 20, 50), dir: SIMD3(0, 0, -1)))
    }
}
