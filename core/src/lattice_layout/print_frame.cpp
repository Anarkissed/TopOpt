// THE PRINT FRAME: "rotate at the door" (topopt/print_frame.hpp; his print orientation 2026-11-23, spec 2c, P2).
#include "topopt/print_frame.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <limits>

#include "topopt/job.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

unsigned g_print_frame_test_skip = 0;

namespace {

// -x, written so a 0 stays +0 (a turned file never holds "-0").
inline double neg(double x) { return 0.0 - x; }
inline double signed_of(int s, double x) { return s > 0 ? x : neg(x); }
inline double at(const Vec3& v, int a) { return a == 0 ? v.x : a == 1 ? v.y : v.z; }
inline void set(Vec3& v, int a, double x) { (a == 0 ? v.x : a == 1 ? v.y : v.z) = x; }

// Voigt index of (i, j): xx yy zz xy yz zx.
int voigt(int i, int j) {
  if (i == j) return i;
  const int a = std::min(i, j), b = std::max(i, j);
  return a == 0 && b == 1 ? 3 : a == 1 && b == 2 ? 4 : 5;
}

std::string num(double v) {
  if (!std::isfinite(v)) return "null";
  char b[40];
  std::snprintf(b, sizeof b, "%.10g", v);
  return b;
}

}  // namespace

Vec3 PrintFrame::point_to_print(const Vec3& p) const {
  if (!on) return p;
  Vec3 q;
  for (int a = 0; a < 3; ++a) set(q, a, signed_of(sign[a], at(p, perm[a])) + at(t, a));
  return q;
}
Vec3 PrintFrame::dir_to_print(const Vec3& d) const {
  if (!on) return d;
  Vec3 q;
  for (int a = 0; a < 3; ++a) set(q, a, signed_of(sign[a], at(d, perm[a])));
  return q;
}
Vec3 PrintFrame::point_to_model(const Vec3& q) const {
  if (!on) return q;
  Vec3 p;
  for (int a = 0; a < 3; ++a) set(p, perm[a], signed_of(sign[a], at(q, a) - at(t, a)));
  return p;
}
Vec3 PrintFrame::dir_to_model(const Vec3& d) const {
  if (!on) return d;
  Vec3 p;
  for (int a = 0; a < 3; ++a) set(p, perm[a], signed_of(sign[a], at(d, a)));
  return p;
}
void PrintFrame::tensor_to_print(const double* in, double* out) const {
  if (!on) {
    for (int q = 0; q < 6; ++q) out[q] = in[q];
    return;
  }
  for (int a = 0; a < 3; ++a)
    for (int b = a; b < 3; ++b) {
      const double v = in[voigt(perm[a], perm[b])];
      out[voigt(a, b)] = sign[a] * sign[b] > 0 ? v : neg(v);
    }
}
std::array<double, 9> PrintFrame::rotation_row_major() const {
  std::array<double, 9> r{1, 0, 0, 0, 1, 0, 0, 0, 1};
  if (!on) return r;
  r.fill(0.0);
  for (int a = 0; a < 3; ++a) r[static_cast<std::size_t>(3 * a + perm[a])] = sign[a];
  return r;
}
void PrintFrame::box_to_print(Vec3& lo, Vec3& hi) const {
  if (!on) return;
  const Vec3 a = point_to_print(lo), b = point_to_print(hi);
  lo = {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)};
  hi = {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)};
}
void PrintFrame::box_to_model(Vec3& lo, Vec3& hi) const {
  if (!on) return;
  const Vec3 a = point_to_model(lo), b = point_to_model(hi);
  lo = {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)};
  hi = {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)};
}
void PrintFrame::axis_six_to_model(const double in[6], double out[6]) const {
  if (!on) {
    for (int q = 0; q < 6; ++q) out[q] = in[q];
    return;
  }
  // Print axis a, side s (0 = -, 1 = +) is model axis perm[a], its side flipped when sign[a] < 0.
  for (int a = 0; a < 3; ++a)
    for (int s = 0; s < 2; ++s) out[2 * perm[a] + (sign[a] > 0 ? s : 1 - s)] = in[2 * a + s];
}

bool print_frame_for_up(const Vec3& up, PrintFrame& out, std::string* why) {
  const double l = std::sqrt(up.x * up.x + up.y * up.y + up.z * up.z);
  if (!std::isfinite(l) || !(l > 0.0)) {
    if (why) *why = "the print frame's up must be a direction (three numbers, not all 0)";
    return false;
  }
  const Vec3 u{up.x / l, up.y / l, up.z / l};
  int axis = -1, s = 0;
  for (int a = 0; a < 3; ++a)
    if (std::fabs(std::fabs(at(u, a)) - 1.0) <= 1e-6) {
      axis = a;
      s = at(u, a) > 0.0 ? 1 : -1;
    }
  if (axis < 0) {
    if (why)
      *why = "the print frame's up must lie along one of the part's six axes for now (a sloped face comes later)";
    return false;
  }
  PrintFrame f;
  f.on = true;
  f.up = {0.0, 0.0, 0.0};
  set(f.up, axis, static_cast<double>(s));
  // print[a] = sign[a] * model[perm[a]]: the shortest turn taking `up` to +Z (a half turn about X for -Z).
  static const int kPerm[3][3] = {{2, 1, 0}, {0, 2, 1}, {0, 1, 2}};   // up along x, y, z
  static const int kSignPlus[3][3] = {{-1, 1, 1}, {1, -1, 1}, {1, 1, 1}};
  static const int kSignMinus[3][3] = {{1, 1, -1}, {1, 1, -1}, {1, -1, -1}};
  for (int a = 0; a < 3; ++a) {
    f.perm[a] = kPerm[axis][a];
    f.sign[a] = s > 0 ? kSignPlus[axis][a] : kSignMinus[axis][a];
  }
  out = f;
  return true;
}

void print_frame_set_base(PrintFrame& f, const TriangleMesh& m) {
  f.t = {0.0, 0.0, 0.0};
  if (!f.on || m.vertices.empty()) return;
  double lo = std::numeric_limits<double>::infinity();
  for (const Vec3& v : m.vertices) lo = std::min(lo, f.dir_to_print(v).z);
  f.t.z = neg(lo);
}

void turn_mesh(const PrintFrame& f, TriangleMesh& m) {
  if (!f.on) return;
  for (Vec3& v : m.vertices) v = f.point_to_print(v);
}

void turn_step_model(const PrintFrame& f, StepModel& m) {
  if (!f.on) return;
  turn_mesh(f, m.mesh);
  for (StepFaceInfo& x : m.faces) {
    x.axis_point = f.point_to_print(x.axis_point);
    x.axis_dir = f.dir_to_print(x.axis_dir);
    x.plane_normal = f.dir_to_print(x.plane_normal);
    x.plane_origin = f.point_to_print(x.plane_origin);
  }
}

void turn_keep_region(const PrintFrame& f, KeepRegion& k) {
  if (!f.on) return;
  f.box_to_print(k.min, k.max);
  // An axis-aligned cylinder's axis index follows the permutation: model axis perm[a] is print axis a.
  for (int a = 0; a < 3; ++a)
    if (f.perm[a] == k.axis) {
      k.axis = a;
      break;
    }
  k.center = f.point_to_print(k.center);
  for (Vec3& ax : k.axes) ax = f.dir_to_print(ax);
  // `half` is in the region's own axes: unchanged.
}

namespace {
void turn_lattice_region(const PrintFrame& f, JobLatticeRegion& r) {
  r.axis_point = f.point_to_print(r.axis_point);
  r.axis_dir = f.dir_to_print(r.axis_dir);
  r.origin = f.point_to_print(r.origin);
  r.normal = f.dir_to_print(r.normal);
  r.frame_u = f.dir_to_print(r.frame_u);
  r.frame_w = f.dir_to_print(r.frame_w);
  if (r.slot_origin_stated) r.slot_origin_mm = f.point_to_print(r.slot_origin_mm);
  // outline_uv is in (frame_u, frame_w): unchanged.
}
void turn_groups(const PrintFrame& f, std::vector<JobLoadGroup>& gs) {
  for (JobLoadGroup& g : gs) g.force = f.dir_to_print(g.force);
}
}  // namespace

void turn_job_description(const PrintFrame& f, JobDescription& job) {
  if (!f.on) return;
  job.gravity.direction = f.dir_to_print(job.gravity.direction);
  // The BUILD direction is the print frame's up; the service (loads.build_dir) is the part's, turned with it.
  job.has_build_direction = true;
  job.build_direction = {0.0, 0.0, 1.0};
  job.orientation_recheck_dir = f.dir_to_print(job.orientation_recheck_dir);
  JobLoadCase& L = job.loads;
  for (FaceRegionSpec& r : L.face_regions)
    for (RegionCut& c : r.cuts) {
      c.point = f.point_to_print(c.point);
      c.normal = f.dir_to_print(c.normal);
    }
  turn_groups(f, L.groups);
  for (JobScenario& s : L.scenarios) turn_groups(f, s.groups);
  for (JobClearance& c : L.clearances) {
    c.axis_point = f.point_to_print(c.axis_point);
    c.axis_dir = f.dir_to_print(c.axis_dir);
    c.origin = f.point_to_print(c.origin);
    c.normal = f.dir_to_print(c.normal);
  }
  L.build_dir = f.dir_to_print(L.build_dir);
  f.box_to_print(job.design_box.min, job.design_box.max);
  for (JobBox& b : job.keep_out_boxes) f.box_to_print(b.min, b.max);
  for (KeepRegion& k : job.keep_regions) turn_keep_region(f, k);
  for (JobLatticeRegion& r : job.lattice.regions) turn_lattice_region(f, r);
  for (JobLatticeRegion& r : job.lattice.whole_part_includes) turn_lattice_region(f, r);
  // A stepped cell is an axis-aligned cube: its low corner is the turned cube's low corner.
  for (SteppedCell& c : job.lattice.stepped_cells) {
    Vec3 lo = c.origin, hi{c.origin.x + c.size_mm, c.origin.y + c.size_mm, c.origin.z + c.size_mm};
    f.box_to_print(lo, hi);
    c.origin = lo;
  }
}

namespace {
// Per print axis a: the model axis it reads and whether it is reversed; the turned grid's dims and origin.
template <class T>
std::vector<T> turn_grid_impl(const PrintFrame& f, bool to_print, const int n[3], Vec3 origin, double h,
                              const std::vector<T>& values, int kind, int n_out[3], Vec3& origin_out) {
  const int comp = kind == 0 ? 1 : kind;
  // `src` axis of output axis o, and its sign: to the print frame, output a reads model perm[a]; back, output
  // perm[a] reads print a.
  int src[3], sg[3];
  for (int a = 0; a < 3; ++a) {
    if (to_print) {
      src[a] = f.perm[a];
      sg[a] = f.sign[a];
    } else {
      src[f.perm[a]] = a;
      sg[f.perm[a]] = f.sign[a];
    }
  }
  for (int o = 0; o < 3; ++o) n_out[o] = n[src[o]];
  // The low corner: along a kept axis the source's low corner, along a reversed one minus the source's high corner;
  // then the translation (to the print frame: + t; back: - t first).
  for (int o = 0; o < 3; ++o) {
    const int s = src[o];
    const double lo = at(origin, s) - (to_print ? 0.0 : at(f.t, s));
    const double hi = lo + h * n[s];
    double v = sg[o] > 0 ? lo : neg(hi);
    if (to_print) v += at(f.t, o);
    set(origin_out, o, v);
  }
  const std::size_t nv = static_cast<std::size_t>(n[0]) * static_cast<std::size_t>(n[1]) * static_cast<std::size_t>(n[2]);
  std::vector<T> out(values.size());
  if (values.size() != nv * static_cast<std::size_t>(comp)) return out;
  int idx_in[3];
  for (int k = 0; k < n_out[2]; ++k)
    for (int j = 0; j < n_out[1]; ++j)
      for (int i = 0; i < n_out[0]; ++i) {
        const int io[3] = {i, j, k};
        for (int o = 0; o < 3; ++o) idx_in[src[o]] = sg[o] > 0 ? io[o] : n[src[o]] - 1 - io[o];
        const std::size_t ein = (static_cast<std::size_t>(idx_in[2]) * static_cast<std::size_t>(n[1]) +
                                 static_cast<std::size_t>(idx_in[1])) * static_cast<std::size_t>(n[0]) +
                                static_cast<std::size_t>(idx_in[0]);
        const std::size_t eout = (static_cast<std::size_t>(k) * static_cast<std::size_t>(n_out[1]) +
                                  static_cast<std::size_t>(j)) * static_cast<std::size_t>(n_out[0]) +
                                 static_cast<std::size_t>(i);
        const T* vi = &values[ein * static_cast<std::size_t>(comp)];
        T* vo = &out[eout * static_cast<std::size_t>(comp)];
        if (kind == 0) {
          vo[0] = vi[0];
        } else if (kind == 3) {
          for (int o = 0; o < 3; ++o) vo[o] = sg[o] > 0 ? vi[src[o]] : static_cast<T>(T(0) - vi[src[o]]);
        } else {
          for (int a = 0; a < 3; ++a)
            for (int b = a; b < 3; ++b) {
              const T v = vi[voigt(src[a], src[b])];
              vo[voigt(a, b)] = sg[a] * sg[b] > 0 ? v : static_cast<T>(T(0) - v);
            }
        }
      }
  return out;
}
}  // namespace

std::vector<double> turn_grid_values(const PrintFrame& f, bool to_print, const int n[3], Vec3 origin, double spacing,
                                     const std::vector<double>& values, int kind, int n_out[3], Vec3& origin_out) {
  return turn_grid_impl<double>(f, to_print, n, origin, spacing, values, kind, n_out, origin_out);
}
std::vector<float> turn_grid_values_f(const PrintFrame& f, bool to_print, const int n[3], Vec3 origin, double spacing,
                                      const std::vector<float>& values, int kind, int n_out[3], Vec3& origin_out) {
  return turn_grid_impl<float>(f, to_print, n, origin, spacing, values, kind, n_out, origin_out);
}
std::vector<float> turn_node_vectors_f(const PrintFrame& f, bool to_print, const int n[3],
                                       const std::vector<float>& values) {
  const int nn[3] = {n[0] + 1, n[1] + 1, n[2] + 1};
  int nout[3];
  Vec3 o;
  return turn_grid_impl<float>(f, to_print, nn, Vec3{}, 1.0, values, 3, nout, o);
}

bool turn_fields_file_to_model(const PrintFrame& f, const std::string& path, std::string* why) {
  if (!f.on) return true;
  std::vector<unsigned char> b;
  {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
      if (why) *why = "cannot open " + path;
      return false;
    }
    b.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
  }
  const auto rd = [&](std::size_t at_, void* p, std::size_t n) {
    if (at_ + n > b.size()) return false;
    std::memcpy(p, b.data() + at_, n);
    return true;
  };
  const auto wr = [&](std::size_t at_, const void* p, std::size_t n) { std::memcpy(b.data() + at_, p, n); };
  if (b.size() < 64 || b[0] != 1) {
    if (why) *why = "not a fields.bin v1 container";
    return false;
  }
  std::int32_t dims[3];
  double org[3], h = 0.0;
  rd(4, dims, sizeof dims);
  rd(16, org, sizeof org);
  rd(40, &h, sizeof h);
  std::int32_t count = 0;
  rd(56, &count, sizeof count);
  const int n[3] = {dims[0], dims[1], dims[2]};
  const std::size_t nv = static_cast<std::size_t>(n[0]) * static_cast<std::size_t>(n[1]) * static_cast<std::size_t>(n[2]);
  const std::size_t nn = static_cast<std::size_t>(n[0] + 1) * static_cast<std::size_t>(n[1] + 1) * static_cast<std::size_t>(n[2] + 1);
  int nout[3];
  Vec3 oout;
  {
    std::vector<float> none;
    (void)turn_grid_values_f(f, false, n, Vec3{org[0], org[1], org[2]}, h, none, 0, nout, oout);
  }
  std::size_t p = 64;
  for (std::int32_t v = 0; v < count; ++v) {
    std::int64_t c_vm = 0, c_t = 0, c_d = 0;
    if (!rd(p + 24, &c_vm, 8) || !rd(p + 32, &c_t, 8) || !rd(p + 40, &c_d, 8)) {
      if (why) *why = "a block is cut short";
      return false;
    }
    p += 48;
    const auto block = [&](std::int64_t cnt, int kind, bool nodes) {
      if (cnt == 0) return true;
      const std::size_t want = nodes ? 3 * nn : (kind == 0 ? nv : static_cast<std::size_t>(kind) * nv);
      if (static_cast<std::size_t>(cnt) != want || p + static_cast<std::size_t>(cnt) * 4 > b.size()) return false;
      std::vector<float> vals(static_cast<std::size_t>(cnt));
      rd(p, vals.data(), vals.size() * 4);
      int no[3];
      Vec3 oo;
      const std::vector<float> t = nodes ? turn_node_vectors_f(f, false, n, vals)
                                         : turn_grid_values_f(f, false, n, Vec3{}, 1.0, vals, kind, no, oo);
      wr(p, t.data(), t.size() * 4);
      p += vals.size() * 4;
      return true;
    };
    if (!block(c_vm, 0, false) || !block(c_t, 6, false) || !block(c_d, 3, true)) {
      if (why) *why = "a block's size is not its grid's";
      return false;
    }
  }
  const std::int32_t d2[3] = {nout[0], nout[1], nout[2]};
  const double o2[3] = {oout.x, oout.y, oout.z};
  wr(4, d2, sizeof d2);
  wr(16, o2, sizeof o2);
  const std::string tmp = path + ".part";
  {
    std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
    out.write(reinterpret_cast<const char*>(b.data()), static_cast<std::streamsize>(b.size()));
    if (!out) {
      if (why) *why = "cannot write " + tmp;
      return false;
    }
  }
  if (std::rename(tmp.c_str(), path.c_str()) != 0) {
    std::remove(tmp.c_str());
    if (why) *why = "cannot replace " + path;
    return false;
  }
  return true;
}

std::string print_frame_json(const PrintFrame& f) {
  const std::array<double, 9> r = f.rotation_row_major();
  std::string s = "{\"up\": [" + num(f.up.x) + ", " + num(f.up.y) + ", " + num(f.up.z) + "], \"rotation_row_major\": [";
  for (std::size_t i = 0; i < 9; ++i) s += (i ? ", " : "") + num(r[i]);
  s += "], \"translation_mm\": [" + num(f.t.x) + ", " + num(f.t.y) + ", " + num(f.t.z) + "]}";
  return s;
}

}  // namespace topopt

namespace topopt::lattice_layout {

namespace {
void turn_cuts(const PrintFrame& f, std::vector<FacePiece>& pieces) {
  for (FacePiece& p : pieces)
    for (FaceCut& c : p.cuts) {
      c.point = f.point_to_print(c.point);
      c.normal = f.dir_to_print(c.normal);
    }
}
std::shared_ptr<const DemandField> turned(const PrintFrame& f, const std::shared_ptr<const DemandField>& d) {
  if (!d || d->empty()) return d;
  auto out = std::make_shared<DemandField>(*d);
  const int n[3] = {d->nx, d->ny, d->nz};
  int no[3];
  out->mpa = turn_grid_values_f(f, true, n, d->origin, d->spacing, d->mpa, 0, no, out->origin);
  out->nx = no[0];
  out->ny = no[1];
  out->nz = no[2];
  return out;
}
void back(const PrintFrame& f, std::vector<Vec3>& v) {
  for (Vec3& p : v) p = f.point_to_model(p);
}
}  // namespace

void turn_layout_inputs(const PrintFrame& f, Settings& settings, std::shared_ptr<const TensorField>& tensor) {
  if (!f.on) return;
  const unsigned skip = g_print_frame_test_skip;
  if (!(skip & kSkipZones)) {
    for (Settings::RegionAsk& a : settings.regions) {
      if (a.zone.kind != Zone::Kind::None) {
        a.zone.centre = f.point_to_print(a.zone.centre);
        for (Vec3& ax : a.zone.axis) ax = f.dir_to_print(ax);
      }
      turn_cuts(f, a.pieces);
    }
    for (Settings::ProtectAsk& a : settings.protect) turn_cuts(f, a.pieces);
  }
  settings.stress.demand = turned(f, settings.stress.demand);
  settings.struts.demand = turned(f, settings.struts.demand);
  settings.cells.demand = turned(f, settings.cells.demand);
  if (tensor && !tensor->empty() && !(skip & kSkipTensor)) {
    const TensorField& t = *tensor;
    auto out = std::make_shared<TensorField>(t);
    const int n[3] = {t.nx, t.ny, t.nz};
    int no[3];
    out->voigt = turn_grid_values(f, true, n, t.origin, t.spacing, t.voigt, 6, no, out->origin);
    out->nx = no[0];
    out->ny = no[1];
    out->nz = no[2];
    tensor = std::move(out);
  }
  if (settings.bed_floor_mm > 0.0) settings.bed_up = {0.0, 0.0, 1.0};
}

void turn_file_job_inputs(const PrintFrame& f, FileJob& job) {
  if (!f.on) return;
  turn_layout_inputs(f, job.settings, job.tensor_field);
  // Up IS +Z inside the door: the grower, the floor and the bed read the print frame's own up (the job never states
  // another: "build_dir" is not a job key).
  job.organic.build_dir = {0.0, 0.0, 1.0};
  for (OrganicGroup& g : job.organic_groups) g.ask.build_dir = {0.0, 0.0, 1.0};
}

void turn_result_to_model(const PrintFrame& f, FileResult& r) {
  if (!f.on || (g_print_frame_test_skip & kSkipReportBack)) return;
  back(f, r.made.shells.sweep_tight_at);
  back(f, r.made.findings_at);
  back(f, r.made.left_out_at);
  back(f, r.guard.outside_at);
  back(f, r.guard.in_solid_at);
  back(f, r.guard.removed_at);
  back(f, r.relief.thin_zone_solid_dropped_at);
  back(f, r.painted.at);   // P3
  {
    double six[6];
    f.axis_six_to_model(r.relief.grew_mm, six);
    for (int q = 0; q < 6; ++q) r.relief.grew_mm[q] = six[q];
    f.axis_six_to_model(r.made.shells.grew_mm, six);
    for (int q = 0; q < 6; ++q) r.made.shells.grew_mm[q] = six[q];
  }
  if (r.grown) {
    auto g = std::make_shared<GrowReport>(*r.grown);
    for (GrowReport::WallRefused& w : g->wall_refused_at) w.at = f.point_to_model(w.at);
    r.grown = std::move(g);
  }
  // The posts stay in the print frame (MeshSpec::Post is vertical there); file_result_json writes their two ends turned.
}

}  // namespace topopt::lattice_layout
