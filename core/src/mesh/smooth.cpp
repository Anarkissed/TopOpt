#include "topopt/smooth.hpp"

#include <cmath>
#include <stdexcept>
#include <vector>

namespace topopt {
namespace {

// Enclosed volume magnitude (mm^3) via the divergence theorem — |signed_volume|,
// so a consistent-winding closed mesh gives its positive enclosed volume.
double enclosed_volume(const TriangleMesh& m) { return std::fabs(signed_volume(m)); }

// The unique 1-ring neighbours of every vertex, from the welded triangle mesh.
// Deterministic (built in triangle then corner order; the umbrella average is
// order-independent anyway).
std::vector<std::vector<int>> build_adjacency(const TriangleMesh& mesh) {
  std::vector<std::vector<int>> adj(mesh.vertices.size());
  auto add = [&](int a, int b) {
    std::vector<int>& na = adj[static_cast<std::size_t>(a)];
    for (const int x : na)
      if (x == b) return;
    na.push_back(b);
  };
  for (const auto& tri : mesh.triangles) {
    add(tri[0], tri[1]);
    add(tri[0], tri[2]);
    add(tri[1], tri[0]);
    add(tri[1], tri[2]);
    add(tri[2], tri[0]);
    add(tri[2], tri[1]);
  }
  return adj;
}

// One umbrella-Laplacian pass with factor `s`: free vertex v moves toward the
// centroid of its 1-ring neighbours' CURRENT positions by s·w[v]; frozen vertices
// are copied verbatim (bit-identical). Reads `pos`, writes `next` (same size).
//
// `w` is either empty (the uniform pre-brush path — every vertex moves by exactly
// `s`, the same arithmetic as before, so results are byte-identical) or one entry
// per vertex, already clamped to [0,1] with frozen entries forced to 0.
//
// A vertex whose weight is 0 takes the SAME verbatim branch as a frozen vertex.
// That is deliberate and not an optimisation: `pos[v].x + 0.0 * lap.x` is NOT
// bit-identical to `pos[v].x` when the coordinate is −0.0 (−0.0 + 0.0 = +0.0),
// and one flipped sign bit is enough to fail the memcmp bar.
void laplacian_pass(const std::vector<Vec3>& pos,
                    const std::vector<std::vector<int>>& adj,
                    const std::vector<char>& frozen,
                    const std::vector<double>& w, double s,
                    std::vector<Vec3>& next) {
  const bool weighted = !w.empty();
  for (std::size_t v = 0; v < pos.size(); ++v) {
    // FROZEN IS TESTED FIRST, unconditionally. No weight the caller supplies can
    // reach a vertex the freeze predicates claimed.
    if (frozen[v] || adj[v].empty() || (weighted && w[v] == 0.0)) {
      next[v] = pos[v];  // frozen / unbrushed / isolated: verbatim
      continue;
    }
    Vec3 sum{0.0, 0.0, 0.0};
    for (const int n : adj[v]) {
      const Vec3& p = pos[static_cast<std::size_t>(n)];
      sum.x += p.x;
      sum.y += p.y;
      sum.z += p.z;
    }
    const double inv = 1.0 / static_cast<double>(adj[v].size());
    const Vec3 lap{sum.x * inv - pos[v].x, sum.y * inv - pos[v].y,
                   sum.z * inv - pos[v].z};
    const double sv = weighted ? s * w[v] : s;
    next[v] = Vec3{pos[v].x + sv * lap.x, pos[v].y + sv * lap.y,
                   pos[v].z + sv * lap.z};
  }
}

// min_feature_violations of `mesh` re-voxelized onto `ref`. Returns -1 if the
// mesh cannot be voxelized (degenerate) — the caller treats that as a violation.
int min_feature_of(const TriangleMesh& mesh, const VoxelGrid& ref) {
  try {
    const VoxelGrid g = voxelize_onto_grid(mesh, ref);
    std::vector<double> density(g.voxel_count(), 0.0);
    for (std::size_t i = 0; i < density.size(); ++i)
      if (g.tags[i] != VoxelTag::Empty) density[i] = 1.0;
    return min_feature_violations(g, density, 0.5);
  } catch (const std::exception&) {
    return -1;
  }
}

}  // namespace

double taubin_mu(double lambda, double k_pb) {
  return -lambda / (1.0 - lambda * k_pb);
}

TaubinParams taubin_params_for_strength(double strength, int max_pairs) {
  TaubinParams p;
  if (strength <= 0.0 || max_pairs <= 0) {
    p.pairs = 0;
    return p;
  }
  const double s = strength < 1.0 ? strength : 1.0;
  p.pairs = static_cast<int>(std::lround(s * static_cast<double>(max_pairs)));
  return p;
}

double taubin_volume_drift_bound(const TaubinParams& params) {
  if (params.pairs <= 0) return 0.0;
  const double mu = taubin_mu(params.lambda, params.k_pb);
  // Pass-band peak A = max_{k in [0,k_PB]} (1−λk)(1−μk) ≥ f(0) = 1. The volume-
  // carrying low-frequency modes are scaled by at most A per pair.
  double peak = 1.0;
  const int kN = 1000;
  for (int m = 0; m <= kN; ++m) {
    const double k = params.k_pb * static_cast<double>(m) / static_cast<double>(kN);
    const double f = (1.0 - params.lambda * k) * (1.0 - mu * k);
    if (f > peak) peak = f;
  }
  return std::pow(peak, static_cast<double>(params.pairs)) - 1.0;
}

double taubin_volume_drift_bound_weighted(const TaubinParams& params,
                                          double max_weight) {
  if (params.pairs <= 0 || max_weight <= 0.0) return 0.0;
  if (max_weight >= 1.0) return taubin_volume_drift_bound(params);
  const double mu = taubin_mu(params.lambda, params.k_pb);
  // The brush scales the pair per vertex, so the amplification a volume-carrying
  // mode can see is the peak of f(k; w) = (1−wλk)(1−wμk) over BOTH k ∈ [0,k_PB]
  // and w ∈ [0, max_weight] — f is not monotone in w (the λμk² term turns over),
  // so the whole rectangle is swept rather than only its w = max corner.
  double peak = 1.0;
  const int kN = 200, wN = 200;
  for (int j = 0; j <= wN; ++j) {
    const double w = max_weight * static_cast<double>(j) / static_cast<double>(wN);
    for (int m = 0; m <= kN; ++m) {
      const double k =
          params.k_pb * static_cast<double>(m) / static_cast<double>(kN);
      const double f = (1.0 - w * params.lambda * k) * (1.0 - w * mu * k);
      if (f > peak) peak = f;
    }
  }
  return std::pow(peak, static_cast<double>(params.pairs)) - 1.0;
}

std::vector<char> compute_freeze_mask(
    const TriangleMesh& mesh, const std::vector<ClearanceGeometry>& regions,
    double tol) {
  std::vector<char> frozen(mesh.vertices.size(), 0);
  for (std::size_t v = 0; v < mesh.vertices.size(); ++v)
    for (const ClearanceGeometry& g : regions)
      if (point_in_clearance_region(g, mesh.vertices[v], tol)) {
        frozen[v] = 1;
        break;
      }
  return frozen;
}

SmoothResult constrained_taubin_smooth(const TriangleMesh& mesh,
                                       const TaubinParams& params,
                                       const SmoothConstraints& constraints) {
  if (mesh.vertices.empty() || mesh.triangles.empty())
    throw std::invalid_argument("constrained_taubin_smooth: empty mesh");

  SmoothResult result;
  result.mesh = mesh;  // topology (triangles) is never changed, only vertex coords

  if (!constraints.vertex_weight.empty() &&
      constraints.vertex_weight.size() != mesh.vertices.size())
    throw std::invalid_argument(
        "constrained_taubin_smooth: vertex_weight size does not match the mesh");

  SmoothStats& st = result.stats;
  st.requested_pairs = params.pairs > 0 ? params.pairs : 0;
  st.total_vertices = mesh.vertices.size();
  st.volume_before_mm3 = enclosed_volume(mesh);
  st.volume_after_mm3 = st.volume_before_mm3;

  // Freeze tolerance: caller value, else 0.75 × the reference grid spacing (so a
  // wall vertex sitting ~half a voxel outside the void is still caught), else 0.
  double tol = constraints.freeze_tol_mm;
  if (tol <= 0.0)
    tol = constraints.min_feature_grid != nullptr
              ? 0.75 * constraints.min_feature_grid->spacing
              : 0.0;

  const std::vector<char> frozen =
      compute_freeze_mask(mesh, constraints.freeze_regions, tol);
  for (const char f : frozen) st.frozen_vertices += (f ? 1u : 0u);

  // THE BRUSH WEIGHTS, sanitized ONCE. Frozen entries are forced to 0 here as
  // well as tested first in the update — the exclusion is structural at both
  // layers, so no caller can smuggle motion into a protected region.
  std::vector<double> weight;
  if (!constraints.vertex_weight.empty()) {
    st.brush_weighted = true;
    weight.assign(mesh.vertices.size(), 0.0);
    for (std::size_t v = 0; v < weight.size(); ++v) {
      double w = constraints.vertex_weight[v];
      if (!(w > 0.0)) w = 0.0;  // also catches NaN
      if (w > 1.0) w = 1.0;
      if (frozen[v]) w = 0.0;
      weight[v] = w;
      if (w > st.max_vertex_weight) st.max_vertex_weight = w;
      if (!frozen[v]) (w > 0.0 ? st.brushed_vertices : st.unbrushed_vertices)++;
    }
  } else {
    st.max_vertex_weight = 1.0;
    st.brushed_vertices = st.total_vertices - st.frozen_vertices;
  }
  st.volume_drift_bound =
      taubin_volume_drift_bound_weighted(params, st.max_vertex_weight);

  // Min-feature baseline (the INPUT mesh's voxelization).
  const bool guard =
      constraints.enforce_min_feature && constraints.min_feature_grid != nullptr;
  if (guard) {
    st.min_feature_evaluated = true;
    st.min_feature_baseline = min_feature_of(mesh, *constraints.min_feature_grid);
    st.min_feature_after = st.min_feature_baseline;
  }

  if (params.pairs <= 0) return result;  // OFF → identity (byte-identical)

  const double mu = taubin_mu(params.lambda, params.k_pb);
  std::vector<std::vector<int>> adj = build_adjacency(mesh);

  std::vector<Vec3> pos = mesh.vertices;
  std::vector<Vec3> tmp(pos.size());
  std::vector<Vec3> next(pos.size());

  for (int p = 0; p < params.pairs; ++p) {
    // One λ|μ pair on a COPY so a min-feature-violating pair can be reverted.
    laplacian_pass(pos, adj, frozen, weight, params.lambda, tmp);
    laplacian_pass(tmp, adj, frozen, weight, mu, next);

    if (guard) {
      result.mesh.vertices = next;  // candidate
      const int viol = min_feature_of(result.mesh, *constraints.min_feature_grid);
      // Reject a pair that raises the count (or breaks voxelization): the melt is
      // structurally impossible. Revert to the last good positions and stop.
      if (viol < 0 ||
          (st.min_feature_baseline >= 0 && viol > st.min_feature_baseline)) {
        result.mesh.vertices = pos;  // last accepted state
        st.min_feature_limited = true;
        break;
      }
      st.min_feature_after = viol;
    }

    pos.swap(next);
    ++st.applied_pairs;
  }

  result.mesh.vertices = pos;
  st.volume_after_mm3 = enclosed_volume(result.mesh);
  st.volume_drift_fraction =
      st.volume_before_mm3 > 0.0
          ? std::fabs(st.volume_after_mm3 - st.volume_before_mm3) /
                st.volume_before_mm3
          : 0.0;
  return result;
}

}  // namespace topopt
