// part.cpp — the one part-import adapter (handoff 134). See part.hpp.
//
// Always compiled. The STEP and 3MF branches are guarded by the same
// TOPOPT_HAVE_OCCT / TOPOPT_HAVE_3MF definitions the CMake dependency probes
// set, so this file builds on a dependency-free slice and simply reports those
// formats as unavailable there.

#include "topopt/part.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <deque>
#include <map>
#include <tuple>
#include <utility>

#include "topopt/stl.hpp"
#ifdef TOPOPT_HAVE_3MF
#include "topopt/threemf.hpp"
#endif

namespace topopt {
namespace {

bool has_suffix_ci(const std::string& s, const std::string& suffix) {
  if (s.size() < suffix.size()) return false;
  for (std::size_t i = 0; i < suffix.size(); ++i) {
    const unsigned char a =
        static_cast<unsigned char>(s[s.size() - suffix.size() + i]);
    const unsigned char b = static_cast<unsigned char>(suffix[i]);
    if (std::tolower(a) != std::tolower(b)) return false;
  }
  return true;
}

// Read the raw triangles of a mesh-format file. STEP is handled separately.
TriangleMesh read_mesh_any(const std::string& path, PartFormat format) {
  if (format == PartFormat::ThreeMf) {
#ifdef TOPOPT_HAVE_3MF
    return read_3mf_file(path);
#else
    throw PartError(
        "3MF import requires lib3mf, which is not available in this build; "
        "export the part as STL and import that instead");
#endif
  }
  // Stl and Unknown: the STL reader (ASCII/binary auto-detected). It welds by
  // exact coordinate, which is also the first of our two repairs.
  try {
    return read_stl_file(path).mesh;
  } catch (const StlError& e) {
    throw PartError(e.what());
  }
}

}  // namespace

// Repair `mesh` in place (weld + normal unification) and return the structural
// verdict. This is the SINGLE definition of "is this mesh usable" — both
// `import_part` (which refuses by throwing) and `inspect_part_file` (which
// reports) run exactly this, so the sheet can never disagree with the refusal.
static PartInspection inspect_and_repair(TriangleMesh& mesh) {
  PartInspection insp;
  insp.checked = true;

  // Repair 1: duplicate-vertex weld + degenerate-triangle removal. The STL
  // reader has already welded; 3MF has not, and a weld is required before the
  // shared-edge topology below means anything.
  mesh = weld_and_clean(mesh, insp.welded_vertices, insp.degenerate_triangles);
  bounding_box(mesh, insp.bbox_min, insp.bbox_max);

  if (mesh.triangles.empty()) {
    insp.defects.push_back(PartDefect::EmptyMesh);
    return insp;
  }

  // Structural verdict. Phase 1 handles clean manifold meshes only; both of
  // these are refusals, not repairs.
  const WatertightReport wt = check_watertight(mesh);
  insp.boundary_edges = wt.boundary_edges;
  insp.non_manifold_edges = wt.non_manifold_edges;
  if (wt.non_manifold_edges > 0)
    insp.defects.push_back(PartDefect::NonManifoldEdges);
  if (wt.boundary_edges > 0) insp.defects.push_back(PartDefect::OpenBoundary);

  // Repair 2: normal unification. Only meaningful on a manifold surface, so it
  // runs after the topology verdict; its failure is its own defect.
  if (insp.defects.empty() && !unify_normals(mesh, insp.flipped_triangles))
    insp.defects.push_back(PartDefect::NonOrientable);

  if (insp.defects.empty()) {
    insp.volume = signed_volume(mesh);
    const double box = (insp.bbox_max.x - insp.bbox_min.x) *
                       (insp.bbox_max.y - insp.bbox_min.y) *
                       (insp.bbox_max.z - insp.bbox_min.z);
    // A closed, outward-wound solid fills a non-trivial fraction of its own
    // bounding box. A doubled-over surface patch closes topologically but
    // encloses essentially nothing; 1e-6 of the box is far below any real part
    // (a thin-walled 1 mm shell in a 100 mm box is still ~1e-2).
    if (!(box > 0.0) || insp.volume <= 1e-6 * box)
      insp.defects.push_back(PartDefect::ZeroThickness);
  }

  insp.acceptable = insp.defects.empty();
  return insp;
}

PartFormat part_format_for_path(const std::string& path) {
  if (has_suffix_ci(path, ".step") || has_suffix_ci(path, ".stp"))
    return PartFormat::Step;
  if (has_suffix_ci(path, ".stl")) return PartFormat::Stl;
  if (has_suffix_ci(path, ".3mf")) return PartFormat::ThreeMf;
  return PartFormat::Unknown;
}

std::string describe_defect(PartDefect defect) {
  switch (defect) {
    case PartDefect::EmptyMesh:
      return "the file contains no triangles";
    case PartDefect::NonManifoldEdges:
      return "the mesh has non-manifold edges (an edge shared by more than two "
             "triangles)";
    case PartDefect::OpenBoundary:
      return "the mesh is open (it has boundary edges, so it is not a closed "
             "solid)";
    case PartDefect::NonOrientable:
      return "the mesh cannot be consistently oriented (its normals contradict "
             "each other)";
    case PartDefect::ZeroThickness:
      return "the mesh encloses no volume (a zero-thickness shell)";
  }
  return "the mesh is unusable";
}

TriangleMesh weld_and_clean(const TriangleMesh& mesh, int& out_welded,
                            int& out_degenerate) {
  out_welded = 0;
  out_degenerate = 0;

  // Exact-coordinate weld through an ORDERED map: same rule as the STL reader
  // (no epsilon — an epsilon weld can collapse genuinely distinct thin
  // features), and no hash iteration order, so vertex numbering is a pure
  // function of the input triangle list.
  TriangleMesh out;
  std::map<std::tuple<double, double, double>, int> index;
  std::vector<int> remap(mesh.vertices.size(), -1);
  for (std::size_t i = 0; i < mesh.vertices.size(); ++i) {
    const Vec3& v = mesh.vertices[i];
    const auto key = std::make_tuple(v.x, v.y, v.z);
    const auto it = index.find(key);
    if (it != index.end()) {
      remap[i] = it->second;
      ++out_welded;
    } else {
      const int idx = static_cast<int>(out.vertices.size());
      out.vertices.push_back(v);
      index.emplace(key, idx);
      remap[i] = idx;
    }
  }

  for (const auto& tri : mesh.triangles) {
    bool bad = false;
    int r[3] = {0, 0, 0};
    for (int k = 0; k < 3; ++k) {
      const int v = tri[k];
      if (v < 0 || static_cast<std::size_t>(v) >= remap.size()) {
        bad = true;
        break;
      }
      r[k] = remap[static_cast<std::size_t>(v)];
    }
    if (bad || r[0] == r[1] || r[1] == r[2] || r[0] == r[2]) {
      ++out_degenerate;
      continue;
    }
    // Zero-area (collinear) triangles have no normal and no contribution to
    // the enclosed volume; they only confuse the segmenter.
    const Vec3& p0 = out.vertices[static_cast<std::size_t>(r[0])];
    const Vec3& p1 = out.vertices[static_cast<std::size_t>(r[1])];
    const Vec3& p2 = out.vertices[static_cast<std::size_t>(r[2])];
    const double ax = p1.x - p0.x, ay = p1.y - p0.y, az = p1.z - p0.z;
    const double bx = p2.x - p0.x, by = p2.y - p0.y, bz = p2.z - p0.z;
    const double cx = ay * bz - az * by;
    const double cy = az * bx - ax * bz;
    const double cz = ax * by - ay * bx;
    if (cx * cx + cy * cy + cz * cz <= 0.0) {
      ++out_degenerate;
      continue;
    }
    out.triangles.push_back({r[0], r[1], r[2]});
  }

  // Vertices left unreferenced by the dropped triangles are harmless (the
  // voxelizer and the segmenter both iterate triangles), so they are kept
  // rather than re-indexed — re-indexing would change vertex ids for no gain.
  return out;
}

bool unify_normals(TriangleMesh& mesh, int& out_flipped) {
  out_flipped = 0;
  const std::size_t nt = mesh.triangles.size();
  if (nt == 0) return true;

  // Edge -> incident triangles, ordered map for determinism.
  std::map<std::pair<int, int>, std::vector<int>> edge_tris;
  for (std::size_t t = 0; t < nt; ++t) {
    const auto& tri = mesh.triangles[t];
    for (int e = 0; e < 3; ++e) {
      int a = tri[e], b = tri[(e + 1) % 3];
      if (a > b) std::swap(a, b);
      edge_tris[std::make_pair(a, b)].push_back(static_cast<int>(t));
    }
  }

  // Propagate orientation across shared edges. Two triangles sharing an edge
  // are consistently wound iff they traverse that edge in OPPOSITE directions.
  // `flip[t]` records whether triangle t must be reversed to agree with its
  // component's seed; a contradiction means the surface is non-orientable.
  std::vector<signed char> state(nt, -1);  // -1 unvisited, 0 keep, 1 flip
  std::deque<int> frontier;

  auto directed_edge = [&](std::size_t t, int e, bool flipped) {
    const auto& tri = mesh.triangles[t];
    int a = tri[e], b = tri[(e + 1) % 3];
    if (flipped) std::swap(a, b);
    return std::make_pair(a, b);
  };

  for (std::size_t seed = 0; seed < nt; ++seed) {
    if (state[seed] != -1) continue;
    state[seed] = 0;
    frontier.clear();
    frontier.push_back(static_cast<int>(seed));
    while (!frontier.empty()) {
      const int cur = frontier.front();
      frontier.pop_front();
      const std::size_t c = static_cast<std::size_t>(cur);
      const bool c_flipped = state[c] == 1;
      const auto& tri = mesh.triangles[c];
      for (int e = 0; e < 3; ++e) {
        int a = tri[e], b = tri[(e + 1) % 3];
        if (a > b) std::swap(a, b);
        const auto it = edge_tris.find(std::make_pair(a, b));
        if (it == edge_tris.end()) continue;
        const auto cur_dir = directed_edge(c, e, c_flipped);
        for (const int nb : it->second) {
          if (nb == cur) continue;
          const std::size_t n = static_cast<std::size_t>(nb);
          // Find how the neighbour traverses this same undirected edge.
          const auto& ntri = mesh.triangles[n];
          int ne = -1;
          for (int k = 0; k < 3; ++k) {
            int x = ntri[k], y = ntri[(k + 1) % 3];
            if (x > y) std::swap(x, y);
            if (x == a && y == b) {
              ne = k;
              break;
            }
          }
          if (ne < 0) continue;
          const auto nb_kept = directed_edge(n, ne, false);
          // Consistent when the neighbour traverses the edge the other way.
          const bool needs_flip = (nb_kept == cur_dir);
          const signed char want = needs_flip ? 1 : 0;
          if (state[n] == -1) {
            state[n] = want;
            frontier.push_back(nb);
          } else if (state[n] != want) {
            return false;  // contradiction: non-orientable
          }
        }
      }
    }
  }

  TriangleMesh oriented = mesh;
  for (std::size_t t = 0; t < nt; ++t) {
    if (state[t] == 1) {
      std::swap(oriented.triangles[t][1], oriented.triangles[t][2]);
      ++out_flipped;
    }
  }

  // A consistently-wound closed surface is either all-outward or all-inward;
  // the sign of the enclosed volume says which. Flip the whole mesh if inward.
  if (signed_volume(oriented) < 0.0) {
    for (std::size_t t = 0; t < nt; ++t)
      std::swap(oriented.triangles[t][1], oriented.triangles[t][2]);
    // Every triangle's winding relative to the input changed, so recount.
    out_flipped = static_cast<int>(nt) - out_flipped;
  }

  mesh = std::move(oriented);
  return true;
}

PartModel import_part(const std::string& path, const PartOptions& opts) {
  PartModel out;
  out.format = part_format_for_path(path);

  if (out.format == PartFormat::Step) {
#ifdef TOPOPT_HAVE_OCCT
    // UNCHANGED PATH. A STEP file gets the identical import it always got: no
    // inspection, no repair, no segmentation. Real B-rep faces are already the
    // contract; touching this path would risk regressing every existing
    // project for no benefit.
    out.model = import_step_file(path, opts.tessellation);
    out.pseudo_faces = false;
    out.inspection.checked = false;
    out.inspection.acceptable = true;
    return out;
#else
    throw PartError(
        "STEP import requires OpenCASCADE, which is not available in this "
        "build; import an STL or 3MF instead");
#endif
  }

  // --- mesh formats ---------------------------------------------------------
  TriangleMesh mesh = read_mesh_any(path, out.format);
  out.inspection = inspect_and_repair(mesh);
  const PartInspection& insp = out.inspection;

  if (!insp.acceptable) {
    std::string msg = "cannot import '" + path + "': ";
    for (std::size_t i = 0; i < insp.defects.size(); ++i) {
      if (i) msg += "; ";
      msg += describe_defect(insp.defects[i]);
    }
    throw PartError(msg);
  }

  // --- manufacture the faces ------------------------------------------------
  const MeshSegmentation seg = segment_mesh_faces(mesh, opts.segmentation);
  out.model.mesh = std::move(mesh);
  out.model.triangle_face = seg.triangle_face;
  out.model.face_count = seg.face_count;
  out.model.faces = seg.faces;
  out.model.solid_count = 1;
  // `brep_volume` is the EXACT solid volume for a STEP part. A mesh has no
  // exact form, so the mesh's own enclosed volume IS the exact answer for the
  // geometry the user supplied — it is not an approximation of something else.
  out.model.brep_volume = insp.volume;
  out.pseudo_faces = true;
  return out;
}

StepModel import_part_file(const std::string& path, const StepTessellation& tess) {
  PartOptions opts;
  opts.tessellation = tess;
  return import_part(path, opts).model;
}

PartInspection inspect_part_file(const std::string& path) {
  const PartFormat fmt = part_format_for_path(path);
  if (fmt == PartFormat::Step) {
    PartInspection insp;
    insp.checked = false;
    insp.acceptable = true;
    return insp;
  }
  // Reads and repairs, but reports the verdict instead of throwing on it. A
  // file that cannot be READ still throws — there is nothing to inspect.
  TriangleMesh mesh = read_mesh_any(path, fmt);
  return inspect_and_repair(mesh);
}

void rescale_part_file(const std::string& in_path, const std::string& out_path,
                       double scale) {
  if (!(scale > 0.0))
    throw PartError("rescale_part_file: scale must be positive");
  const PartFormat fmt = part_format_for_path(in_path);
  if (fmt == PartFormat::Step)
    throw PartError(
        "rescale_part_file: STEP carries its own unit and is never rescaled");
  TriangleMesh mesh = read_mesh_any(in_path, fmt);
  for (Vec3& v : mesh.vertices) {
    v.x *= scale;
    v.y *= scale;
    v.z *= scale;
  }
  try {
    write_stl_file(out_path, mesh, StlFormat::Binary);
  } catch (const StlError& e) {
    throw PartError(e.what());
  }
}

}  // namespace topopt
