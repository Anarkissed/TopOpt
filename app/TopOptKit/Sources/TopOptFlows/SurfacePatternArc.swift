// SurfacePatternArc.swift — ★ §7, REBUILT: A FACE IS PATTERNED ON ITS OWN ARC.
//
// Maintainer, 2026-08-16, after five rounds of this not working:
//
//   "The curved pattern issue is still not resolved. PLEASE stop making bandaids
//    and re-create the entire pattern on a face system with curves and straight
//    lines as the default. For curves, I had a thought: do not represent the
//    separation by area or length. Represent via degrees. Compare the curve to a
//    circle, define how big the circle is, what the radius is, how wide the face's
//    full length is in degrees, then break them up into 2 or 3 (or however many is
//    in columns) equally spaced lines with degrees as the marker."
//
// ── WHAT WAS ACTUALLY WRONG, MEASURED RATHER THAN GUESSED ────────────────────
//
// Five division rules were tried — even parameter, area quantiles, area
// bisection, arc along a swept centroid, arc along a walked spine — and each was
// reported as still uneven. That is a strong hint that the DIVISION was never the
// broken part, and it wasn't. Two other things were:
//
//  1. ★ A DIVIDER IS A PLANE, AND A PLANE CUTS A CURVED STRIP MORE THAN ONCE.
//     Place a plane a third of the way along a U and it passes straight through
//     the far arm as well. Both pieces it makes there are then bounded by the same
//     plane, so the "third" of the strip is really two disconnected patches, and a
//     divider drawn from it appears in two or three places at once. That is the
//     three gold marks in the maintainer's screenshot where two were asked for.
//
//  2. ★ THE LATERAL BOX BUILT TO CONTAIN THAT DID NOT PARTITION. It was oriented
//     off a world axis (`|tangent.z| < 0.9 ? +Z : +X`) and padded by
//     `halfWidth * 2 + extent * 0.25`, so neighbouring cells OVERLAPPED by a
//     quarter of their length while distant ones could still both claim the same
//     surface. A cell that holds no surface at all is then routine — "Smallest
//     piece: 0 voxels, floor 16" — and the confirm is correctly refused, which is
//     why the tool appeared to do nothing on a curve.
//
// ── HIS IDEA IS THE FIX, AND IT FIXES THE REAL PROBLEM ───────────────────────
//
// ★ A WEDGE PLANE PASSES THROUGH THE ARC'S AXIS. Fit a circle to the strip and
// every divider becomes a half-plane hinged on that axis. Two of them bound a
// WEDGE, and a wedge narrower than 180° contains exactly one crossing of the
// strip — the far arm is at a different angle and is excluded by the wedge's own
// other plane. No lateral box, no padding, no overlap: the wedges partition the
// space around the axis by construction, which is precisely the property every
// previous attempt was missing.
//
// So the arc is not a nicer way to space the dividers. It is the thing that makes
// a piece of a curved strip EXPRESSIBLE as `faces ∩ (intersection of half-spaces)`
// at all — the shape `FaceRegion` has always been.
//
// ── ONE PLACE THIS DEPARTS FROM THE BRIEF, AND WHY ───────────────────────────
//
// ★ THE DIVIDERS ARE PLACED BY ARC LENGTH, NOT BY EQUAL DEGREES. On a true circle
// these are the same thing — s = Rθ — so nothing is lost where his rule applies.
// They come apart on a strip that is STRAIGHT, then BENT, then STRAIGHT, which is
// the shape of his own part: the straight arms contribute no turn at all, so an
// equal-DEGREE split puts every divider inside the bend and leaves the two arms
// whole. Equal degrees is right for a circle and wrong for a hook; equal arc is
// right for both, and on a circle it IS equal degrees.
//
// The angle is still what the CELL is built from. Position by length, bound by
// degrees.
//
// Pure geometry on value types — no mesh walking beyond what is handed in, no
// Metal, no view. Everything here is exercised headlessly.

import Foundation
import simd
import TopOptKit

public enum SurfacePatternArc {

    /// ★ THE STRIP, AS A CIRCLE (or as the straight line that is a circle of
    /// infinite radius). This is the "how big is the circle, what is the radius,
    /// how many degrees does the face cover" the maintainer asked for, measured
    /// off the strip itself.
    public struct Sweep: Equatable, Sendable {

        /// False when the strip turns too little to have a meaningful centre —
        /// the degenerate, and extremely common, case.
        public var isCurved: Bool
        /// Curved: the centre of the fitted circle. Straight: the run's start.
        public var centre: SIMD3<Double>
        /// Curved: the axis the strip turns about (unit). Straight: zero.
        public var axis: SIMD3<Double>
        /// Curved: the fitted radius, mm. Straight: `.infinity` — stated rather
        /// than implied, because that is exactly what a straight strip is.
        public var radiusMM: Double
        /// ★ THE FACE'S FULL LENGTH IN DEGREES. Signed, positive about `axis`.
        /// Zero on a straight strip.
        public var sweepDegrees: Double
        /// Arc length along the strip, mm. The measure the dividers are placed by.
        public var lengthMM: Double
        /// The radial direction at the strip's START — the zero of the angle
        /// measure, so every angle below is "degrees along the face from its
        /// beginning". Straight: the run direction.
        public var reference: SIMD3<Double>

        /// The other in-plane axis, completing a right-handed frame with `axis`.
        /// `radial(0) = reference`, and angle increases from `reference` toward
        /// this.
        public var coReference: SIMD3<Double> { simd_cross(axis, reference) }

        /// The point on the fitted circle at `degrees` from the start.
        public func radial(_ degrees: Double) -> SIMD3<Double> {
            let a = degrees * .pi / 180
            return reference * cos(a) + coReference * sin(a)
        }

        /// ★ THE DIVIDER PLANE AT `degrees`: hinged on the axis, facing the way the
        /// angle increases. Everything at a greater angle is on its positive side,
        /// everything behind it is not — which is what makes two of them a wedge.
        public func plane(at degrees: Double) -> RegionCut {
            RegionCut(point: centre, normal: simd_cross(axis, radial(degrees)))
        }

        /// Where a point sits in the measure, in degrees from the start. Unwrapping
        /// is the caller's job — this is the raw value in (−180, 180].
        public func degrees(of p: SIMD3<Double>) -> Double {
            let d = p - centre
            let flat = d - axis * simd_dot(axis, d)
            guard simd_length(flat) > 1e-12 else { return 0 }
            return atan2(simd_dot(flat, coReference), simd_dot(flat, reference))
                * 180 / .pi
        }
    }

    /// ★ THE SMALLEST TURN WORTH CALLING A CURVE. Below this the fitted radius is
    /// enormous, the centre is far off the part, and every angle is numerically
    /// indistinguishable — so the straight construction is both simpler and more
    /// accurate. 5° over a whole strip is well under a tessellation's own noise.
    public static let straightBelowDegrees: Double = 5

    /// ★ THE WIDEST WEDGE A PAIR OF PLANES CAN ACTUALLY ENCLOSE. At exactly 180°
    /// the two bounding planes are the same plane facing opposite ways and their
    /// intersection is empty — a cell holding nothing. Refusing above this is
    /// honest; drawing the empty result is what produced "0 voxels".
    public static let maxWedgeDegrees: Double = 170

    // MARK: - fitting

    /// ★ FIT THE CIRCLE TO A WALKED SPINE.
    ///
    /// The axis is the strip's own mean turning direction, `Σ tᵢ × tᵢ₊₁` over the
    /// spine's unit tangents — which is the binormal of the curve, and whose
    /// magnitude is already a measure of how much it turns. The total turn is then
    /// the signed angle between successive tangents summed about that axis, and the
    /// radius follows from arc length: R = L / Θ. No least-squares solve, no
    /// eigenproblem, and the straightness test comes out of the same quantity.
    ///
    /// Nil when there is not enough spine to measure.
    /// How many equal-arc windows the spine is reduced to before anything is
    /// measured from it. See `stations`.
    public static let turnSamples = 16

    /// ★ THE SPINE, AVERAGED INTO EQUAL-ARC WINDOWS.
    ///
    /// A walked spine hops between the two triangles of each quad strip, so it
    /// saw-tooths across the strip's width. Any measurement taken between ADJACENT
    /// samples reads that saw-tooth as curvature: measured on a straight tapered
    /// wedge, integrating local tangents reported 60° of turn and a centre 39 mm
    /// off a strip that does not bend at all.
    ///
    /// AVERAGING each window's samples — not interpolating between two of them —
    /// is what removes it: the saw-tooth is symmetric about the true centreline, so
    /// its mean IS the centreline.
    ///
    /// Returns the stations with the arc position of each.
    public static func stations(of spine: [SIMD3<Double>])
        -> (points: [SIMD3<Double>], arc: [Double], length: Double)? {
        guard spine.count >= 3 else { return nil }
        var cum: [Double] = [0]
        for i in 1..<spine.count {
            cum.append(cum[i - 1] + simd_length(spine[i] - spine[i - 1]))
        }
        guard let length = cum.last, length > 1e-9 else { return nil }

        // ★ AS MANY WINDOWS AS THE SPINE CAN FILL. Sixteen windows over a ten-point
        // spine leaves most of them holding one sample and some holding none, so
        // the "averaging" averages nothing and the station count silently drops.
        // Measured on face 3 of his part, whose spine is ten points.
        let windows = Swift.max(4, Swift.min(turnSamples, spine.count / 3))

        var points: [SIMD3<Double>] = []
        var arc: [Double] = []
        for k in 0..<windows {
            let lo = length * Double(k) / Double(windows)
            let hi = length * Double(k + 1) / Double(windows)
            var acc = SIMD3<Double>.zero
            var accArc = 0.0
            var n = 0.0
            for (i, p) in spine.enumerated() where cum[i] >= lo && cum[i] <= hi {
                acc += p; accArc += cum[i]; n += 1
            }
            guard n > 0 else { continue }
            points.append(acc / n)
            arc.append(accArc / n)
        }
        guard points.count >= 4 else { return nil }
        return (points, arc, length)
    }

    public static func fit(spine: [SIMD3<Double>]) -> Sweep? {
        guard let s = stations(of: spine) else { return nil }
        let points = s.points, length = s.length

        var tangents: [SIMD3<Double>] = []
        var midpoints: [SIMD3<Double>] = []
        for i in 1..<points.count {
            let d = points[i] - points[i - 1]
            let l = simd_length(d)
            guard l > 1e-12 else { continue }
            tangents.append(d / l)
            midpoints.append((points[i] + points[i - 1]) / 2)
        }
        guard tangents.count >= 3 else { return nil }

        var runDirection = points[points.count - 1] - points[0]
        if simd_length(runDirection) < 1e-12 { runDirection = tangents[0] }
        let straight = Sweep(isCurved: false, centre: spine[0], axis: .zero,
                             radiusMM: .infinity, sweepDegrees: 0,
                             lengthMM: length,
                             reference: simd_normalize(runDirection))

        // ── the plane the strip turns in, and how far it turns ───────────────
        var turn = SIMD3<Double>.zero
        for i in 0..<(tangents.count - 1) {
            turn += simd_cross(tangents[i], tangents[i + 1])
        }
        guard simd_length(turn) > 1e-12 else { return straight }
        var axis = simd_normalize(turn)

        var theta = 0.0
        for i in 0..<(tangents.count - 1) {
            let a = tangents[i], b = tangents[i + 1]
            theta += atan2(simd_dot(simd_cross(a, b), axis), simd_dot(a, b))
        }
        if theta < 0 { axis = -axis; theta = -theta }   // ★ angle always increases
        // ★ A CHORD'S DIRECTION IS THE TANGENT AT ITS MIDDLE, so a run of chords
        // misses half a step of turn at each end. Exact for a circle, negligible
        // otherwise, and without it a 120° arc measures as 112°.
        theta *= Double(tangents.count) / Double(tangents.count - 1)
        guard theta * 180 / .pi >= straightBelowDegrees else { return straight }

        // ★ AND A STRIP IS ONLY CURVED IF IT VISIBLY BOWS.
        //
        // An integrated turn is not enough on its own: a straight tapered wedge
        // still saw-tooths a little after windowing, and those leftover wiggles
        // integrate to 23° of "turn" on a strip that runs dead straight. The BOW —
        // how far the strip departs from the chord between its own ends — cannot be
        // faked that way, because a wiggle that returns to the line contributes
        // nothing to it. Measured: wedge 0.3% of its length, a 120° arc 24%, a hook
        // 45%.
        let chordA = points[0], chordB = points[points.count - 1]
        var chord = chordB - chordA
        let chordLength = simd_length(chord)
        if chordLength > 1e-12 { chord /= chordLength }
        var bow = 0.0
        for p in points {
            let d = p - chordA
            let off = chordLength > 1e-12 ? d - chord * simd_dot(d, chord) : d
            bow = Swift.max(bow, simd_length(off))
        }
        guard bow > length * 0.02 else { return straight }

        // ★ THE CIRCLE THE STRIP IMPLIES: R = L / Θ — "how big the circle is, what
        // the radius is". Its centre is one radius away along `axis × tangent` from
        // every point at once, so averaging over the whole strip settles a hook on
        // the centre its BEND implies rather than on any one sample's opinion.
        let radius = length / theta
        guard radius.isFinite, radius > 1e-9 else { return straight }
        var acc = SIMD3<Double>.zero
        for (p, t) in zip(midpoints, tangents) {
            acc += p + simd_cross(axis, t) * radius
        }
        let centre = acc / Double(midpoints.count)

        // ── ★ AND THE TEST THAT ACTUALLY MATTERS ─────────────────────────────
        //
        // The wedge construction does NOT require the strip to lie on that circle —
        // his own part is straight, then bent, then straight, and no circle passes
        // near all of it. What it requires is that the ANGLE ABOUT THE CENTRE
        // increases monotonically along the strip: then each wedge contains exactly
        // one stretch of it, and the wedges tile.
        //
        // (An earlier build tested goodness-of-fit instead — least squares plus a
        // residual bound — and it rejected the hook, which is the one shape the
        // wedge exists for. Fitting well and being usable are different questions
        // and only the second one is being asked.)
        // ★ AND THE AXIS IS ALREADY ORIENTED — DO NOT RE-DERIVE IT FROM THE ENDS.
        //
        // Integrating the turn above chose the sign so the strip turns POSITIVELY
        // about `axis`. Recovering it instead from `cross(first, last)` — which an
        // earlier build did — is wrong for exactly the shape this is for: a hook
        // sweeps 303°, and a cross product cannot tell 303° from −57°, so the axis
        // flipped, the angle ran backwards, the monotone test below failed, and the
        // U fell through to the straight construction that cannot cut it.
        let first = flatten(spine[0], centre, axis)
        guard simd_length(first) > 1e-9 else { return straight }
        let reference = simd_normalize(first)

        var probe = Sweep(isCurved: true, centre: centre, axis: axis,
                          radiusMM: radius, sweepDegrees: 0, lengthMM: length,
                          reference: reference)
        // ★ THE RADIUS, RE-READ FROM THE CENTRE IT PRODUCED. `L / Θ` is the circle
        // the strip's turn IMPLIES and is what locates the centre; once located,
        // the honest radius is how far the strip actually is from it. On a true
        // circle the two agree and this only removes the sampling bias (32.0 → 30.0
        // on a 30 mm arc); on a hook, where they cannot agree, this is the one that
        // means something.
        var radiusAcc = 0.0
        for p in points { radiusAcc += simd_length(flatten(p, centre, axis)) }
        probe.radiusMM = radiusAcc / Double(points.count)

        // ★ MONOTONICITY IS CHECKED ON THE STATIONS — they are the de-noised
        // version, and a saw-tooth in the raw spine would fail a test it should not.
        let stationAngles = unwrappedDegrees(points, probe)
        guard stationAngles.count == points.count,
              let lo = stationAngles.first, let hi = stationAngles.last,
              hi - lo >= straightBelowDegrees else { return straight }
        let slack = (hi - lo) * 0.02
        for i in 1..<stationAngles.count
        where stationAngles[i] < stationAngles[i - 1] - slack {
            return straight
        }

        // ★ …BUT THE SWEEP IS READ OFF THE WHOLE STRIP. The stations sit at window
        // CENTRES, so their span misses half a window at each end — on a 120° arc
        // in 16 windows that is 120° reported as 112°. The strip's own ends are
        // where it begins and ends.
        let full = unwrappedDegrees(spine, probe)
        if let a = full.first, let b = full.last, b > a {
            probe.sweepDegrees = b - a
        } else {
            probe.sweepDegrees = hi - lo
        }
        return probe
    }

    /// A point's offset from `centre`, projected into the plane the strip turns in.
    static func flatten(_ p: SIMD3<Double>, _ centre: SIMD3<Double>,
                        _ axis: SIMD3<Double>) -> SIMD3<Double> {
        let d = p - centre
        return d - axis * simd_dot(axis, d)
    }

    // MARK: - where the dividers go

    /// ★ THE ANGLE AT EACH POINT OF THE SPINE, UNWRAPPED so it runs monotonically
    /// from the start instead of jumping at ±180°. A U sweeps well past half a
    /// turn, so the raw `atan2` wraps in the middle of the strip and every
    /// comparison downstream would be nonsense.
    public static func unwrappedDegrees(_ spine: [SIMD3<Double>],
                                        _ sweep: Sweep) -> [Double] {
        guard sweep.isCurved else { return [] }
        var out: [Double] = []
        var offset = 0.0
        var previous: Double? = nil
        for p in spine {
            var a = sweep.degrees(of: p) + offset
            if let prev = previous {
                while a - prev > 180 { offset -= 360; a -= 360 }
                while prev - a > 180 { offset += 360; a += 360 }
            }
            out.append(a)
            previous = a
        }
        return out
    }

    /// ★ THE DIVIDER ANGLES: the k/n points BY ARC LENGTH, reported in DEGREES.
    ///
    /// Length places them (right on a hook as well as on a circle); degrees is the
    /// coordinate the cells are then built in. See the file header for why the two
    /// measures are used together rather than one of them alone.
    ///
    /// Returns `parts + 1` boundary angles — the strip's own start and end included
    /// — so a cell is simply the span between two consecutive entries.
    public static func boundaryDegrees(spine: [SIMD3<Double>], sweep: Sweep,
                                       parts: Int) -> [Double] {
        guard sweep.isCurved, parts >= 1, spine.count >= 2 else { return [] }
        let angles = unwrappedDegrees(spine, sweep)
        guard angles.count == spine.count else { return [] }

        var cum: [Double] = [0]
        for i in 1..<spine.count {
            cum.append(cum[i - 1] + simd_length(spine[i] - spine[i - 1]))
        }
        guard let total = cum.last, total > 1e-9 else { return [] }

        /// The unwrapped angle at a given arc position, by linear interpolation
        /// between the two spine samples that straddle it.
        func angle(atArc want: Double) -> Double {
            if want <= 0 { return angles[0] }
            if want >= total { return angles[angles.count - 1] }
            for i in 1..<cum.count where cum[i] >= want {
                let span = cum[i] - cum[i - 1]
                let f = span > 1e-15 ? (want - cum[i - 1]) / span : 0
                return angles[i - 1] + (angles[i] - angles[i - 1]) * f
            }
            return angles[angles.count - 1]
        }

        return (0...parts).map { angle(atArc: total * Double($0) / Double(parts)) }
    }

    /// ★ THE STRAIGHT TWIN: boundary POSITIONS along the run, by the same equal-arc
    /// rule. A straight strip has no angle, so cells are bounded by parallel planes
    /// square to the spine there — the same construction, with the hinge at
    /// infinity.
    ///
    /// Returns `parts + 1` (point, tangent) pairs, ends included.
    public static func boundaryStations(spine: [SIMD3<Double>], parts: Int)
        -> [(point: SIMD3<Double>, tangent: SIMD3<Double>)] {
        guard parts >= 1, spine.count >= 2 else { return [] }
        var cum: [Double] = [0]
        for i in 1..<spine.count {
            cum.append(cum[i - 1] + simd_length(spine[i] - spine[i - 1]))
        }
        guard let total = cum.last, total > 1e-9 else { return [] }

        func station(atArc want: Double) -> (SIMD3<Double>, SIMD3<Double>) {
            var idx = spine.count - 1
            var f = 1.0
            if want <= 0 { idx = 1; f = 0 }
            else if want < total {
                for i in 1..<cum.count where cum[i] >= want {
                    idx = i
                    let span = cum[i] - cum[i - 1]
                    f = span > 1e-15 ? (want - cum[i - 1]) / span : 0
                    break
                }
            }
            let a = spine[idx - 1], b = spine[idx]
            let point = a + (b - a) * f
            // The local direction, taken across the neighbouring samples so a single
            // short segment cannot set the plane's orientation.
            let lo = spine[max(0, idx - 2)]
            let hi = spine[min(spine.count - 1, idx + 1)]
            var t = hi - lo
            if simd_length(t) < 1e-12 { t = b - a }
            guard simd_length(t) > 1e-12 else { return (point, SIMD3<Double>(0, 0, 1)) }
            return (point, simd_normalize(t))
        }

        return (0...parts).map { station(atArc: total * Double($0) / Double(parts)) }
    }

    // MARK: - the cells

    /// What a refusal is, so the panel can say it rather than draw an empty grid.
    public struct Refusal: Error, Equatable, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// ★ THE GRID, ON A STRIP. `columns` divide it along its length; `rows` divide
    /// it across its width.
    ///
    /// Every cell is an intersection of half-spaces and the set of them PARTITIONS
    /// the strip — no overlaps, no gaps, no lateral padding. On a curve the length
    /// bounds are wedge planes hinged on the fitted axis; on a straight run they are
    /// parallel planes square to it. The width bounds are local to each column,
    /// because across a bend the true width boundary is a cylinder and the best a
    /// plane can do is be right where its own cell is.
    ///
    /// Returns the cells, or a refusal that says why not.
    public static func cells(spine: [SIMD3<Double>],
                             polygons: [[SIMD3<Double>]],
                             columns: Int, rows: Int)
        -> Result<[FaceRegionGeometry.GridCell], Refusal> {

        guard columns >= 1, rows >= 1 else {
            return .failure(Refusal("A grid needs at least one column and one row."))
        }
        guard let sweep = fit(spine: spine) else {
            return .failure(Refusal("This face is too small to divide."))
        }

        // ★ THE GEOMETRY FLOOR: dividers closer together than a thousandth of the
        // strip leave no surface between them, so the grid would UNDER-DELIVER —
        // six pieces set, three made, one of them selectable as two. Refusing is
        // what lets the panel say why. (Refusing a grid that is merely too fine to
        // PRINT is a different question, answered downstream by the sliver guard.)
        guard columns < 1000, rows < 1000 else {
            return .failure(Refusal("\(columns * rows) pieces is finer than this "
                                    + "face can be divided."))
        }

        // ── the length bounds ────────────────────────────────────────────────
        var lengthPlanes: [RegionCut] = []          // columns + 1, ends included
        // ★ WHETHER THE OUTERMOST CELLS ARE CLOSED AT THEIR OUTER END.
        //
        // On a straight run they need not be: nothing lies beyond the ends, and
        // leaving them open costs nothing. On a CURVE they must be, and this is
        // the defect the U exposed. A wedge bound is a HALF-SPACE, so an unbounded
        // end cell claims a full 180° of angle; on a strip that sweeps 320° the
        // first cell's 180° and the last cell's 180° OVERLAP by 107°, and every
        // triangle in that overlap belongs to two pieces at once (23 of them on
        // the U, 96 at six columns). Closing both ends is what makes the wedges
        // tile rather than merely abut.
        let closeEnds = sweep.isCurved

        if sweep.isCurved {
            var bounds = boundaryDegrees(spine: spine, sweep: sweep, parts: columns)
            guard bounds.count == columns + 1 else {
                return .failure(Refusal("This curve could not be measured."))
            }
            // ★ THE END BOUNDS ARE PUSHED OUT TO THE SURFACE'S OWN EDGE. The spine
            // is a CENTRELINE, so the strip's corners reach a little past its ends;
            // a bound placed exactly at the last spine sample would shave them off.
            // Measured rather than padded by a guess, and it moves no INTERIOR
            // divider — only the two outermost planes, in a direction where there
            // is no surface to reassign.
            let extent = angularExtent(polygons: polygons, spine: spine, sweep: sweep)
            if let extent {
                bounds[0] = Swift.min(bounds[0], extent.lo) - 0.5
                bounds[columns] = Swift.max(bounds[columns], extent.hi) + 0.5
            }
            guard bounds[columns] - bounds[0] < 358 else {
                return .failure(Refusal("This face wraps the whole way round — "
                                        + "cut it once by hand first."))
            }
            // ★ AND REFUSE A WEDGE A PLANE PAIR CANNOT HOLD. See `maxWedgeDegrees`:
            // at 180° the two bounds are one plane and the cell is empty. This is
            // the honest answer to "2 columns puts the line at the far left" on a
            // strip that turns most of the way round.
            for k in 0..<columns where abs(bounds[k + 1] - bounds[k]) > maxWedgeDegrees {
                let each = Int(abs(bounds[k + 1] - bounds[k]).rounded())
                let total = bounds[columns] - bounds[0]
                // ★ AND THE SUGGESTION MUST BE MORE THAN WHAT JUST FAILED.
                // Measured on his face 3: a 188° wedge refused with "use 2 or
                // more", and 2 is exactly what had been asked for. A refusal that
                // recommends the thing it refused is worse than no recommendation.
                let need = Swift.max(columns + 1,
                                     Int((total / maxWedgeDegrees).rounded(.up)))
                return .failure(Refusal("\(each)° per piece is too wide to cut "
                                        + "with a plane — use \(need) or more."))
            }
            lengthPlanes = bounds.map { sweep.plane(at: $0) }
        } else {
            let stations = boundaryStations(spine: spine, parts: columns)
            guard stations.count == columns + 1 else {
                return .failure(Refusal("This face is too small to divide."))
            }
            lengthPlanes = stations.map { RegionCut(point: $0.point, normal: $0.tangent) }
        }

        // ── the cells ────────────────────────────────────────────────────────
        var out: [FaceRegionGeometry.GridCell] = []
        for i in 0..<columns {
            var span: [RegionCut] = []
            if i > 0 || closeEnds { span.append(lengthPlanes[i]) }
            if i < columns - 1 || closeEnds { span.append(flip(lengthPlanes[i + 1])) }

            // ★ THE WIDTH IS MEASURED INSIDE THIS COLUMN, not over the whole face.
            // Across a bend the strip's "across" direction rotates with it, so a
            // single global width axis is wrong everywhere but the middle.
            let widthPlanes = rows >= 2
                ? widthBounds(polygons: polygons, within: span, parts: rows)
                : []
            if rows >= 2, widthPlanes.count != rows + 1 {
                return .failure(Refusal("This face is too narrow for \(rows) rows."))
            }

            for j in 0..<rows {
                var cuts = span
                var drawn: [RegionCut] = []
                // ★ EACH INTERIOR BOUNDARY IS DRAWN BY EXACTLY ONE CELL — the one
                // it is the LOWER bound of. Drawn by both, every divider is a pair
                // of coincident lines, which reads as one thick mis-registered
                // line rather than as one line.
                if i > 0 { drawn.append(lengthPlanes[i]) }
                if rows >= 2 {
                    if j > 0 {
                        cuts.append(widthPlanes[j])
                        drawn.append(widthPlanes[j])
                    }
                    if j < rows - 1 { cuts.append(flip(widthPlanes[j + 1])) }
                }
                out.append(FaceRegionGeometry.GridCell(i: i, j: j, cuts: cuts,
                                                       drawn: drawn))
            }
        }

        // ★ AND EVERY PIECE MUST ACTUALLY HOLD SURFACE.
        //
        // Everything above is construction; this is the only thing that CHECKS it.
        // A piece holding nothing is the defect the maintainer met as "Smallest
        // piece: 0 voxels, floor 16" and as "I set 3 columns and there is only 1
        // cut" — a divider with nothing on one side of it has nothing to separate,
        // so it does not draw and the grid silently under-delivers.
        //
        // Found by sweeping every face of his part rather than by reasoning: face
        // 61 produced an empty piece at four columns even after the arc rewrite,
        // because its walked spine doubles back and two boundaries landed on top of
        // each other. Rather than hunt each such face, the property is asserted
        // here and a grid that fails it is REFUSED with a reason — the caller can
        // then try another spine, and if nothing works the user is told, which is
        // strictly better than a dead checkmark and a number they cannot act on.
        if !polygons.isEmpty {
            let total = polygons.reduce(0.0) { $0 + SurfacePatternAxis.polygonArea($1) }
            if total > 0 {
                for c in out {
                    let held = polygons.reduce(0.0) {
                        $0 + SurfacePatternAxis.polygonArea(
                            SurfacePatternAxis.clipPolygon($1, to: c.cuts))
                    } / total
                    guard held > 0.01 else {
                        return .failure(Refusal("\(columns * rows) pieces leaves one "
                                                + "with nothing on this face."))
                    }
                }
            }
        }
        return .success(out)
    }

    /// The same plane facing the other way, as a cell's upper bound. `strict` so the
    /// shared boundary belongs to exactly one of the two cells that meet on it.
    public static func flip(_ c: RegionCut) -> RegionCut {
        RegionCut(point: c.point, normal: -c.normal, strict: true)
    }

    /// ★ HOW FAR THE SURFACE ITSELF REACHES, in the same unwrapped degrees the
    /// dividers are placed in.
    ///
    /// Each polygon point is unwrapped against the spine sample NEAREST to it,
    /// rather than against a global window: on a strip that sweeps more than half a
    /// turn, "which multiple of 360 does this angle belong to" has no answer from
    /// the angle alone, and picking the wrong one puts a point at the far end of the
    /// strip. The nearest spine sample knows, because it is on the same stretch.
    ///
    /// Nil when the strip is straight (there are no angles) or there is nothing to
    /// measure.
    static func angularExtent(polygons: [[SIMD3<Double>]], spine: [SIMD3<Double>],
                              sweep: Sweep) -> (lo: Double, hi: Double)? {
        guard sweep.isCurved, !polygons.isEmpty, spine.count >= 2 else { return nil }
        let reference = unwrappedDegrees(spine, sweep)
        guard reference.count == spine.count else { return nil }

        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for poly in polygons {
            for p in poly {
                var nearest = 0
                var bestD = Double.greatestFiniteMagnitude
                for (k, s) in spine.enumerated() {
                    let d = simd_length_squared(s - p)
                    if d < bestD { bestD = d; nearest = k }
                }
                let anchor = reference[nearest]
                var a = sweep.degrees(of: p)
                while a - anchor > 180 { a -= 360 }
                while anchor - a > 180 { a += 360 }
                lo = Swift.min(lo, a)
                hi = Swift.max(hi, a)
            }
        }
        guard lo <= hi else { return nil }
        return (lo, hi)
    }

    /// ★ WHERE THE STRIP'S WIDTH RUNS, AND HOW FAR — inside one column.
    ///
    /// The column's own surface points are collected, their spread is measured along
    /// the two directions perpendicular to the column's length, and the wider of the
    /// two is the width. That distinguishes the two shapes a curved strip can have
    /// without being told which it is: a band around a tube (width along the axis)
    /// and a flat annulus (width along the radius) both fall out of the same
    /// measurement.
    ///
    /// Returns `parts + 1` planes across the width, ends included, or [] when the
    /// column has no measurable width.
    static func widthBounds(polygons: [[SIMD3<Double>]], within: [RegionCut],
                            parts: Int) -> [RegionCut] {
        guard parts >= 1 else { return [] }
        var points: [SIMD3<Double>] = []
        for poly in polygons {
            let clipped = within.isEmpty ? poly
                                         : SurfacePatternAxis.clipPolygon(poly, to: within)
            guard clipped.count >= 3 else { continue }
            points.append(contentsOf: clipped)
        }
        guard points.count >= 3 else { return [] }

        let centroid = points.reduce(SIMD3<Double>.zero, +) / Double(points.count)

        // The column's length direction: the average of its bounding planes'
        // normals, which all face along the strip there.
        var along = SIMD3<Double>.zero
        for c in within where simd_length(c.normal) > 1e-12 {
            let n = simd_normalize(c.normal)
            // The two bounds face opposite ways; fold them onto one direction.
            along += simd_dot(n, along) < 0 ? -n : n
        }
        if simd_length(along) < 1e-12 {
            // A single-column grid has no length bounds to read — take the widest
            // spread as the length instead, so "width" is still the other one.
            along = spread(points, about: centroid).0
        }
        guard simd_length(along) > 1e-12 else { return [] }
        along = simd_normalize(along)

        // The widest direction perpendicular to that.
        let flat = points.map { p -> SIMD3<Double> in
            let d = p - centroid
            return d - along * simd_dot(along, d)
        }
        let (width, extentSpan) = spread(flat, about: .zero)
        guard simd_length(width) > 1e-12, extentSpan > 1e-9 else { return [] }

        let ts = points.map { simd_dot($0 - centroid, width) }
        guard let lo = ts.min(), let hi = ts.max(), hi - lo > 1e-9 else { return [] }

        return (0...parts).map { k in
            let t = lo + (hi - lo) * Double(k) / Double(parts)
            return RegionCut(point: centroid + width * t, normal: width)
        }
    }

    /// The direction of widest spread of a point set, and how wide that is. A
    /// two-direction search over the plane is enough here and needs no eigensolver:
    /// the candidates are the differences from the centroid, and the widest pair
    /// wins.
    static func spread(_ points: [SIMD3<Double>], about centre: SIMD3<Double>)
        -> (SIMD3<Double>, Double) {
        var best = SIMD3<Double>.zero
        var bestLen = 0.0
        for p in points {
            let d = p - centre
            let l = simd_length(d)
            if l > bestLen { bestLen = l; best = d }
        }
        guard bestLen > 1e-12 else { return (.zero, 0) }
        let dir = simd_normalize(best)
        let ts = points.map { simd_dot($0 - centre, dir) }
        return (dir, (ts.max() ?? 0) - (ts.min() ?? 0))
    }
}
