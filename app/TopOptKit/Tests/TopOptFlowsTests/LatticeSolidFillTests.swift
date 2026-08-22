// LatticeSolidFillTests — ★★★ A REFUSED CELL IS SOLID PLASTIC, NOT A HOLE
// (maintainer, 2026-08-21: "Can we just make it so the empty spots are filled in with
// what looks like 3D printed layers? This will cover the holes and also show what it
// would actually look like. Please use the actual layer height provided in the Print
// Params info.")
//
// ★★ HIS DIAGNOSIS WAS THE RIGHT SHAPE AND THE HOLES WERE NEVER GEOMETRY. A cell whose
// member cannot hold the cells-per-member floor is REFUSED, so the march's `anyActive`
// stays false, its field stays 1e9, and the ray passes clean through. With the body
// drawn transparent behind the lattice (`LatticePreviewBodyAlpha`) that reads as a hole
// bored through the wall — when the truth is the opposite: it is the DENSEST material in
// the part, solid wall to wall.
//
// ★ SO THE FIX IS NOT A FILL LAYER ON TOP. An inactive cell's field is now `dClip` — the
// part ∩ region clip the STRUTS already use — so the solid is bounded by exactly the same
// surfaces the lattice is, and the two cannot disagree about where the region ends.

import XCTest
@testable import TopOptFlows

final class LatticeSolidFillTests: XCTestCase {

    private var march: String { MeshRenderer.latticeShaderSourceForTesting }

    /// ★★★ THE FIELD. An inactive cell must fall back to the CLIP, not to infinity.
    func testAnInactiveCellIsClippedByThePartInsteadOfBeingInfinite() {
        XCTAssertTrue(
            march.contains("float F = anyActive ? max(dn * cellHere, dClip) : dClip;"),
            "★ the march must give a refused cell the part/region clip as its field — "
            + "with 1e9 the ray passes through and the wall reads as holed")
    }

    /// ★ AND THE SOLID IS BOUNDED BY THE STRUTS' OWN CLIP TERM, not a second one. If a
    /// separate solid ever gets introduced here, the fill and the lattice can end at
    /// different places on the same face — which is the whole class of preview/run
    /// divergence this branch has been closing.
    func testTheSolidUsesTheSameClipTheStrutsDo() {
        // ★ THE CLIP GAINED A TERM. `dPart` is now `lsdf_part_clip(...)`, which holds
        // the struts off any surface the SHELL still draws and lets them reach the
        // declared mouth — so the literal moved. What this bar is for is unchanged: the
        // fill must read the SAME `dClip` the struts did, computed before it.
        guard let clip = march.range(of: "float dClip = max(max(lsdf_part_clip("),
              let use = march.range(of: ": dClip;")
        else { return XCTFail("★ the clip term or its solid-fill use is gone") }
        XCTAssertLessThan(clip.lowerBound, use.lowerBound,
                          "★ the fill must read the clip the struts computed")
        // ★★ AND IT READS IT VERBATIM. The fill used to add its OWN one-voxel inset
        // (`dPart + solidInset`) so it could not z-fight the shell; `dClip` now carries
        // exactly that, and only where the shell actually survives — so through the
        // declared mouth the fill reads flush instead of recessed behind a ledge.
        XCTAssertTrue(march.contains("anyActive ? max(dn * cellHere, dClip) : dClip"),
                      "★ the fill must take the struts' own clip term unmodified — a "
                      + "second inset here is a second answer to where the part ends")
    }

    /// ★★ THE HIT CARRIES WHICH IT IS. Without this the albedo would have to guess from
    /// the density — and a refused cell has no density, so it would be painted as some
    /// invented one.
    func testTheHitSaysWhetherItIsSolid() {
        XCTAssertTrue(march.contains("float solid;"),
                      "★ the hit record must carry it")
        XCTAssertTrue(march.contains("out.solid = anyActive ? 0.0 : 1.0;"),
                      "★ and it must be set from the same flag the field branched on, "
                      + "so the picture and the field cannot disagree")
    }

    /// ★★★ THE LAYER HEIGHT IS THE PRINTER'S — read from the uniform, never a constant.
    func testTheBandingReadsThePrintersLayerHeight() {
        XCTAssertTrue(march.contains("float lh = U.overlayParams.w;"),
                      "★ the layer height must come from the uniform")
        XCTAssertFalse(march.contains("/ 0.2)"),
                       "★ and never from a hard-coded 0.2 mm")
    }

    /// ★★ NO PRINTER STATED ⇒ NO BANDING, NOT A DEFAULT ONE. A picture showing the wrong
    /// number of layers is worse than a plain one: it invites him to count them.
    func testWithNoLayerHeightNoBandingIsDrawn() {
        XCTAssertTrue(march.contains("if (lh > 1e-4)"),
                      "★ the banding must be gated on a stated layer height")
    }

    /// ★ AND IT MUST NOT ALIAS. A hard stripe at 0.2 mm over a 200 mm part is moiré the
    /// moment the camera moves; the contrast has to die as a band approaches a pixel.
    func testTheBandingFadesRatherThanAliasing() {
        XCTAssertTrue(march.contains("fwidth(z)"),
                      "★ the on-screen period must be measured")
        XCTAssertTrue(march.contains("legible"),
                      "★ and used to fade the contrast out")
    }

    /// ★★★ THE UNIFORM IS FED FROM THE RENDERER'S OWN FIELD, in the `w` slot the
    /// shader reads. This struct is matched to its MSL twin by BYTE OFFSET, so the
    /// value had to go in a FREE SLOT on an existing float4 rather than a new field —
    /// the last field appended to one side alone had the shader reading `lightDir` as
    /// the overlay flags.
    func testTheLayerHeightIsWrittenIntoTheSlotTheShaderReads() throws {
        let src = try String(contentsOfFile: "Sources/TopOptFlows/LatticeSDFMetal.swift",
                            encoding: .utf8)
        XCTAssertTrue(src.contains("Float(max(0, layerHeightMM))"),
                      "★ the renderer must write its layer height into overlayParams")
        XCTAssertTrue(src.contains("var layerHeightMM: Double = 0"),
                      "★ …from a field of its own, defaulting to \"not stated\"")
    }

    /// ★ And the printer's own default is a real number, so the wiring has something to
    /// carry on a fresh project — otherwise every one of the bars above would be
    /// vacuously satisfied by a zero that never becomes anything else.
    func testPrintParamsCarriesALayerHeight() {
        XCTAssertGreaterThan(PrintParams.fdmDefault.layerHeightMM, 0,
                             "positive control: there IS a layer height to draw with")
    }
}
