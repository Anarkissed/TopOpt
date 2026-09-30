// FlexibleDepthAccent — never violet under Flexible (task 2026-09-29-flexible-screens, round 3
// batch C; the plan's optional recolour, his standing rule "never purple"). Hook H13 in #354's
// WorkspacePlaceholder: the lattice-depth prism's tint and the two knobs' glass.

import simd
import TopOptDesign

extension FlexibleMainTints {
    /// ★ NEVER PURPLE UNDER FLEXIBLE (plan item 1.4's optional recolour; his standing rule): the
    /// main page's lattice-depth prism (a Lattice / Solid group's slab) and its knobs are drawn in
    /// the octet's violet density ramp; under Flexible they take the Flexible accent (DS
    /// accentGreen) — Solid in DS textQuaternary. Anything else keeps #354's colour.
    public static func depthPlane(_ role: LatticeGroupRole?, flexible: Bool) -> SIMD3<Float>? {
        guard flexible, let role else { return nil }
        let c = role == .include ? FlexibleStageStyle.accentToken : DS.Color.textQuaternary
        return SIMD3<Float>(Float(c.r), Float(c.g), Float(c.b))
    }
    /// The depth / expand knobs' glass tint: the Flexible accent under Flexible, else `octet`.
    public static func knob(flexible: Bool, _ octet: RGBA) -> RGBA {
        flexible ? FlexibleStageStyle.accentToken : octet
    }
}
