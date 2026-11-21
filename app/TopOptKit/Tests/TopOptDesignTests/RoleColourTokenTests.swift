// RoleColourTokenTests — B2 (design-system §2, U5): one colour per role, pinned to the design's table.
import XCTest
@testable import TopOptDesign

final class RoleColourTokenTests: XCTestCase {
    func hex(_ c: RGBA) -> UInt32 {
        UInt32((c.r * 255).rounded()) << 16 | UInt32((c.g * 255).rounded()) << 8 | UInt32((c.b * 255).rounded())
    }

    func testEachRoleHasTheDesignsOneColour() {
        XCTAssertEqual(hex(DS.Color.Role.anchor), 0x30D158)
        XCTAssertEqual(hex(DS.Color.Role.load), 0x0A84FF)
        XCTAssertEqual(hex(DS.Color.Role.keepClear), 0xF26B61)
        XCTAssertEqual(hex(DS.Color.Role.protect), 0x2EE0C7)
        XCTAssertEqual(hex(DS.Color.Role.lattice), 0x7C6FD6)
        XCTAssertEqual(hex(DS.Color.Role.noLattice), 0x7C6FD6)
        XCTAssertEqual(DS.Color.Role.noLattice.a, 0.45, accuracy: 1e-9, "No lattice: the purple at 45 %")
        XCTAssertEqual(hex(DS.Color.Role.allowGrowth), 0x0A84FF)
        XCTAssertEqual(hex(DS.Color.Role.protectSkinOutline), hex(DS.Color.Role.protect))
        XCTAssertEqual(hex(DS.Color.Role.latticeZone), hex(DS.Color.Role.lattice))
    }
}
