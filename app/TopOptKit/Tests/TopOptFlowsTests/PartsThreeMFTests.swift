// PartsThreeMFTests — B5 (ledger note 11, Q10, plan.md §B5): "One 3MF (all parts)" holds one named object per part, laid
// out in a row so none overlap, parsed back. (The sheet's own test is ExportPickedHostedTests.)
import XCTest
import simd
@testable import TopOptFlows

final class PartsThreeMFTests: XCTestCase {
    /// A unit cube's 8 corners and 12 triangles, scaled and moved.
    static func cube(_ s: Float, at o: SIMD3<Float>) -> (v: [Float], i: [Int32]) {
        var v: [Float] = []
        for k in 0..<8 {
            let p = o + s * SIMD3<Float>(Float(k & 1), Float((k >> 1) & 1), Float((k >> 2) & 1))
            v += [p.x, p.y, p.z]
        }
        let i: [Int32] = [0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5]
        return (v, i)
    }

    func testThreePartsAreThreeNamedObjectsInARow() throws {
        // three parts, all modelled round the origin (the overlap a slicer would show if they kept their places)
        let parts = [("Carriage Arms \u{00B7} v7b", Self.cube(40, at: SIMD3(-20, -20, 0))),
                     ("2040 Extrusion Stand", Self.cube(20, at: SIMD3(-10, -10, 5))),
                     ("Motor Mount & <Plate>", Self.cube(30, at: SIMD3(0, 0, -15)))]
        let data = PartsThreeMF.write(parts.map { PartsThreeMF.Object(name: $0.0, vertices: $0.1.v, indices: $0.1.i) },
                                      title: "Squish Mechanism")
        // the slicer evidence (plan.md §B5's risk): TOPOPT_3MF_EVIDENCE=<path> writes this file for a slicer to open
        if let p = ProcessInfo.processInfo.environment["TOPOPT_3MF_EVIDENCE"] { try data.write(to: URL(fileURLWithPath: p)) }
        let back = try XCTUnwrap(PartsThreeMF.read(data), "★ the file reads back")
        XCTAssertEqual(back.map(\.name), parts.map(\.0), "★ one object per part, with its name (escaped and restored)")
        XCTAssertEqual(back.map(\.vertexCount), [8, 8, 8])
        XCTAssertEqual(back.map(\.triangleCount), [12, 12, 12])
        for o in back {
            XCTAssertEqual(o.placedMin.y, 0, accuracy: 1e-4); XCTAssertEqual(o.placedMin.z, 0, accuracy: 1e-4, "on the plate")
        }
        XCTAssertEqual(back[0].placedMin.x, 0, accuracy: 1e-4)
        for k in 1..<back.count {
            XCTAssertEqual(back[k].placedMin.x - back[k - 1].placedMax.x, PartsThreeMF.gap, accuracy: 1e-4,
                           "★ side by side, \(PartsThreeMF.gap) mm apart — none overlap")
        }
        // a 3MF package: the content types, the relationship, the model
        let names = try XCTUnwrap(StoredZip.entries(data)).map(\.name)
        XCTAssertEqual(names, ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model"])
    }

    func testABadIndexDropsItsTriangleNotTheFile() throws {
        var c = Self.cube(10, at: .zero)
        c.i += [0, 1, 99]   // out of range
        c.i += [2, 2, 3]    // degenerate
        let back = try XCTUnwrap(PartsThreeMF.read(PartsThreeMF.write([.init(name: "p", vertices: c.v, indices: c.i)], title: "t")))
        XCTAssertEqual(back.first?.triangleCount, 12)
    }
}
