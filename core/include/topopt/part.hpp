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
// SCOPE (Phase 2): before refusing, the importer ATTEMPTS a deterministic,
// conservative repair of the common, safely-fixable defects, then re-inspects
// and proceeds if the result is clean. What it repairs and refuses:
//
//   REPAIRED (unambiguous, and REPORTED — the user's geometry was changed):
//     * duplicate-vertex welding                        (Phase 1)
//     * normal unification (consistent + outward wind)  (Phase 1)
//     * redundant exact-duplicate triangles removed      (Phase 2) — the #1
//       cause of non-manifold edges in CAD-exported STLs is a stacked, coincident
//       facet; dropping the redundant copy restores 2-manifoldness where the fix
//       is unambiguous (same-oriented facet, so nothing about the solid changes).
//     * small holes capped                               (Phase 2) — a simple
//       boundary loop below a CONSERVATIVE size bound is closed by a centroid fan
//       (topologically guaranteed 2-manifold). Bounds are on loop edge-count and
//       on the loop's geometric span as a fraction of the part.
//
//   REFUSED (structured `PartInspection` -> plain-language sheet, never a crash,
//   never a silent half-import):
//     * holes too large or too complex to fill safely   (OpenBoundary)
//     * ambiguous non-manifold junctions that survive duplicate removal
//       (NonManifoldEdges) — inside/outside is genuinely undefined there
//     * a non-orientable surface (NonOrientable)
//     * a zero-thickness shell (ZeroThickness)
//     * an empty mesh (EmptyMesh)
//
// Repair NEVER silently changes the intended solid: the bounds are conservative,
// every repair is reported, and the result is only accepted after a clean
// re-inspection. Deeper repair — self-intersection resolution, shell
// thickening, remeshing, non-manifold junction cutting — is still NOT attempted.

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
  int removed_duplicate_triangles = 0;  // redundant coincident facets dropped
  int filled_holes = 0;        // simple boundary loops closed by a cap (Phase 2)
  int filled_hole_triangles = 0;  // triangles added by hole caps

  // Measured geometry, in FILE units. The app needs these for the STL unit
  // prompt's size sanity hint (STL carries no unit).
  double volume = 0.0;
  Vec3 bbox_min{0.0, 0.0, 0.0};
  Vec3 bbox_max{0.0, 0.0, 0.0};
};

// Bounds on the automatic mesh repair (Phase 2). Deliberately CONSERVATIVE: a
// hole is only capped when it is unambiguously a small defect, never when it
// could be an intended opening or a whole missing wall. Every bound is a hard
// ceiling — a loop that exceeds ANY of them is left open (and the mesh is then
// refused), never force-filled.
struct MeshRepairOptions {
  // A boundary loop with more than this many edges is not a "small hole"; it is
  // a large opening whose fill would be a guess. 64 comfortably covers a dropped
  // facet or a small crack while refusing a torn-off face of a tessellated part.
  int max_hole_edges = 64;
  // A boundary loop whose bounding-box diagonal exceeds this fraction of the
  // whole mesh's bounding-box diagonal is a wall-sized opening, not a defect.
  // 0.5 refuses e.g. a missing cube face (~0.82 of the diagonal) while filling
  // any genuinely small hole.
  double max_hole_fraction = 0.5;
};

// Import options. `tessellation` applies to STEP only; `segmentation` applies
// to mesh formats only; `repair` applies to mesh formats only.
struct PartOptions {
  StepTessellation tessellation;
  SegmentOptions segmentation;
  MeshRepairOptions repair;
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

// Drop redundant EXACT-DUPLICATE triangles: two triangles that describe the
// same oriented facet (the same three welded vertices in the same cyclic order,
// so the same outward normal). A stacked coincident facet is the most common
// cause of non-manifold edges in a CAD-exported STL, and removing the copy is
// unambiguous — the surface it describes is unchanged. The FIRST occurrence in
// triangle order is kept; every later copy is dropped (deterministic). An
// OPPOSITE-wound coincident pair is NOT a duplicate (it is a doubled-over
// membrane, handled by the zero-thickness verdict) and is left untouched.
// Returns the number of triangles removed; the mesh must already be welded.
int remove_duplicate_triangles(TriangleMesh& mesh);

// Cap small holes: find the mesh's boundary loops (chains of edges used by a
// single triangle) and close each SIMPLE loop that falls within `opts`. "Simple"
// means every vertex on the loop has exactly one incoming and one outgoing
// boundary edge — a pinched or branching boundary is ambiguous and is left open.
// A qualifying loop is filled with a centroid fan (a new centre vertex joined to
// every loop edge), which is topologically guaranteed to close the loop into a
// 2-manifold patch without introducing any new non-manifold edge. Loops that
// exceed a bound, or are not simple, are left OPEN so the mesh is subsequently
// refused rather than force-filled. `out_filled_loops` receives the number of
// loops closed and `out_filled_triangles` the number of triangles added. The
// mesh must already be welded; determinism is by ascending vertex order.
void fill_small_holes(TriangleMesh& mesh, const MeshRepairOptions& opts,
                      int& out_filled_loops, int& out_filled_triangles);

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
