// Brief E2, items 9 to 11 (lattice_layout_organic.hpp): the width floors a strengthen round leaves, their file, and
// strengthened.json (the job key "strengthened", read alike by the file job and the preview).
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <unordered_map>

#include "../flexible/json.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_organic.hpp"

namespace topopt::lattice_layout {
namespace {

namespace json = topopt::flexible::json;

using Key = std::array<long long, 3>;
Key end_key(const Vec3& p) {   // as bars.cpp's key_of (kSame 1e-5 mm)
  return {std::llround(p.x / 1e-5), std::llround(p.y / 1e-5), std::llround(p.z / 1e-5)};
}
std::string folder_of(const std::string& path) {
  const std::size_t at = path.find_last_of('/');
  return at == std::string::npos ? std::string(".") : path.substr(0, at);
}

}  // namespace

std::size_t apply_width_floors(Bars& bars, const std::vector<WidthFloor>& floors, double upper_mm, double light_mm,
                               double link_width, std::size_t* links) {
  if (links) *links = 0;
  if (floors.empty() || bars.bars.empty()) return 0;
  // The floors in a hash of cells as wide as the largest ball.
  double cell = 0.0;
  for (const WidthFloor& f : floors) cell = std::max(cell, f.radius_mm);
  if (!(cell > 0.0)) return 0;
  std::map<Key, std::vector<std::size_t>> grid;
  auto cell_of = [&](const Vec3& p) {
    return Key{static_cast<long long>(std::floor(p.x / cell)), static_cast<long long>(std::floor(p.y / cell)),
               static_cast<long long>(std::floor(p.z / cell))};
  };
  for (std::size_t i = 0; i < floors.size(); ++i) grid[cell_of(floors[i].centre)].push_back(i);
  std::size_t widened = 0;
  for (Bar& b : bars.bars) {
    if (b.link) continue;
    const Vec3 m{0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)};
    const Key k = cell_of(m);
    double least = 0.0;
    for (long long dx = -1; dx <= 1; ++dx)
      for (long long dy = -1; dy <= 1; ++dy)
        for (long long dz = -1; dz <= 1; ++dz) {
          const auto it = grid.find({k[0] + dx, k[1] + dy, k[2] + dz});
          if (it == grid.end()) continue;
          for (std::size_t i : it->second) {
            const WidthFloor& f = floors[i];
            const double ex = m.x - f.centre.x, ey = m.y - f.centre.y, ez = m.z - f.centre.z;
            if (ex * ex + ey * ey + ez * ez <= f.radius_mm * f.radius_mm) least = std::max(least, f.width_mm);
          }
        }
    const double w = std::max(b.width, std::min(least, upper_mm));
    if (w > b.width) {
      b.width = w;
      ++widened;
    }
  }
  // S8 for the links, from the struts at their two ends (each end: the widest non-link bar ending there).
  std::map<Key, double> widest;
  for (const Bar& b : bars.bars) {
    if (b.link) continue;
    for (const Vec3* p : {&b.a, &b.b}) {
      double& w = widest[end_key(*p)];
      w = std::max(w, b.width);
    }
  }
  for (Bar& l : bars.bars) {
    if (!l.link) continue;
    const auto ia = widest.find(end_key(l.a)), ib = widest.find(end_key(l.b));
    const double x = ia == widest.end() ? 0.0 : ia->second, y = ib == widest.end() ? 0.0 : ib->second;
    if (x <= 0.0 && y <= 0.0) continue;
    const double thin = x > 0.0 && y > 0.0 ? std::min(x, y) : std::max(x, y), thick = std::max(x, y);
    const double w = std::max(light_mm, std::min(link_width * thin, thick));
    if (w > l.width + 1e-12) {
      l.width = w;
      if (links) ++*links;
    }
  }
  return widened;
}

bool write_floors_file(const std::string& path, const std::vector<WidthFloor>& floors) {
  std::ofstream f(path, std::ios::binary);
  if (!f) return false;
  const std::int32_t version = 1, count = static_cast<std::int32_t>(floors.size());
  f.write("TOFLOORS", 8);
  f.write(reinterpret_cast<const char*>(&version), 4);
  f.write(reinterpret_cast<const char*>(&count), 4);
  for (const WidthFloor& x : floors) {
    const double v[5] = {x.centre.x, x.centre.y, x.centre.z, x.radius_mm, x.width_mm};
    f.write(reinterpret_cast<const char*>(v), sizeof v);
  }
  return static_cast<bool>(f);
}

bool read_floors_file(const std::string& path, std::vector<WidthFloor>& floors, std::string* why) {
  auto no = [&](const char* w) {
    if (why) *why = w;
    return false;
  };
  std::ifstream f(path, std::ios::binary);
  if (!f) return no("the floors file cannot be opened");
  char magic[8];
  std::int32_t version = 0, count = 0;
  f.read(magic, 8);
  f.read(reinterpret_cast<char*>(&version), 4);
  f.read(reinterpret_cast<char*>(&count), 4);
  if (!f || std::memcmp(magic, "TOFLOORS", 8) != 0) return no("the floors file is not one");
  if (version != 1) return no("the floors file's version is not 1");
  if (count < 0) return no("the floors file's count is below 0");
  floors.clear();
  floors.reserve(static_cast<std::size_t>(count));
  for (std::int32_t i = 0; i < count; ++i) {
    double v[5];
    f.read(reinterpret_cast<char*>(v), sizeof v);
    if (!f) return no("the floors file is shorter than its count");
    for (double x : v)
      if (!std::isfinite(x)) return no("the floors file holds a number that is not finite");
    floors.push_back({{v[0], v[1], v[2]}, v[3], v[4]});
  }
  if (f.peek() != EOF) return no("the floors file is longer than its count");
  return true;
}

bool write_strengthened_file(const std::string& path, const Strengthened& s, const std::string& more_json) {
  char ref[64];
  std::snprintf(ref, sizeof ref, "%.17g", s.reference_mpa);
  std::string t = s.version == 2
                      ? "{\n  \"version\": 2,\n  \"mode\": \"additive\",\n  \"additions\": \"" + s.additions + "\""
                      : "{\n  \"version\": 1,\n  \"stress_input\": \"" + s.stress_input + "\",\n  \"floors\": \"" + s.floors +
                            "\",\n  \"reference_mpa\": " + ref;
  if (!more_json.empty()) t += ",\n" + more_json;
  t += "\n}\n";
  std::ofstream f(path);
  f << t;
  return static_cast<bool>(f);
}

bool apply_strengthened(const std::string& path, TensorField& field, OrganicAsk& ask, std::string* why) {
  auto no = [&](const std::string& w) {
    if (why) *why = w;
    return false;
  };
  std::ifstream f(path);
  if (!f) return no("the strengthened file cannot be opened");
  std::ostringstream all;
  all << f.rdbuf();
  Strengthened s;
  try {
    const json::Value doc = json::parse(all.str(), "strengthened.json");
    const long long version = json::as_int(json::require(doc, "version", "strengthened.json"), "version");
    if (version == 2) {   // brief E3a: the additive mode; the job's own stress and floors stay
      s.additions = json::as_string(json::require(doc, "additions", "strengthened.json"), "additions");
      if (s.additions.empty() || s.additions == "." || s.additions == ".." || s.additions.find_first_of("/\\") != std::string::npos)
        return no("the strengthened file must name its files by bare name, beside it");
      Additions adds;
      std::string w;
      if (!read_additions_file(folder_of(path) + "/" + s.additions, adds, &w)) return no(w);
      ask.additions = std::move(adds);
      return true;
    }
    if (version != 1) return no("the strengthened file's version is not 1 or 2");
    s.stress_input = json::as_string(json::require(doc, "stress_input", "strengthened.json"), "stress_input");
    s.floors = json::as_string(json::require(doc, "floors", "strengthened.json"), "floors");
    s.reference_mpa = json::as_number(json::require(doc, "reference_mpa", "strengthened.json"), "reference_mpa");
  } catch (const std::exception& e) {
    return no(e.what());
  }
  for (const std::string* n : {&s.stress_input, &s.floors})
    if (n->empty() || *n == "." || *n == ".." || n->find_first_of("/\\") != std::string::npos)
      return no("the strengthened file must name its files by bare name, beside it");
  if (!(s.reference_mpa > 0.0)) return no("the strengthened file's reference_mpa must be above 0");
  const std::string dir = folder_of(path);
  TensorField boosted;
  std::string w;
  if (!read_tensor_file(dir + "/" + s.stress_input, boosted, &w)) return no("its stress input: " + w);
  std::vector<WidthFloor> floors;
  if (!read_floors_file(dir + "/" + s.floors, floors, &w)) return no(w);
  field = std::move(boosted);
  ask.reference_mpa = s.reference_mpa;
  ask.floors.insert(ask.floors.end(), floors.begin(), floors.end());
  return true;
}

}  // namespace topopt::lattice_layout
