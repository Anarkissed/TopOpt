// ShellClipLayoutTests — ★★★ THE UNIFORM AND ITS MSL TWIN ARE MATCHED BY BYTE OFFSET.
//
// ★ THIS HAS BITTEN THIS FILE BEFORE. A field added to the Swift struct alone shifts
// every field after it, and the shader then reads a NEIGHBOURING uniform as this one —
// on the last occurrence the lattice shader read `lightDir` as the overlay flags. There
// is no compiler on either side of that boundary; the only guard is a test.
//
// ★ SO THIS PINS BOTH SIDES: the Swift struct's size and field offsets, and the MSL
// text's field list and order. A one-sided edit fails here rather than on the GPU.

import XCTest
import simd
@testable import TopOptFlows

final class ShellClipLayoutTests: XCTestCase {

    func testTheSwiftStructIsFourFloat4s() {
        XCTAssertEqual(MemoryLayout<ShellClipUniform>.size, 64)
        XCTAssertEqual(MemoryLayout<ShellClipUniform>.stride, 64)
        XCTAssertEqual(MemoryLayout<ShellClipUniform>.alignment, 16)
        // The offsets the shader reads, in the shader's own order.
        XCTAssertEqual(MemoryLayout<ShellClipUniform>.offset(of: \.grid), 0)
        XCTAssertEqual(MemoryLayout<ShellClipUniform>.offset(of: \.spacing), 16)
        XCTAssertEqual(MemoryLayout<ShellClipUniform>.offset(of: \.dims), 32)
        XCTAssertEqual(MemoryLayout<ShellClipUniform>.offset(of: \.gate), 48)
    }

    func testTheMSLDeclaresTheSameFieldsInTheSameOrder() {
        // The struct body, verbatim from the shared source both libraries interpolate.
        guard let open = shellClipMSL.range(of: "struct ShellClip {"),
              let close = shellClipMSL.range(of: "};", range: open.upperBound..<shellClipMSL.endIndex)
        else { return XCTFail("`struct ShellClip` not found in shellClipMSL") }
        let body = shellClipMSL[open.upperBound..<close.lowerBound]
        let fields = body.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("float4 ") else { return nil }
            return String(t.dropFirst("float4 ".count).prefix(while: { $0 != ";" }))
        }
        XCTAssertEqual(fields, ["origin", "spacing", "dims", "gate"],
                       "the MSL struct moved; `ShellClipUniform` must move with it")
    }

    /// ★ THE DECLARATION BUFFER'S STRIDE. The list rides in its own buffer precisely so
    /// this struct can stay a fixed 64 bytes — but the buffer has a stride of its own,
    /// and the shader indexes it with `SHELL_DECL_STRIDE`.
    func testTheDeclarationStrideAgreesWithTheShader() {
        XCTAssertTrue(shellClipMSL.contains("#define SHELL_DECL_STRIDE 3"),
                      "the shader's declaration stride changed")
        // Three float4s per declaration, which is what the Swift builder appends.
        XCTAssertEqual(MemoryLayout<ShellDeclUniform>.size, 48)
        XCTAssertEqual(MemoryLayout<ShellDeclUniform>.stride, 48)
        XCTAssertEqual(3 * MemoryLayout<SIMD4<Float>>.stride,
                       MemoryLayout<ShellDeclUniform>.stride)
    }

    /// ★ THE RULE ITSELF, STATED ONCE IN MSL — this only pins that it still reads the
    /// fragment's normal and the region field, because a rule that quietly reverts to
    /// "is the owning cell active" is exactly the regression this task exists to undo.
    func testTheRuleTestsTheFragmentNormalAndTheRegionField() {
        XCTAssertTrue(shellClipMSL.contains("float3 mnormal"),
                      "the shell rule no longer takes the fragment's own normal")
        XCTAssertTrue(shellClipMSL.contains("regionTex.sample"),
                      "the shell rule no longer reads the declared region's field")
        XCTAssertTrue(shellClipMSL.contains("dot(sn, -inward) < c.gate.x"),
                      "the normal-agreement gate is gone")
    }
}
