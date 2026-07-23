#pragma once

#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/segment.hpp"
#include "topopt/step.hpp"

namespace topopt {

// ---------------------------------------------------------------------------
// The ONE part-import adapter (handoff 134).
//
// Downstream, everything that selects, tags, masks, clears or optimizes takes a
// `const StepModel&` — it is the interface, and `face_id` is the contract. This
// header is the single place that decides where a StepModel comes from:
//
//   .step / .stp  -> OCCT B-rep import, REAL faces      (unchanged, byte for byte)
//   .stl          -> mesh import + dihedral segmentation -> PSEUDO-faces
//   .3mf          -> mesh import + dihedral segmentation -> PSEUDO-faces
//
// Callers cannot tell the difference, and no downstream code was changed to
// accommodate meshes. `PartModel::pseudo_faces` records which source was used
// so the UI can be honest about it, not so behaviour can branch on it.
//
// SCOPE (Phase 1): clean, manifold, closed meshes. A mesh that is non-manifold,
// open, non-orientable or zero-thickness is REFUSED with a structured
// diagnosis (`PartInspection`) the app renders as a plain-language sheet — it
// is never a crash and never a silent half-import. Two repairs are performed
// automatically because they are unambiguous: duplicate-vertex welding and
// normal unification (consistent winding + outward orientation). Anything
// deeper — hole filling, self-intersection resolution, shell thickening,
// remeshing — is explicitly Phase 2 and is NOT attempted.

// Thrown when a part cannot be imported. `inspection` carries the structured
// reason when the failure was a mesh-quality refusal (defects non-empty); for a
// missing file or an unparseable one it is left at its default and only
// what() is meaningful.
class PartError : public std::runtime_error {
 public:
  explicit PartError(const std::string& msg) : std::runtime_error(msg) {}
};

enum class PartFormat { Step, Stl, ThreeMf, Unknown };

// A structural defect that makes a mesh unusable for Phase 1. These are
// REFUSALS, not warnings: each one breaks an assumption the voxelizer or the
// face selection relies on.
enum class PartDefect {
  // No triangles at all (empty or unparseable-but-not-fatal file).
  EmptyMesh,
  // An edge used by three or more triangles. Inside/outside is undefined at
  // such an edge, so voxelization cannot decide what is solid.
  NonManifoldEdges,
  // An edge used by exactly one triangle: the surface is open (a hole, or a
  // surface patch that was never a solid).
  OpenBoundary,
  // The surface cannot be consistently oriented (neighbouring triangles
  // disagree in a way no global flip resolves — a non-orientable surface).
  // This is "inverted normals beyond repairable"; the repairable case is fixed
  // silently and reported as `flipped_triangles`.
  NonOrientable,
  // The mesh closes, but encloses no meaningful volume relative to its own
  // bounding box — a zero-thickness shell (a surface doubled back on itself).
  ZeroThickness,
};

// What the importer found and what it repaired. Produced for MESH imports; a
// STEP import leaves it default (`checked == false`) because the B-rep path is
// untouched by this work.
struct PartInspection {
  bool checked = false;
  bool acceptable = false;
  std::vector<PartDefect> defects;  // empty iff acceptable

  // Raw counts behind the verdict.
  int boundary_edges = 0;
  int non_manifold_edges = 0;
  int degenerate_triangles = 0;  // zero-area / repeated-index, dropped

  // Repairs applied (reported, not hidden — the user's file was changed in
  // memory, and the sheet says so).
  int welded_vertices = 0;   // duplicate vertices merged (3MF does not weld)
  int flipped_triangles = 0; // triangles re-wound during normal unification

  // Measured geometry, in FILE units. The app needs these for the STL unit
  // prompt's size sanity hint (STL carries no unit).
  double volume = 0.0;
  Vec3 bbox_min{0.0, 0.0, 0.0};
  Vec3 bbox_max{0.0, 0.0, 0.0};
};

// Import options. `tessellation` applies to STEP only; `segmentation` applies
// to mesh formats only.
struct PartOptions {
  StepTessellation tessellation;
  SegmentOptions segmentation;
};

// The imported part: a StepModel every downstream consumer already accepts,
// plus provenance.
struct PartModel {
  StepModel model;
  PartFormat format = PartFormat::Unknown;
  // true when `model.faces` were MANUFACTURED by segmentation rather than read
  // from a B-rep. For honest UI copy only — no downstream behaviour branches
  // on it.
  bool pseudo_faces = false;
  PartInspection inspection;
};

// Classify a path by extension (case-insensitive). Unknown extensions are
// treated as Stl by `import_part`, matching the historic bridge behaviour
// (import_any fell through to the STL reader).
PartFormat part_format_for_path(const std::string& path);

// Import any supported part file into a face-carrying StepModel.
// Throws PartError if the file cannot be read or parsed, if STEP is requested
// where OCCT is not compiled in, if 3MF is requested where lib3mf is not, or
// if a mesh is refused by inspection. On a mesh refusal, use `inspect_part_file`
// to get the structured reason for the sheet.
PartModel import_part(const std::string& path, const PartOptions& opts = {});

// The drop-in replacement for `import_step_file` at the stateless call sites:
// same signature shape, same return type, dispatches by extension. STEP inputs
// take the identical code path they always did.
StepModel import_part_file(const std::string& path,
                           const StepTessellation& tess = {});

// Inspect a mesh file WITHOUT throwing on refusal: returns the same
// PartInspection `import_part` would have produced, so the app can build its
// refusal sheet from the structured verdict. A file that cannot be read or
// parsed at all still throws PartError (there is nothing to inspect). For a
// STEP path this returns `checked == false, acceptable == true`.
PartInspection inspect_part_file(const std::string& path);

// A one-line, human-readable summary of a defect. The app writes its own
// longer copy; this exists so the CLI and logs say the same thing.
std::string describe_defect(PartDefect defect);

// ---------------------------------------------------------------------------
// Repairs and unit handling, exposed because they are independently testable.

// Merge geometrically identical vertices (exact coordinate match, the same rule
// the STL reader uses) and drop triangles that reference a vertex twice or
// enclose zero area. Returns the repaired mesh; `out_welded` receives the
// number of vertices removed and `out_degenerate` the number of triangles
// dropped.
TriangleMesh weld_and_clean(const TriangleMesh& mesh, int& out_welded,
                            int& out_degenerate);

// Unify triangle winding: propagate a consistent orientation across shared
// edges, then flip the whole mesh if its signed volume came out negative, so
// the result is outward-wound. Returns false if the surface is NON-ORIENTABLE
// (no consistent assignment exists), in which case `mesh` is left unchanged.
// `out_flipped` receives the number of triangles whose winding was reversed.
bool unify_normals(TriangleMesh& mesh, int& out_flipped);

// Read a mesh file, scale every vertex by `scale`, and write it back out as a
// binary STL at `out_path`. This is how a unit choice is applied: STL carries
// no unit, so the app asks, and the answer is baked into the app-owned working
// copy ONCE. Every stateless downstream call then re-reads a file that is
// already in millimetres, which is why no unit has to be threaded through the
// bridge, the job schema, or persistence. Throws PartError on a read/write
// failure or a non-positive scale.
void rescale_part_file(const std::string& in_path, const std::string& out_path,
                       double scale);

}  // namespace topopt
