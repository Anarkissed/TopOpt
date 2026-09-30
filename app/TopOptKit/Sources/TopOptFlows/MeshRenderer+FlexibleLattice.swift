// MeshRenderer+FlexibleLattice — the GATES the Flexible pass needs in #354's frame (task
// 2026-09-29-flexible-screens, in-pass round). The hooks in MetalMeshView.swift are one
// line each and call these; all the logic lives here, in #362's own file.
//
// ★ WHY TWO EXTRA RULES. Structural and Aesthetic only ever draw the body at alpha 1 or 0.
// The Flexible X-ray draws it as a 0.04 GHOST, and two of #354's rules then break the
// picture:
//   1. `shellVisible = bodyAlpha > 0.004` rasterises the ghost into the G-buffer with depth
//      write on, and the shell writes albedo alpha 0 there — every wall behind it fails the
//      depth test, and lsdf_shade discards those pixels. The ghost would HIDE the walls.
//   2. The translucent body is drawn before the opaque lsdf_shade, which then paints over
//      the ghost AND the "100 %" dent. The shade would paint over the ghost and the map.
// So, ONLY while a Flexible pass is drawable: a see-through body stays out of the G-buffer
// (`flexibleGhostOutOfGBuffer`), and the body draw is moved to just AFTER the shade
// (`flexibleGhostAfterLattice`), with neutral AO (`flexibleGhostKeepsAO` is a test
// control) so the lattice-only occlusion and creases do not print on the heat map.
// Then ghost fragments in front of a wall blend over it, ghost back faces behind a wall
// fail against the depth lsdf_shade wrote, the a = 1 dent quads (the overlay mesh's last
// triangles) replace the walls behind them, and walls nearer than the dent occlude it.
//
// ★ NO-OP WHEN ABSENT. With `flexibleLattice` nil, not uploaded, or hidden, every gate
// below is false and each hook collapses to #354's expression (T12 renders the octet's
// frames byte-identical in all three cases).

#if canImport(MetalKit)
import MetalKit
import QuartzCore

extension MeshRenderer {

    /// The Flexible pass draws this frame: present, uploaded, not hidden — AND #354's two
    /// lattice pipelines built. Its walls are lit by #354's `lsdf_shade` (built with `try?`):
    /// without it they would be written into the G-buffer, where AO and creases read them,
    /// but never shaded, and the ghost would still leave the G-buffer — lattice-shaped AO on
    /// the ghost and the map. Every gate below keys on this, so they all fall back together.
    var flexibleLatticeInFrame: Bool { flexibleLattice?.isDrawable == true && latticePipelinesDidBuild }

    /// A see-through body stays OUT of the G-buffer while the Flexible pass draws, so the
    /// ghost cannot occlude the walls it is meant to show (rule 1 above).
    var flexibleGhostOutOfGBuffer: Bool {
        guard flexibleLatticeInFrame, let fx = flexibleLattice, !fx.controlKeepGhostInGBuffer else { return false }
        return bodyAlpha < 0.999
    }

    /// The see-through body is drawn AFTER the opaque lattice shade, not before it (rule 2).
    /// `latticeShaded`: the shade block runs this frame (the G-buffer exists).
    func flexibleGhostAfterLattice(translucent: Bool, latticeShaded: Bool) -> Bool {
        guard flexibleLatticeInFrame, let fx = flexibleLattice, !fx.controlDrawGhostFirst else { return false }
        return translucent && latticeShaded
    }

    /// Test control only: bind the lattice-only AO to the re-issued body.
    var flexibleGhostKeepsAO: Bool { flexibleLattice?.controlKeepAOForGhost == true }

    /// THE ONE ENTRY POINT for the Flexible lattice (called from the view's apply). Uploads
    /// once per TOKEN; `hidden` flips without re-uploading; nil tears the pass down.
    /// Returns true when the frame must be redrawn. The pass is built on `device` — the
    /// view's, which is this renderer's. `baseScale`: the view's OWN flexScale (the
    /// coordinator's), restored when a loop stops driving it (batch B review).
    @discardableResult
    func applyFlexibleLattice(_ inputs: FlexibleLatticeLayerInputs?, device: MTLDevice?, baseScale: Float? = nil) -> Bool {
        guard let inputs else {
            guard let old = flexibleLattice else { return false }
            releaseFlexibleLoop(old.loop, baseScale: baseScale)
            flexibleLattice = nil
            return true
        }
        if flexibleLattice == nil {
            // a library that failed to compile does not get rebuilt every frame
            guard let device, FlexibleLatticePass.lastInitError == nil else { return false }
            do { flexibleLattice = try FlexibleLatticePass(device: device) }
            catch {
                FlexibleLatticePass.lastInitError = "\(error)"
                NSLog("DIAG flexible lattice: %@", "\(error)")
                return false
            }
        }
        guard let pass = flexibleLattice else { return false }
        var changed = false
        if pass.token != inputs.token {
            pass.upload(inputs)
            changed = true
        } else if pass.facesToken != inputs.facesToken {
            // ★ ROUND 4 (D2): the player's pick — the same lattice, other faces squishing
            pass.uploadFaces(inputs)
            changed = true
        }
        // ★ BATCH G: the squeeze groups' FE fields (once per feToken) and the loop's sequence
        if pass.feToken != inputs.feToken {
            pass.uploadFE(inputs)
            changed = true
        } else if pass.feSequence != inputs.feSequence {
            pass.setFESequence(inputs.feSequence)
            changed = true
        }
        if pass.hidden != inputs.hidden {
            pass.hidden = inputs.hidden
            changed = true
        }
        if pass.loop !== inputs.loop {
            releaseFlexibleLoop(pass.loop, baseScale: baseScale)
            pass.loop = inputs.loop
            changed = true
        }
        return changed
    }

    /// ★ A LOOP TAKEN AWAY MID-PLAY GIVES THE VIEW BACK (batch B review). The step re-pauses
    /// the view only when it runs WITH a paused loop; when the loop is detached (Settings goes
    /// up, the lattice goes stale) or the pass torn down (he leaves the stage), no step ever
    /// runs for it again — the main view kept drawing at display rate under the full-screen
    /// page and on every other stage, and the dent stayed frozen at the loop's last frame
    /// (the coordinator re-sends flexScale only when ITS value changes). So, on that edge:
    /// the view's own flexScale comes back, the view returns to on-demand drawing (unless a
    /// settle or a pulse still animates), and the loop forgets the view (a later play must
    /// not wake a view nothing steps it in).
    private func releaseFlexibleLoop(_ loop: FlexibleSquishLoop?, baseScale: Float?) {
        guard let loop else { return }
        if let s = baseScale { setFlexScale(s) }
        let view = loop.view
        loop.view = nil
        guard loop.renderingContinuously else { return }
        loop.renderingContinuously = false
        if let view, !isSettling, !isPulsing {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
    }

    // MARK: the main page's squish loop (round 3 batch B)

    /// ★ THE MAIN PAGE'S SQUISH RUNS IN THE RENDERER (plan: a 30 fps publish would re-run
    /// WorkspacePlaceholder's 11.7k-line body 30 times a second). The loop's scale for a frame
    /// at `now`, or nil when no loop drives this view (no Flexible pass, nothing uploaded, or
    /// no loop handed over — then #354's flexScale stands, byte for byte).
    /// Hidden walls still loop the DENT (the Lattice view off keeps the squish on the map).
    func flexibleLoopScale(now: CFTimeInterval) -> Float? {
        guard let pass = flexibleLattice, pass.token >= 0, let loop = pass.loop else { return nil }
        return loop.scale(at: now)
    }

    /// The top of `draw(in:)`: set THIS frame's flexScale from the loop — the one float the
    /// dent's vertices and the walls both read — and keep frames coming while it plays.
    /// Returns true while the loop needs continuous frames (the settle's end must not pause
    /// the view under it). A pause or a drag draws its frame and returns the view to
    /// on-demand drawing (battery), unless a settle or a pulse still animates.
    @discardableResult
    func stepFlexibleLoop(in view: MTKView, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard let s = flexibleLoopScale(now: now), let loop = flexibleLattice?.loop else { return false }
        loop.attach(view)
        setFlexScale(s)
        stepFlexibleFE(loop, now: now)
        if loop.playing {
            if view.isPaused { view.isPaused = false }
            if view.enableSetNeedsDisplay { view.enableSetNeedsDisplay = false }
            loop.renderingContinuously = true
            return true
        }
        if loop.renderingContinuously {
            loop.renderingContinuously = false
            if !isSettling && !isPulsing {
                view.isPaused = true
                view.enableSetNeedsDisplay = true
            }
        }
        return false
    }

    /// ★ BATCH G: the loop's squeeze on screen. Each group is its own sim; "Play all" plays them one
    /// after another: the loop's CYCLE picks the sequence entry, and the field AND the mesh
    /// displacements are swapped TOGETHER, in the same step, only as a cycle begins (amount =
    /// ease(0) = 0 — nothing pops) — or at once when nothing is bound or the loop is paused (a
    /// pick). The loop learns what is shown (`shownIndex`) so the page's H4 hands the same mesh.
    func stepFlexibleFE(_ loop: FlexibleSquishLoop, now: CFTimeInterval) {
        guard let pass = flexibleLattice, !pass.feSequence.isEmpty else { return }
        if let lag = pass.controlPendingMesh, lag < pass.feMesh.count {   // (the red control's late mesh)
            setFlexDisplacements(pass.feMesh[lag]); pass.feMeshShown = lag; pass.controlPendingMesh = nil
        }
        let cycle = loop.cycle(at: now)
        let n = pass.feSequence.count
        let want = pass.feSequence[((cycle % n) + n) % n]
        defer { pass.feCycle = cycle }
        guard want != pass.feShown else { return }
        guard pass.feShown < 0 || !loop.playing || pass.feCycle != cycle || pass.controlSwapAnywhere else { return }
        pass.bindFE(want)
        if pass.controlSwapMeshNextFrame {
            pass.controlPendingMesh = want   // RED CONTROL: the mesh lags the field one frame
        } else if want < pass.feMesh.count {
            setFlexDisplacements(pass.feMesh[want])
            pass.feMeshShown = want
        }
        loop.shownIndex = want
    }
}
#endif
