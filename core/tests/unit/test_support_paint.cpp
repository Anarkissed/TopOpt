// P3, his print orientation: painted supports (support_paint.hpp) and the 3MF that carries them (threemf_stream.hpp).
// The part: the synthetic T-block of the Bambu check (agent-scratch .../orient/make_shelf_3mf.py): a stem under a bar,
// two 15 mm shelves (left and right) with their undersides at z = 15, never his files.
//   §1 a place under the RIGHT shelf paints exactly the right shelf's underside; no place, nothing; no places asked:
//      both shelves (the 45 degree rule); nothing on the bed; "outside" false (material below): nothing.
//   §2 the file: support on, Tree (manual) for Bambu / Orca, enforcers only for PrusaSlicer, both marks on each painted
//      triangle and on no other, PrusaSlicer's one volume naming every triangle; a writer with supports off writes
//      what it always wrote. The files are left in the build folder for the slicer check (SUPPORT_PAINT_TMP_DIR).
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/support_paint.hpp"
#include "topopt/threemf_stream.hpp"

#ifdef TOPOPT_HAVE_ZLIB
#include <zlib.h>
#endif

#ifndef SUPPORT_PAINT_TMP_DIR
#define SUPPORT_PAINT_TMP_DIR "."
#endif

using namespace topopt;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                        \
  do {                                                                                     \
    ++g_checks;                                                                            \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

namespace {

const std::string kTmp = SUPPORT_PAINT_TMP_DIR;

std::string slurp(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}
bool has(const std::string& s, const std::string& w) { return s.find(w) != std::string::npos; }

// The T-block, as make_shelf_3mf.py makes it (placed near the middle of a 256 mm plate), outward normals.
TriangleMesh shelf(std::vector<int>* right_underside, std::vector<int>* left_underside) {
  const double P[8][2] = {{0, 0}, {20, 0}, {20, 15}, {35, 15}, {35, 20}, {-15, 20}, {-15, 15}, {0, 15}};
  const double ox = 100.0, oy = 100.0;
  TriangleMesh m;
  for (int s = 0; s < 2; ++s)
    for (int i = 0; i < 8; ++i) m.vertices.push_back({P[i][0] + ox, (s ? 20.0 : 0.0) + oy, P[i][1]});
  const auto normal = [&](int a, int b, int c) {
    const Vec3 &A = m.vertices[a], &B = m.vertices[b], &C = m.vertices[c];
    const Vec3 u{B.x - A.x, B.y - A.y, B.z - A.z}, w{C.x - A.x, C.y - A.y, C.z - A.z};
    return Vec3{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
  };
  const int cap[6][3] = {{0, 1, 2}, {0, 2, 7}, {5, 6, 7}, {5, 7, 2}, {5, 2, 3}, {5, 3, 4}};
  for (const auto& t : cap) {
    if (normal(t[0], t[1], t[2]).y > 0) m.triangles.push_back({t[0], t[2], t[1]});
    else m.triangles.push_back({t[0], t[1], t[2]});
    if (normal(t[0] + 8, t[1] + 8, t[2] + 8).y < 0) m.triangles.push_back({t[0] + 8, t[2] + 8, t[1] + 8});
    else m.triangles.push_back({t[0] + 8, t[1] + 8, t[2] + 8});
  }
  for (int a = 0; a < 8; ++a) {
    const int b = (a + 1) % 8;
    const double dx = P[b][0] - P[a][0], dz = P[b][1] - P[a][1];
    const Vec3 out{dz, 0.0, -dx};
    for (const std::array<int, 3>& t0 : {std::array<int, 3>{a, b, b + 8}, std::array<int, 3>{a, b + 8, a + 8}}) {
      std::array<int, 3> t = t0;
      const Vec3 n = normal(t[0], t[1], t[2]);
      if (n.x * out.x + n.z * out.z < 0) std::swap(t[1], t[2]);
      if (a == 2 && right_underside) right_underside->push_back(static_cast<int>(m.triangles.size()));
      if (a == 6 && left_underside) left_underside->push_back(static_cast<int>(m.triangles.size()));
      m.triangles.push_back(t);
    }
  }
  return m;
}

// The zip's entries, by name (inflated where deflated).
std::map<std::string, std::string> entries(const std::string& zip) {
  std::map<std::string, std::string> out;
  for (std::size_t at = 0; at + 30 <= zip.size();) {
    auto u16 = [&](std::size_t i) { return static_cast<unsigned>(static_cast<unsigned char>(zip[i])) | static_cast<unsigned>(static_cast<unsigned char>(zip[i + 1])) << 8; };
    auto u32 = [&](std::size_t i) { return u16(i) | u16(i + 2) << 16; };
    if (u32(at) != 0x04034b50u) break;
    const unsigned method = u16(at + 8), csize = u32(at + 18), size = u32(at + 22), nl = u16(at + 26), xl = u16(at + 28);
    const std::string name = zip.substr(at + 30, nl);
    const std::string data = zip.substr(at + 30 + nl + xl, csize);
    if (method == 0) out[name] = data;
#ifdef TOPOPT_HAVE_ZLIB
    if (method == 8) {
      std::string d(size, '\0');
      z_stream zs;
      std::memset(&zs, 0, sizeof zs);
      inflateInit2(&zs, -15);
      zs.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(data.data()));
      zs.avail_in = static_cast<uInt>(data.size());
      zs.next_out = reinterpret_cast<Bytef*>(&d[0]);
      zs.avail_out = static_cast<uInt>(size);
      inflate(&zs, Z_FINISH);
      inflateEnd(&zs);
      out[name] = d;
    }
#endif
    at += 30 + nl + xl + csize;
  }
  return out;
}

void write_3mf(const std::string& path, const TriangleMesh& m, const std::vector<char>* paint) {
  StreamingThreeMfWriter::Options o;
  o.indexed = true;
  o.deflate = true;
  o.supports = paint != nullptr;
  o.object_name = "shelf";
  StreamingThreeMfWriter w(path, o);
  for (const Vec3& v : m.vertices) w.add_vertex(v);
  for (std::size_t i = 0; i < m.triangles.size(); ++i) {
    const auto& t = m.triangles[i];
    if (paint) w.add_indexed(t[0], t[1], t[2], (*paint)[i] != 0);
    else w.add_indexed(t[0], t[1], t[2]);
  }
  w.finish();
}

}  // namespace

int main() {
  std::vector<int> right, left;
  const TriangleMesh m = shelf(&right, &left);
  CHECK(m.triangles.size() == 28 && right.size() == 2 && left.size() == 2);
  const auto painted_set = [](const SupportPaint& p) {
    std::vector<int> v;
    for (std::size_t i = 0; i < p.painted.size(); ++i)
      if (p.painted[i]) v.push_back(static_cast<int>(i));
    return v;
  };
  const auto sorted = [](std::vector<int> v) { std::sort(v.begin(), v.end()); return v; };
  // §1
  {
    SupportPaintAsk a;
    const std::vector<Vec3> place{{127.5, 110.0, 15.1}};   // the first layer of the right shelf, its middle
    a.places = &place;
    const SupportPaint p = paint_supports(m, a);
    std::printf("[right] painted %zu, area %.6g, est %.6g, places %zu unpainted %zu\n", p.triangles, p.area_mm2,
                p.est_volume_mm3, p.places, p.places_unpainted);
    CHECK(painted_set(p) == sorted(right));
    CHECK(std::fabs(p.area_mm2 - 15.0 * 20.0) < 1e-9 && std::fabs(p.est_volume_mm3 - 15.0 * 20.0 * 15.0) < 1e-6);
    CHECK(p.places == 1 && p.places_unpainted == 0);
    const std::vector<Vec3> far{{110.0, 110.0, 30.0}};
    a.places = &far;
    const SupportPaint q = paint_supports(m, a);
    CHECK(q.triangles == 0 && q.places_unpainted == 1);
    a.places = nullptr;
    const SupportPaint all = paint_supports(m, a);
    std::vector<int> both = right;
    both.insert(both.end(), left.begin(), left.end());
    CHECK(painted_set(all) == sorted(both));   // the bottom of the stem is on the bed: never painted
    a.outside = [](const Vec3&) { return false; };   // material under every face: nothing
    CHECK(paint_supports(m, a).triangles == 0);
    a.outside = [](const Vec3& v) { return v.x > 120.0; };   // only right of the stem is air
    CHECK(painted_set(paint_supports(m, a)) == sorted(right));
    a.part_triangles = 4;   // only the first triangles are the part's: none of them faces down
    CHECK(paint_supports(m, a).triangles == 0);
  }
  // §2
  {
    SupportPaintAsk a;
    const std::vector<Vec3> place{{127.5, 110.0, 15.1}};
    a.places = &place;
    const SupportPaint p = paint_supports(m, a);
    const std::string painted_path = kTmp + "/shelf_painted_core.3mf", plain_path = kTmp + "/shelf_plain_core.3mf";
    write_3mf(painted_path, m, &p.painted);
    write_3mf(plain_path, m, nullptr);
    const auto e = entries(slurp(painted_path));
    CHECK(e.count("3D/3dmodel.model") && e.count("Metadata/model_settings.config") && e.count("Metadata/Slic3r_PE_model.config"));
    const std::string& model = e.at("3D/3dmodel.model");
    CHECK(has(model, "xmlns:slic3rpe=\"http://schemas.slic3r.org/3mf/2017/06\""));
    std::size_t marks = 0, t = 0;
    bool right_marked = true;
    for (std::size_t at = model.find("<triangle "); at != std::string::npos; at = model.find("<triangle ", at + 1), ++t) {
      const std::size_t end = model.find("/>", at);
      const std::string line = model.substr(at, end - at);
      const bool mark = has(line, "paint_supports=\"4\"") && has(line, "slic3rpe:custom_supports=\"4\"");
      marks += mark;
      const bool want = std::find(right.begin(), right.end(), static_cast<int>(t)) != right.end();
      right_marked = right_marked && mark == want;
    }
    CHECK(t == 28 && marks == 2 && right_marked);
    const std::string& bambu = e.at("Metadata/model_settings.config");
    CHECK(has(bambu, "<object id=\"1\">") && has(bambu, "key=\"enable_support\" value=\"1\"") &&
          has(bambu, "key=\"support_type\" value=\"tree(manual)\""));
    const std::string& prusa = e.at("Metadata/Slic3r_PE_model.config");
    CHECK(has(prusa, "key=\"support_material\" value=\"1\"") && has(prusa, "key=\"support_material_auto\" value=\"0\"") &&
          has(prusa, "<volume firstid=\"0\" lastid=\"27\">"));
    const auto ep = entries(slurp(plain_path));
    CHECK(ep.size() == 3 && !has(ep.at("3D/3dmodel.model"), "slic3rpe") && !has(ep.at("3D/3dmodel.model"), "paint_supports"));
    // The geometry is the same, mark for mark: the painted file's model less its marks and namespace is the plain one.
    std::string stripped = model;
    for (const std::string& cut : {std::string(" paint_supports=\"4\" slic3rpe:custom_supports=\"4\""),
                                   std::string(" xmlns:slic3rpe=\"http://schemas.slic3r.org/3mf/2017/06\"")})
      for (std::size_t at = stripped.find(cut); at != std::string::npos; at = stripped.find(cut)) stripped.erase(at, cut.size());
    CHECK(stripped == ep.at("3D/3dmodel.model"));
    std::printf("files for the slicer check: %s, %s\n", painted_path.c_str(), plain_path.c_str());
  }
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
