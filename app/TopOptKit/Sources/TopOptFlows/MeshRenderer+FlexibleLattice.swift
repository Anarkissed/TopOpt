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

extension MeshRenderer {

    /// The Flexible pass draws this frame: present, uploaded, not hidden.
    var flexibleLatticeInFrame: Bool { flexibleLattice?.isDrawable == true }

    /// A see-through body stays OUT of the G-buffer while the Flexible pass draws, so the
    /// ghost cannot occlude the walls it is meant to show (rule 1 above).
    var flexibleGhostOutOfGBuffer: Bool {
        guard let fx = flexibleLattice, fx.isDrawable, !fx.controlKeepGhostInGBuffer else { return false }
        return bodyAlpha < 0.999
    }

    /// The see-through body is drawn AFTER the opaque lattice shade, not before it (rule 2).
    /// `latticeShaded`: the shade block runs this frame (the G-buffer exists).
    func flexibleGhostAfterLattice(translucent: Bool, latticeShaded: Bool) -> Bool {
        guard let fx = flexibleLattice, fx.isDrawable, !fx.controlDrawGhostFirst else { return false }
        return translucent && latticeShaded
    }

    /// Test control only: bind the lattice-only AO to the re-issued body.
    var flexibleGhostKeepsAO: Bool { flexibleLattice?.controlKeepAOForGhost == true }

    /// THE ONE ENTRY POINT for the Flexible lattice (called from the view's apply). Uploads
    /// once per TOKEN; `hidden` flips without re-uploading; nil tears the pass down.
    /// Returns true when the frame must be redrawn. The pass is built on `device` — the
    /// view's, which is this renderer's.
    @discardableResult
    func applyFlexibleLattice(_ inputs: FlexibleLatticeLayerInputs?, device: MTLDevice?) -> Bool {
        guard let inputs else {
            guard flexibleLattice != nil else { return false }
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
        }
        if pass.hidden != inputs.hidden {
            pass.hidden = inputs.hidden
            changed = true
        }
        return changed
    }
}
#endif
