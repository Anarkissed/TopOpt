// OrbitCameraModel.swift — the ONE shared orbit-camera source of truth (the
// 3d-gizmo-orbit-camera task, STEP 1).
//
// Before this, every `MetalMeshView` buried its own `OrbitCamera` inside its private
// renderer, so nothing else — least of all a corner widget — could read or drive it.
// This lifts the camera into a `@MainActor ObservableObject` that a screen creates
// once and hands to BOTH its Metal viewer AND its orientation gizmo, so the drag, the
// cube, and the snap all move the same state in lockstep.
//
// The orbit itself already did the right thing (full azimuth + elevation, elevation
// clamped just under the poles — see `OrbitCamera.orbit`); the friction the maintainer
// hit was that free-drag alone can never land a *clean* canonical view and there was no
// home to return to. So this model adds the accelerators: `snap(to:)` eases to a named
// view and `home()` returns to the default the viewer opens at.
//
// Everything mutating the orientation funnels through here, and the pure end-states
// (snap targets, home) are headlessly tested; only the eased *animation* needs a clock.

import Foundation
import simd
import Combine
#if canImport(QuartzCore)
import QuartzCore
#endif

@MainActor
public final class OrbitCameraModel: ObservableObject {
    /// The live camera. Published so the viewer redraws and the gizmo re-renders on any
    /// change (drag, zoom, snap tick, reframe).
    @Published public private(set) var camera: OrbitCamera

    /// The default orientation a freshly-opened viewer uses — captured from the initial
    /// camera so `home()` returns to exactly that (not an invented angle). For the
    /// stock `OrbitCamera()` this is azimuth π/4, elevation π/6 (the M7.4 default view).
    public let defaultAzimuth: Float
    public let defaultElevation: Float

    /// ~0.3s eased snap/home transition (the task's target; NOT an instant teleport).
    public static let transitionDuration: CFTimeInterval = 0.3

    public init(camera: OrbitCamera = OrbitCamera()) {
        self.camera = camera
        self.defaultAzimuth = camera.azimuth
        self.defaultElevation = camera.elevation
    }

    // MARK: - Live drag / zoom (STEP 2: full orbit, elevation clamped)

    /// Free-drag orbit: horizontal turns azimuth, vertical changes elevation (clamped
    /// near the poles so the view can always be levelled to a clean front). Cancels any
    /// running snap so a grab always wins.
    public func orbit(dx: Float, dy: Float) {
        stopAnimation()
        camera.orbit(dx: dx, dy: dy)
    }

    /// Pinch / scroll zoom (clamped to the framed distance limits).
    public func zoom(_ factor: Float) {
        stopAnimation()
        camera.zoom(factor)
    }

    /// Refit distance/target/limits to a new mesh WITHOUT disturbing the user's
    /// orientation (azimuth/elevation are preserved by `frame`). Called when a viewer
    /// loads or swaps its mesh.
    public func reframe(_ bounds: MeshBounds) {
        camera.frame(bounds)
    }

    /// Replace the whole camera (used to adopt the framing a renderer computed for a
    /// fresh mesh while keeping this model the single source of truth).
    public func adopt(_ newCamera: OrbitCamera) {
        camera = newCamera
    }

    // MARK: - Snap / home (STEP 3 accelerators)

    /// Ease the camera to a named region's canonical view (Front, Top, a corner, …).
    /// `animated == false` snaps immediately (reduced-motion / tests).
    public func snap(to region: GizmoRegion, animated: Bool = true) {
        let target = region.orientation(currentAzimuth: camera.azimuth)
        setOrientation(azimuth: target.azimuth, elevation: target.elevation, animated: animated)
    }

    /// Convenience: snap to a region id ("Front", "Top", "Front-Top-Right").
    public func snap(toID id: String, animated: Bool = true) {
        guard let region = OrientationGizmo.region(id) else { return }
        snap(to: region, animated: animated)
    }

    /// Return to the viewer's default view angle (the Home button).
    public func home(animated: Bool = true) {
        setOrientation(azimuth: defaultAzimuth, elevation: defaultElevation, animated: animated)
    }

    /// The world→view rotation the gizmo renders the cube with — taken verbatim from the
    /// live camera so the widget can never diverge from what the viewer shows.
    public var viewRotation: simd_float3x3 { camera.viewRotation() }

    // MARK: - Orientation transition

    private func setOrientation(azimuth: Float, elevation: Float, animated: Bool) {
        let targetEl = OrbitCamera.clampElevation(elevation)
        guard animated else {
            stopAnimation()
            camera.setOrientation(azimuth: azimuth, elevation: targetEl)
            return
        }
        startAnimation(toAzimuth: azimuth, toElevation: targetEl)
    }

    // MARK: - Eased animation (needs a clock; excluded from the headless end-state tests)

    private var displayLink: AnyObject?
    private var animFromAz: Float = 0
    private var animFromEl: Float = 0
    private var animToAz: Float = 0
    private var animToEl: Float = 0
    private var animStart: CFTimeInterval = 0

    /// True while a snap/home transition is running (drivable by a host that prefers to
    /// tick the animation itself).
    public private(set) var isAnimating = false

    private func startAnimation(toAzimuth: Float, toElevation: Float) {
        animFromAz = camera.azimuth
        animFromEl = camera.elevation
        // Shortest angular path for azimuth (it wraps); elevation is bounded so it lerps
        // linearly. Unwrapping the target relative to the start avoids a 350°-the-long-way
        // spin when the numeric values straddle ±π.
        animToAz = animFromAz + shortestDelta(from: animFromAz, to: toAzimuth)
        animToEl = toElevation
        animStart = now()
        isAnimating = true
        startClock()
    }

    private func tick() {
        guard isAnimating else { return }
        let elapsed = now() - animStart
        let raw = Self.transitionDuration > 0 ? Float(elapsed / Self.transitionDuration) : 1
        let t = Swift.min(1, Swift.max(0, raw))
        let e = easeInOut(t)
        let az = animFromAz + (animToAz - animFromAz) * e
        let el = animFromEl + (animToEl - animFromEl) * e
        camera.setOrientation(azimuth: az, elevation: el)
        if t >= 1 {
            camera.setOrientation(azimuth: animToAz, elevation: animToEl)
            stopAnimation()
        }
    }

    /// Stop any running transition (a fresh drag or a new snap pre-empts it).
    public func stopAnimation() {
        isAnimating = false
        stopClock()
    }

    private func shortestDelta(from: Float, to: Float) -> Float {
        var d = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    private func easeInOut(_ t: Float) -> Float {
        // Smoothstep — matches the app's gentle sheet easing closely enough for a cube.
        t * t * (3 - 2 * t)
    }

    private func now() -> CFTimeInterval {
        #if canImport(QuartzCore)
        return CACurrentMediaTime()
        #else
        return 0
        #endif
    }

    // A lightweight repeating clock. CADisplayLink on iOS/tvOS, a main-runloop Timer on
    // macOS/elsewhere; both just call `tick()` until the transition lands.
    private func startClock() {
        stopClock()
        #if canImport(QuartzCore) && (os(iOS) || os(tvOS) || os(visionOS))
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() },
                                 selector: #selector(DisplayLinkProxy.fire))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #else
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayLink = timer
        #endif
    }

    private func stopClock() {
        #if canImport(QuartzCore) && (os(iOS) || os(tvOS) || os(visionOS))
        (displayLink as? CADisplayLink)?.invalidate()
        #else
        (displayLink as? Timer)?.invalidate()
        #endif
        displayLink = nil
    }
}

#if canImport(QuartzCore) && (os(iOS) || os(tvOS) || os(visionOS))
/// Bridges a CADisplayLink's selector target to a closure (CADisplayLink retains its
/// target, so this proxy — not the model — is what it holds).
private final class DisplayLinkProxy: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
#endif
