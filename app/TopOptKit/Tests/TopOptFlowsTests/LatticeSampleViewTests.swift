// LatticeSampleViewTests — his iPad notes 11-08 (4.1): "There is no 'One cell' or 'In the part' visuals whatsoever."
// The view switch outlived the sample stage B8 deleted (10-24), so Sample drew nothing. Design note 30 / R3.2 (plan B7):
// Sample is core's sample block beside the panel. These pin that the page mounts it and that the block is core's own.
import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeSampleViewTests: XCTestCase {

    /// ★ The block is core's coupon for the type: triangles, and a receipt that says so.
    func testTheSampleIsCoresCouponForTheType() throws {
        let block = try TopOptKit.latticeSampleBlock(topology: "octet")
        XCTAssertGreaterThan(block.mesh.triangleCount, 1000, "★ the engine's block, not an empty stand-in")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(block.receiptJSON.utf8)) as? [String: Any])
        XCTAssertEqual(obj["shape"] as? String, "coupon")
        XCTAssertEqual(obj["topology"] as? String, "octet")
        XCTAssertEqual((obj["dimensions_mm"] as? [Double])?.count, 3)
        XCTAssertEqual(LatticeSampleView.caption(receiptJSON: block.receiptJSON, typeName: "Octet truss").hasPrefix("Sample block · "), true)
        // CONTROL: a type core cannot generate is refused in core's words, never drawn as octet
        XCTAssertThrowsError(try TopOptKit.latticeSampleBlock(topology: "no-such-type"))
    }

    /// ★ The page mounts it under Sample (the switch's first view), beside the panel; In the part keeps the stage's preview.
    func testThePageDrawsTheSampleUnderTheSwitch() throws {
        let src = try FlexibleSource.code("LatticeSetupWizard.swift")
        let r = try XCTUnwrap(src.range(of: "private func latticePage(_ c: CellsPageContext, size: CGSize) -> AnyView {"))
        let page = String(src[r.upperBound...].prefix(1400))
        XCTAssertTrue(page.contains("if model.stage == .cell {"))
        XCTAssertTrue(page.contains("LatticeSampleView(inputs: latticeSampleInputs)"))
        XCTAssertTrue(src.contains("Text(s == .cell ? LatticeSampleView.switchTitle : s.title)"), "the switch says Sample")
        XCTAssertEqual(LatticeSampleView.switchTitle, "Sample")
    }
}
