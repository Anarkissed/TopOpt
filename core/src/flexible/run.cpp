#include "topopt/flexible/run.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "topopt/face_overrides.hpp"  // import_part_file_resolved
#include "topopt/face_region.hpp"
#include "topopt/flexible/data.hpp"
#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/field.hpp"
#include "topopt/flexible/job_block.hpp"
#include "topopt/flexible/recommend.hpp"
#include "topopt/flexible/squish.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/voxel.hpp"

namespace topopt {
namespace {

using namespace flexible;

const double kNaN = std::numeric_limits<double>::quiet_NaN();

// ── JSON text ──────────────────────────────────────────────────────────────────
std::string jnum(double v) {
  if (!std::isfinite(v)) return "null";
  char b[40];
  std::snprintf(b, sizeof(b), "%.6g", v);
  return b;
}
std::string jstr(const std::string& s) {
  std::string o = "\"";
  for (char c : s) {
    if (c == '"' || c == '\\') {
      o.push_back('\\');
      o.push_back(c);
    } else if (c == '\n') {
      o += "\\n";
    } else if (static_cast<unsigned char>(c) < 0x20) {
      char b[8];
      std::snprintf(b, sizeof(b), "\\u%04x", static_cast<unsigned>(c));
      o += b;
    } else {
      o.push_back(c);
    }
  }
  return o + "\"";
}
std::string jbool(bool b) { return b ? "true" : "false"; }
std::string jvec(const Vec3& v) { return "[" + jnum(v.x) + ", " + jnum(v.y) + ", " + jnum(v.z) + "]"; }
std::string jarr(const std::vector<double>& v) {
  std::string o = "[";
  for (std::size_t i = 0; i < v.size(); ++i) o += (i ? ", " : "") + jnum(v[i]);
  return o + "]";
}
std::string jcurve(const std::vector<double>& x, const std::vector<double>& y) {
  std::string o = "[";
  for (std::size_t i = 0; i < x.size(); ++i)
    o += (i ? ", " : "") + std::string("[") + jnum(x[i]) + ", " + jnum(y[i]) + "]";
  return o + "]";
}

struct Obj {
  std::string s = "{";
  bool first = true;
  Obj& add(const std::string& k, const std::string& raw) {
    s += (first ? "" : ", ") + jstr(k) + ": " + raw;
    first = false;
    return *this;
  }
  std::string str() const { return s + "}"; }
};
std::string jlist(const std::vector<std::string>& items) {
  std::string o = "[";
  for (std::size_t i = 0; i < items.size(); ++i) o += (i ? ", " : "") + items[i];
  return o + "]";
}
std::string jrange(const Range1& r) {
  if (!r.any) return "null";
  return Obj().add("min", jnum(r.min)).add("mean", jnum(r.mean)).add("max", jnum(r.max)).str();
}

// A CSV line with every non-finite field left EMPTY (H1: an unknown value is blank with
// its status beside it, never a number).
std::string blank_nans(std::string line) {
  for (const char* t : {"-nan", "nan", "-inf", "inf"}) {
    std::size_t at = 0;
    const std::string tok(t);
    while ((at = line.find(tok, at)) != std::string::npos) {
      const bool left = at == 0 || line[at - 1] == ',';
      const std::size_t end = at + tok.size();
      const bool right = end == line.size() || line[end] == ',' || line[end] == '\n';
      if (left && right)
        line.erase(at, tok.size());
      else
        at = end;
    }
  }
  return line;
}

std::string fmtd(double v, int dec) {
  char b[40];
  std::snprintf(b, sizeof(b), "%.*f", dec, v);
  return b;
}

void write_text(const std::string& path, const std::string& text) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out) throw JobError("cannot write " + path);
  out << text;
  if (!out) throw JobError("failed writing " + path);
}

// ── colour ──────────────────────────────────────────────────────────────────────
struct RGB {
  int r, g, b;
};
RGB viridis(double t) {
  static const RGB stops[5] = {{68, 1, 84}, {59, 82, 139}, {33, 145, 140}, {94, 201, 98}, {253, 231, 37}};
  t = std::min(1.0, std::max(0.0, t));
  const double x = t * 4.0;
  const int i = std::min(3, static_cast<int>(x));
  const double f = x - i;
  return {static_cast<int>(std::lround(stops[i].r + f * (stops[i + 1].r - stops[i].r))),
          static_cast<int>(std::lround(stops[i].g + f * (stops[i + 1].g - stops[i].g))),
          static_cast<int>(std::lround(stops[i].b + f * (stops[i + 1].b - stops[i].b)))};
}
std::string hex(RGB c) {
  char b[8];
  std::snprintf(b, sizeof(b), "#%02x%02x%02x", c.r, c.g, c.b);
  return b;
}
std::string esc(const std::string& s) {
  std::string o;
  for (char c : s) {
    if (c == '<') o += "&lt;";
    else if (c == '>') o += "&gt;";
    else if (c == '&') o += "&amp;";
    else o.push_back(c);
  }
  return o;
}

// ── SVG maps over a face's column grid ─────────────────────────────────────────
struct Canvas {
  double scale = 1.0;  // px per mm
  double map_w = 0.0, map_h = 0.0;
  double left = 80.0, top = 0.0;
};

std::string svg_open(double w, double h) {
  return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" + fmtd(w, 0) + "\" height=\"" +
         fmtd(h, 0) + "\" viewBox=\"0 0 " + fmtd(w, 0) + " " + fmtd(h, 0) +
         "\" font-family=\"Helvetica, Arial, sans-serif\" font-size=\"12\" "
         "shape-rendering=\"crispEdges\">\n"
         "<rect width=\"100%\" height=\"100%\" fill=\"#ffffff\"/>\n";
}
std::string text_at(double x, double y, const std::string& s, const char* extra = "") {
  return "<text x=\"" + fmtd(x, 1) + "\" y=\"" + fmtd(y, 1) + "\" " + extra + ">" + esc(s) +
         "</text>\n";
}

std::string header(const std::string& title, const std::vector<std::string>& notes, double& y) {
  std::string o = text_at(20, 28, title, "font-size=\"16\" font-weight=\"bold\"");
  y = 50;
  for (const std::string& n : notes) {
    o += text_at(20, y, n, "fill=\"#333333\"");
    y += 16;
  }
  y += 10;
  return o;
}

// Cells of one colour per row run, so a 128 x 128 face stays a small file.
std::string cells(const Stack& s, const Canvas& c, const std::vector<std::string>& colour) {
  std::string o;
  const double px = s.pitch_mm * c.scale;
  for (int iv = 0; iv < s.nv; ++iv) {
    int iu = 0;
    while (iu < s.nu) {
      const int k = s.column_at(iu, iv);
      if (k < 0) {
        ++iu;
        continue;
      }
      const std::string& col = colour[static_cast<std::size_t>(k)];
      int run = 1;
      while (iu + run < s.nu) {
        const int k2 = s.column_at(iu + run, iv);
        if (k2 < 0 || colour[static_cast<std::size_t>(k2)] != col) break;
        ++run;
      }
      const double x = c.left + iu * px;
      const double y = c.top + (s.nv - 1 - iv) * px;  // v up
      o += "<rect x=\"" + fmtd(x, 2) + "\" y=\"" + fmtd(y, 2) + "\" width=\"" + fmtd(run * px + 0.05, 2) +
           "\" height=\"" + fmtd(px + 0.05, 2) + "\" fill=\"" + col + "\"/>\n";
      iu += run;
    }
  }
  return o;
}

std::string axes(const Stack& s, const Canvas& c) {
  std::string o = "<rect x=\"" + fmtd(c.left, 1) + "\" y=\"" + fmtd(c.top, 1) + "\" width=\"" +
                  fmtd(c.map_w, 1) + "\" height=\"" + fmtd(c.map_h, 1) +
                  "\" fill=\"none\" stroke=\"#555555\"/>\n";
  const double U = s.nu * s.pitch_mm, V = s.nv * s.pitch_mm;
  for (double f : {0.0, 0.5, 1.0}) {
    const double x = c.left + f * c.map_w;
    o += "<line x1=\"" + fmtd(x, 1) + "\" y1=\"" + fmtd(c.top + c.map_h, 1) + "\" x2=\"" + fmtd(x, 1) +
         "\" y2=\"" + fmtd(c.top + c.map_h + 5, 1) + "\" stroke=\"#555555\"/>\n";
    o += text_at(x, c.top + c.map_h + 18, fmtd(f * U, 1), "text-anchor=\"middle\"");
    const double y = c.top + c.map_h - f * c.map_h;
    o += "<line x1=\"" + fmtd(c.left - 5, 1) + "\" y1=\"" + fmtd(y, 1) + "\" x2=\"" + fmtd(c.left, 1) +
         "\" y2=\"" + fmtd(y, 1) + "\" stroke=\"#555555\"/>\n";
    o += text_at(c.left - 8, y + 4, fmtd(f * V, 1), "text-anchor=\"end\"");
  }
  o += text_at(c.left + c.map_w / 2, c.top + c.map_h + 34, "u (mm), along the frame's X",
               "text-anchor=\"middle\" fill=\"#333333\"");
  o += "<text x=\"" + fmtd(c.left - 48, 1) + "\" y=\"" + fmtd(c.top + c.map_h / 2, 1) +
       "\" text-anchor=\"middle\" fill=\"#333333\" transform=\"rotate(-90 " + fmtd(c.left - 48, 1) + " " +
       fmtd(c.top + c.map_h / 2, 1) + ")\">v (mm), along the frame's Y</text>\n";
  return o;
}

Canvas canvas_for(const Stack& s, double top) {
  Canvas c;
  const double U = s.nu * s.pitch_mm, V = s.nv * s.pitch_mm;
  c.scale = std::min(560.0 / U, 560.0 / V);
  c.map_w = U * c.scale;
  c.map_h = V * c.scale;
  c.top = top;
  return c;
}

// A continuous heat map with a colour bar, tick numbers and min / mean / max.
// `special` (optional, parallel to the columns): a fixed colour for a column that has
// no value for a stated reason (e.g. beyond the data), described in `notes`.
std::string heatmap_svg(const Stack& s, const std::vector<double>& values, const std::string& title,
                        std::vector<std::string> notes, const std::string& unit, int dec,
                        const std::vector<std::string>* special = nullptr) {
  double lo = 1e300, hi = -1e300, sum = 0.0;
  int n = 0, missing = 0;
  for (std::size_t k = 0; k < values.size(); ++k) {
    const double v = values[k];
    if (special != nullptr && !(*special)[k].empty()) continue;
    if (!std::isfinite(v)) {
      ++missing;
      continue;
    }
    lo = std::min(lo, v);
    hi = std::max(hi, v);
    sum += v;
    ++n;
  }
  if (n == 0) {
    lo = 0;
    hi = 1;
  }
  const double span = hi > lo ? hi - lo : 0.0;
  if (n > 0)
    notes.push_back("min " + fmtd(lo, dec) + "  mean " + fmtd(sum / n, dec) + "  max " + fmtd(hi, dec) +
                    " " + unit + "  (" + std::to_string(n) + " columns" +
                    (missing ? ", " + std::to_string(missing) + " with no value: grey" : "") + ")");
  double y = 0;
  std::string body = header(title, notes, y);
  const Canvas c = canvas_for(s, y);
  std::vector<std::string> colour(values.size());
  for (std::size_t k = 0; k < values.size(); ++k)
    colour[k] = (special != nullptr && !(*special)[k].empty())
                    ? (*special)[k]
                    : std::isfinite(values[k]) ? hex(viridis(span > 0 ? (values[k] - lo) / span : 0.5))
                                               : std::string("#dddddd");
  body += cells(s, c, colour);
  body += axes(s, c);
  // colour bar
  const double bx = c.left + c.map_w + 40, bw = 18;
  for (int i = 0; i < 64; ++i) {
    const double t0 = i / 64.0;
    const double y0 = c.top + c.map_h * (1.0 - (i + 1) / 64.0);
    body += "<rect x=\"" + fmtd(bx, 1) + "\" y=\"" + fmtd(y0, 2) + "\" width=\"" + fmtd(bw, 1) +
            "\" height=\"" + fmtd(c.map_h / 64.0 + 0.3, 2) + "\" fill=\"" + hex(viridis(t0 + 0.5 / 64)) + "\"/>\n";
  }
  body += "<rect x=\"" + fmtd(bx, 1) + "\" y=\"" + fmtd(c.top, 1) + "\" width=\"" + fmtd(bw, 1) +
          "\" height=\"" + fmtd(c.map_h, 1) + "\" fill=\"none\" stroke=\"#555555\"/>\n";
  for (double f : {0.0, 0.25, 0.5, 0.75, 1.0}) {
    const double yy = c.top + c.map_h * (1.0 - f);
    body += text_at(bx + bw + 6, yy + 4, fmtd(lo + f * span, dec));
  }
  body += text_at(bx, c.top - 8, unit, "fill=\"#333333\"");
  const double W = std::max(bx + bw + 90, 640.0), H = c.top + c.map_h + 50;
  return svg_open(W, H) + body + "</svg>\n";
}

// A categorical map with a legend and counts.
std::string category_svg(const Stack& s, const std::vector<int>& cat,
                         const std::vector<std::pair<std::string, std::string>>& legend,
                         const std::string& title, const std::vector<std::string>& notes) {
  double y = 0;
  std::string body = header(title, notes, y);
  const Canvas c = canvas_for(s, y);
  std::vector<std::string> colour(cat.size());
  std::vector<int> count(legend.size(), 0);
  for (std::size_t k = 0; k < cat.size(); ++k) {
    colour[k] = legend[static_cast<std::size_t>(cat[k])].second;
    ++count[static_cast<std::size_t>(cat[k])];
  }
  body += cells(s, c, colour);
  body += axes(s, c);
  const double lx = c.left + c.map_w + 30;
  double ly = c.top + 4;
  for (std::size_t i = 0; i < legend.size(); ++i) {
    body += "<rect x=\"" + fmtd(lx, 1) + "\" y=\"" + fmtd(ly - 10, 1) +
            "\" width=\"14\" height=\"14\" fill=\"" + legend[i].second + "\" stroke=\"#555555\"/>\n";
    body += text_at(lx + 20, ly + 2, legend[i].first + ": " + std::to_string(count[i]));
    ly += 22;
  }
  const double W = std::max(lx + 340, 640.0), H = c.top + c.map_h + 50;
  return svg_open(W, H) + body + "</svg>\n";
}

// ── the field slice ─────────────────────────────────────────────────────────────
std::string field_slice_svg(const DensityField& f, bool owner_map, const std::string& title,
                            const std::vector<std::string>& notes, const std::vector<int>& face_ids) {
  const int j = f.ny / 2;
  double y = 0;
  std::string body = header(title, notes, y);
  const double W_mm = f.nx * f.spacing, H_mm = f.nz * f.spacing;
  const double sc = std::min(600.0 / W_mm, 420.0 / H_mm);
  const double left = 80, top = y, px = f.spacing * sc;
  double lo = 1e300, hi = -1e300;
  for (double d : f.density)
    if (d > 0.0) {
      lo = std::min(lo, d);
      hi = std::max(hi, d);
    }
  if (!(hi >= lo)) lo = hi = 0.0;
  static const char* palette[] = {"#1b9e77", "#d95f02", "#7570b3", "#e7298a", "#66a61e", "#e6ab02"};
  for (int k = 0; k < f.nz; ++k)
    for (int i = 0; i < f.nx; ++i) {
      const std::size_t idx = (static_cast<std::size_t>(k) * static_cast<std::size_t>(f.ny) +
                               static_cast<std::size_t>(j)) * static_cast<std::size_t>(f.nx) +
                              static_cast<std::size_t>(i);
      const double d = f.density[idx];
      if (d < 0.0) continue;
      std::string col = "#cccccc";  // lattice, no loaded stack
      if (d > 0.0) {
        if (owner_map) {
          const auto it = std::find(face_ids.begin(), face_ids.end(), f.owner[idx]);
          col = it == face_ids.end() ? "#999999" : palette[(it - face_ids.begin()) % 6];
        } else {
          col = hex(viridis(hi > lo ? (d - lo) / (hi - lo) : 0.5));
        }
      }
      body += "<rect x=\"" + fmtd(left + i * px, 2) + "\" y=\"" + fmtd(top + (f.nz - 1 - k) * px, 2) +
              "\" width=\"" + fmtd(px + 0.05, 2) + "\" height=\"" + fmtd(px + 0.05, 2) + "\" fill=\"" + col +
              "\"/>\n";
    }
  body += "<rect x=\"" + fmtd(left, 1) + "\" y=\"" + fmtd(top, 1) + "\" width=\"" + fmtd(W_mm * sc, 1) +
          "\" height=\"" + fmtd(H_mm * sc, 1) + "\" fill=\"none\" stroke=\"#555555\"/>\n";
  body += text_at(left + W_mm * sc / 2, top + H_mm * sc + 20,
                  "model X (mm): " + fmtd(f.origin.x, 1) + " .. " + fmtd(f.origin.x + W_mm, 1),
                  "text-anchor=\"middle\" fill=\"#333333\"");
  body += "<text x=\"" + fmtd(left - 20, 1) + "\" y=\"" + fmtd(top + H_mm * sc / 2, 1) +
          "\" text-anchor=\"middle\" fill=\"#333333\" transform=\"rotate(-90 " + fmtd(left - 20, 1) + " " +
          fmtd(top + H_mm * sc / 2, 1) + ")\">model Z (mm): " + fmtd(f.origin.z, 1) + " .. " +
          fmtd(f.origin.z + H_mm, 1) + "</text>\n";
  double ly = top + H_mm * sc + 44;
  if (owner_map) {
    for (std::size_t i = 0; i < face_ids.size(); ++i) {
      body += "<rect x=\"" + fmtd(left + 150 * static_cast<double>(i), 1) + "\" y=\"" + fmtd(ly - 10, 1) +
              "\" width=\"14\" height=\"14\" fill=\"" + palette[i % 6] + "\"/>\n";
      body += text_at(left + 150 * static_cast<double>(i) + 20, ly + 2, "face " + std::to_string(face_ids[i]));
    }
  } else {
    body += text_at(left, ly + 2, "density " + fmtd(lo, 3) + " (dark) .. " + fmtd(hi, 3) +
                                      " (yellow); grey = lattice under no loaded stack");
  }
  const double W = std::max(left + W_mm * sc + 60, 700.0), H = ly + 30;
  return svg_open(W, H) + body + "</svg>\n";
}

std::string lower_ext(const std::string& p) {
  const std::size_t d = p.find_last_of('.');
  std::string e = d == std::string::npos ? "" : p.substr(d + 1);
  for (char& c : e) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return e;
}

std::string safe_name(const std::string& s) {
  std::string o;
  for (char c : s) o.push_back(std::isalnum(static_cast<unsigned char>(c)) ? c : '_');
  return o.empty() ? "stamp" : o;
}

std::string stamp_json(const StampGrid& g) {
  return Obj()
      .add("name", jstr(g.name))
      .add("mode", jstr(g.rigid ? "rigid" : "soft"))
      .add("force_n", jnum(g.force_n))
      .add("cells_force_n", jnum(stamp_force_n(g)))
      .add("origin_mm", "[" + jnum(g.origin_u_mm) + ", " + jnum(g.origin_v_mm) + "]")
      .add("cell_mm", jnum(g.cell_mm))
      .add("nu", jnum(g.nu))
      .add("nv", jnum(g.nv))
      .str();
}

std::string region_json(const JobLatticeRegion& r) {
  Obj o;
  o.add("role", jstr(r.role)).add("kind", jstr(r.kind));
  if (r.kind == "region") o.add("region_id", jnum(r.region_id));
  if (r.kind == "bolt")
    o.add("axis_point", jvec(r.axis_point)).add("axis_dir", jvec(r.axis_dir))
        .add("radius_mm", jnum(r.radius_mm)).add("half_length_mm", jnum(r.half_length_mm));
  if (r.kind == "face")
    o.add("origin", jvec(r.origin)).add("normal", jvec(r.normal)).add("half_u_mm", jnum(r.half_u_mm))
        .add("half_w_mm", jnum(r.half_w_mm));
  if (r.kind != "bolt") o.add("depth_mm", jnum(r.depth_mm));
  return o.str();
}

std::string reasons_json(const std::vector<Reason>& rs) {
  std::vector<std::string> out;
  for (const Reason& r : rs)
    out.push_back(Obj().add("code", jstr(r.code)).add("text", jstr(r.text))
                      .add("face_region_id", r.face_region_id >= 0 ? jnum(r.face_region_id) : "null")
                      .str());
  return jlist(out);
}

std::string failure_json(const FaceFailure& f) {
  return Obj()
      .add("face_region_id", jnum(f.face_region_id))
      .add("topology", jstr(f.topology))
      .add("temp_c", jnum(f.temp_c))
      .add("too_firm", jnum(f.too_firm))
      .add("too_soft", jnum(f.too_soft))
      .add("beyond_data", jnum(f.beyond_data))
      .add("u_mm", "[" + jnum(f.u_min_mm) + ", " + jnum(f.u_max_mm) + "]")
      .add("v_mm", "[" + jnum(f.v_min_mm) + ", " + jnum(f.v_max_mm) + "]")
      .add("nearest_depth_mm", f.nearest_known ? "[" + jnum(f.nearest_depth_min_mm) + ", " +
                                                     jnum(f.nearest_depth_max_mm) + "]"
                                               : "null")
      .add("text", jstr(f.text))
      .str();
}

std::string recommendation_json(const Recommendation& r, const std::string& req_topo,
                                 const std::string& req_temp) {
  std::vector<std::string> cands;
  for (const Candidate& c : r.candidates) {
    std::vector<std::string> fl;
    for (const FaceFailure& f : c.failures) fl.push_back(failure_json(f));
    cands.push_back(Obj()
                        .add("topology", jstr(c.topology))
                        .add("temp_c", jnum(c.temp_c))
                        .add("eligible", jbool(c.eligible))
                        .add("has_data", jbool(c.has_data))
                        .add("refusal", c.refusal.refused()
                                            ? Obj().add("code", jstr(c.refusal.code))
                                                  .add("reason", jstr(c.refusal.reason)).str()
                                            : "null")
                        .add("reachable", jbool(c.reachable))
                        .add("unreachable_columns", jnum(c.unreachable_columns))
                        .add("near_edge_columns", jnum(c.near_edge_columns))
                        .add("material_volume_mm3", jnum(c.material_volume_mm3))
                        .add("mass_g", c.mass_known ? jnum(c.mass_g) : "null")
                        .add("insideness", jnum(c.insideness))
                        .add("failures", jlist(fl))
                        .str());
  }
  std::vector<std::string> fl;
  for (const FaceFailure& f : r.failures) fl.push_back(failure_json(f));
  return Obj()
      .add("requested", Obj().add("topology", jstr(req_topo)).add("nozzle_temp_c", req_temp).str())
      .add("chosen", jbool(r.chosen))
      .add("reachable", jbool(r.reachable))
      .add("topology", r.chosen ? jstr(r.topology) : "null")
      .add("nozzle_temp_c", r.chosen ? jnum(r.temp_c) : "null")
      .add("feel", jstr(r.feel))
      .add("sentence", jstr(r.sentence))
      .add("reasons", reasons_json(r.reasons))
      .add("failures", jlist(fl))
      .add("candidates", jlist(cands))
      .str();
}

}  // namespace

FlexibleRunResult run_flexible_job(const JobDescription& job, const std::string& job_dir,
                                   const std::string& out_dir,
                                   const std::string& flexible_materials_path,
                                   const FlexibleProvenance& provenance) {
  if (!job.flexible) throw JobError("this job has no \"flexible\" block");
  const JobFlexible& fx = *job.flexible;
  FlexibleRunResult result;
  {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec) throw JobError("cannot create output directory " + out_dir + ": " + ec.message());
  }
  auto out_path = [&](const std::string& name) {
    result.files.push_back(name);
    return (std::filesystem::path(out_dir) / name).string();
  };

  FlexibleData data;
  try {
    data = load_flexible_data(flexible_materials_path);
  } catch (const FlexibleError& e) {
    throw JobError(std::string("flexible data: ") + e.what());
  }

  // ── the part, its grid, the lattice region ──
  const std::string model_path = (std::filesystem::path(job_dir) / job.model).string();
  StepModel model;
  try {
    model = import_part_file_resolved(model_path);
  } catch (const PartError& e) {
    throw JobError("cannot import model \"" + job.model + "\": " + e.what());
  }
  if (!check_watertight(model.mesh).watertight)
    throw JobError("model tessellation is not watertight: " + job.model);
  const VoxelGrid grid = voxelize(model.mesh, job.resolution);
  std::vector<char> mask;
  std::vector<ResolvedFaceRegion> regions;
  try {
    mask = flexible_region_mask(job, model, grid);
    regions = resolve_face_regions(model, job.loads.face_regions);
  } catch (const FlexibleError& e) {
    throw JobError(e.what());
  } catch (const std::invalid_argument& e) {
    throw JobError(std::string("face regions: ") + e.what());
  }
  long long lattice_voxels = 0;
  for (char c : mask) lattice_voxels += c ? 1 : 0;
  const Vec3 build = job.has_build_direction ? job.build_direction
                                             : (job.loads.present ? job.loads.build_dir : Vec3{0, 0, 1});
  const double pitch = grid.spacing;

  auto find_region = [&](int id) -> const ResolvedFaceRegion& {
    for (const ResolvedFaceRegion& r : regions)
      if (r.id == id) return r;
    throw JobError("flexible face_region_id " + std::to_string(id) + " did not resolve");
  };

  // ── stacks ──
  std::vector<const JobFlexibleFace*> loaded;
  std::vector<Stack> stacks;
  for (const JobFlexibleFace& f : fx.faces)
    if (f.role == "loaded") loaded.push_back(&f);
  stacks.reserve(loaded.size());
  for (const JobFlexibleFace* f : loaded) {
    try {
      stacks.push_back(build_stack(model, find_region(f->face_region_id), regions, grid, mask,
                                   f->frame_rotation_deg, build, pitch));
    } catch (const FlexibleError& e) {
      throw JobError(e.what());
    }
  }
  std::vector<const Stack*> sp;
  for (const Stack& s : stacks) sp.push_back(&s);
  const std::vector<StackConflict> conflicts = find_stack_conflicts(grid, mask, sp);

  // ── the drawn maps (these need no data, so they are written even on a refusal) ──
  std::vector<std::vector<double>> target(stacks.size());
  for (std::size_t i = 0; i < stacks.size(); ++i) {
    const SquishMap m = squish_map_of(*loaded[i]);
    const std::vector<double> s = squish_fraction(stacks[i], m);
    target[i].resize(s.size());
    for (std::size_t k = 0; k < s.size(); ++k) target[i][k] = s[k] * m.deepest_squish_mm;
    const std::string id = std::to_string(loaded[i]->face_region_id);
    write_text(out_path("face" + id + "_target_depth.svg"),
               heatmap_svg(stacks[i], target[i], "Face " + id + " - target squish depth (what you drew)",
                           {"mode " + m.mode + ", deepest squish " + fmtd(m.deepest_squish_mm, 2) +
                                " mm, weight " + fmtd(loaded[i]->weight_n, 1) + " N",
                            "the drawn map: S x deepest squish. Not a prediction."},
                           "mm", 2));
  }

  // ── the recommender over the candidates the job leaves open ──
  const std::vector<double> temps = fx.nozzle_temp_auto
                                        ? tested_temperatures(data, fx.material_id)
                                        : std::vector<double>{fx.nozzle_temp_c};
  const std::vector<std::string> topos =
      fx.topology == "auto" ? std::vector<std::string>{"gyroid", "honeycomb"}
                            : std::vector<std::string>{fx.topology};
  std::vector<FaceRequest> requests;
  for (std::size_t i = 0; i < stacks.size(); ++i)
    requests.push_back({&stacks[i], squish_map_of(*loaded[i]), loaded[i]->weight_n,
                        loaded[i]->has_design_stamp ? &loaded[i]->design_stamp : nullptr});

  Recommendation rec;
  std::string refusal_code, refusal_reason;
  if (!conflicts.empty()) {
    refusal_code = "one_profile_per_stack";
    refusal_reason = "faces " + std::to_string(conflicts[0].face_a) + " and " +
                     std::to_string(conflicts[0].face_b) +
                     " are both loaded and push the same material along the same axis (" +
                     fmtd(conflicts[0].overlap_mm3, 0) +
                     " mm3 shared). One squish profile per stack (M13): mark one of them as "
                     "where it rests.";
  } else if (temps.empty()) {
    const auto it = data.catalogue.materials.find(fx.material_id);
    if (it != data.catalogue.materials.end() && it->second.tier == "literature") {
      refusal_code = "temperature_not_tested";
      refusal_reason = it->second.display_name + " has no tested temperature in its tables";
    } else {
      const Refusal gate = curve_set(data, fx.material_id, 0.0, "gyroid").refusal;
      refusal_code = gate.code;
      refusal_reason = gate.reason;
    }
  } else {
    try {
      rec = recommend(data, fx.material_id, temps, topos, fx.feel, fx.beads_per_wall,
                      fx.min_extrudable_width_mm, requests);
    } catch (const FlexibleError& e) {
      throw JobError(e.what());
    }
    if (!rec.chosen) {
      refusal_code = rec.reasons.empty() ? "no_data" : rec.reasons.back().code;
      refusal_reason = rec.sentence;
    }
  }

  // ── the design, the field, the checks ──
  std::vector<FaceDesign> designs;
  std::vector<std::string> face_json, check_json;
  DensityField field;
  CurveSet set;
  BuildParams bp;
  if (refusal_code.empty()) {
    set = curve_set(data, fx.material_id, rec.temp_c, rec.topology).set;
    bp = BuildParams{rec.topology, fx.beads_per_wall, fx.min_extrudable_width_mm};
    for (std::size_t i = 0; i < stacks.size(); ++i) {
      const TierBand tier = tier_band(data.catalogue.error_bands, set.tier, stacks[i].frame.side,
                                      fx.beads_per_wall);
      designs.push_back(design_face(set, stacks[i], requests[i].map, requests[i].weight_n,
                                    requests[i].design_stamp, bp, tier));
    }
    std::vector<LoadedStack> ls;
    for (std::size_t i = 0; i < stacks.size(); ++i) ls.push_back({&stacks[i], &designs[i]});
    field = assemble_density_field(grid, mask, ls, bp);
  }

  const std::string temp_label = rec.chosen ? fmtd(rec.temp_c, 0) + " \xC2\xB0""C" : std::string("-");
  for (std::size_t i = 0; i < stacks.size(); ++i) {
    const Stack& st = stacks[i];
    const JobFlexibleFace& jf = *loaded[i];
    const std::string id = std::to_string(jf.face_region_id);
    Obj fo;
    fo.add("face_region_id", jnum(jf.face_region_id)).add("role", jstr("loaded")).add("skin_on", jbool(jf.skin_on));
    const FaceFrame& fr = st.frame;
    fo.add("frame", Obj()
                        .add("load", jvec(fr.load))
                        .add("x_axis", jvec(fr.x_axis))
                        .add("y_axis", jvec(fr.y_axis))
                        .add("rotation_deg", jnum(fr.rotation_deg))
                        .add("u_extent_mm", jnum(fr.u_extent_mm))
                        .add("v_extent_mm", jnum(fr.v_extent_mm))
                        .add("area_mm2", jnum(fr.area_mm2))
                        .add("projected_area_mm2", jnum(fr.projected_area_mm2))
                        .add("normal_spread_deg", jnum(fr.normal_spread_deg))
                        .add("normal_spread_flag", jbool(fr.normal_spread_flag))
                        .add("principal_axis_tied", jbool(fr.principal_axis_tied))
                        .add("build_angle_deg", jnum(fr.build_angle_deg))
                        .add("side", jbool(fr.side))
                        .str());
    std::vector<std::string> links, rlinks;
    for (const StackLink& l : st.exit_faces)
      links.push_back(Obj().add("face_id", jnum(l.id)).add("area_fraction", jnum(l.area_fraction)).str());
    for (const StackLink& l : st.exit_regions)
      rlinks.push_back(Obj().add("face_region_id", jnum(l.id)).add("area_fraction", jnum(l.area_fraction)).str());
    fo.add("stack", Obj()
                        .add("columns", jnum(static_cast<double>(st.columns.size())))
                        .add("column_pitch_mm", jnum(st.pitch_mm))
                        .add("footprint_mm2", jnum(st.footprint_area_mm2))
                        .add("latticed_columns", jnum(st.latticed_columns))
                        .add("lattice_height_mm", Obj().add("min", jnum(st.lattice_mm_min))
                                                      .add("mean", jnum(st.lattice_mm_mean))
                                                      .add("max", jnum(st.lattice_mm_max)).str())
                        .add("stack_length_max_mm", jnum(st.stack_mm_max))
                        .add("linked_faces", jlist(links))
                        .add("linked_regions", jlist(rlinks))
                        .add("exit_unresolved_fraction", jnum(st.exit_unresolved_fraction))
                        .str());
    fo.add("weight_n", jnum(jf.weight_n))
        .add("deepest_squish_mm", jnum(jf.deepest_squish_mm))
        .add("mode", jstr(jf.mode));
    if (jf.mode == "centre_edge")
      fo.add("curve_centre_edge", jcurve(jf.curve_c_x, jf.curve_c_y));
    else
      fo.add("curve_x", jcurve(jf.curve_x_x, jf.curve_x_y)).add("curve_y", jcurve(jf.curve_y_x, jf.curve_y_y));
    fo.add("design_stamp", jf.has_design_stamp ? stamp_json(jf.design_stamp) : "null");
    if (!designs.empty()) {
      const FaceDesign& d = designs[i];
      fo.add("design_pressure_even_mpa", jnum(d.design_pressure_even_mpa))
          .add("design_stamp_rigid_averaged", jbool(d.design_stamp_rigid_averaged))
          .add("design_stamp_off_face_n", jnum(d.design_stamp_off_face_n))
          .add("design_stamp_off_face", jbool(d.design_stamp_off_face))
          .add("solid_under_map_columns", jnum(d.solid_under_map))
          .add("columns_by_status", Obj().add("ok", jnum(d.ok)).add("too_firm", jnum(d.too_firm))
                                        .add("too_soft", jnum(d.too_soft)).add("beyond_data", jnum(d.beyond_data))
                                        .add("no_lattice", jnum(d.no_lattice)).str())
          .add("clamped_columns", jnum(d.too_firm + d.too_soft + d.beyond_data))
          .add("target_extrapolated_columns", jnum(d.target_extrapolated))
          .add("buildable_extrapolated_columns", jnum(d.buildable_extrapolated))
          .add("buildable_beyond_data_columns", jnum(d.buildable_beyond_data))
          .add("near_table_edge_columns", jnum(d.near_edge))
          .add("target_depth_mm", jrange(d.target_depth))
          .add("buildable_depth_mm", jrange(d.buildable_depth))
          .add("buildable_depth_band_mm",
               d.buildable_depth.any ? "[" + jnum(d.buildable_depth.min * (1 - d.tier.band)) + ", " +
                                           jnum(d.buildable_depth.max * (1 + d.tier.band)) + "]"
                                     : "null")
          .add("density", jrange(d.buildable_density))
          .add("cell_mm", jrange(d.cell))
          .add("smoothing_sigma_mm", jrange(d.sigma))
          .add("max_smoothing_change_mm", jnum(d.max_smoothing_change_mm))
          .add("material_volume_mm3", jnum(d.material_volume_mm3))
          .add("tier", Obj().add("tier", jstr(d.tier.tier)).add("band", jnum(d.tier.band))
                           .add("why", jstr(d.tier.why)).str());

      // maps + CSV
      std::vector<double> bdepth(st.columns.size(), kNaN), dens(st.columns.size(), kNaN),
          cell(st.columns.size(), kNaN);
      std::vector<int> cat(st.columns.size(), 0);
      std::ostringstream csv;
      csv << "iu,iv,u_mm,v_mm,area_mm2,latticed_height_mm,exit_face,s,pressure_mpa,target_depth_mm,"
             "target_strain,status,target_density,nearest_depth_mm,clamped_density,clamped_depth_mm,"
             "sigma_mm,buildable_density,buildable_depth_mm,buildable_ok,buildable_extrapolated,cell_mm,"
             "tier,band,depth_band_lo_mm,depth_band_hi_mm\n";
      for (std::size_t k = 0; k < st.columns.size(); ++k) {
        const StackColumn& sc = st.columns[k];
        const ColumnDesign& c = d.columns[k];
        const bool has = c.status != "no_lattice";
        if (has) {
          dens[k] = c.buildable_density;
          cell[k] = c.cell_mm;
          if (c.buildable_ok) bdepth[k] = c.buildable_depth_mm;
        }
        if (!has) cat[k] = 5;
        else if (c.status == "too_firm") cat[k] = 2;
        else if (c.status == "too_soft") cat[k] = 3;
        else if (c.status == "beyond_data" || !c.buildable_ok) cat[k] = 4;
        else if (c.buildable_extrapolated || c.target_extrapolated) cat[k] = 1;
        char line[1024];
        std::snprintf(line, sizeof(line),
                      "%d,%d,%.4f,%.4f,%.4f,%.4f,%d,%.6f,%.6g,%.5f,%.6f,%s,%.6f,%.5f,%.6f,%.5f,%.4f,%.6f,%.5f,%d,%d,%.4f,%s,%.2f,%.5f,%.5f\n",
                      sc.iu, sc.iv, sc.u_mm, sc.v_mm, sc.area_mm2, sc.lattice_mm, sc.exit_face, c.s,
                      c.pressure_mpa, c.target_depth_mm, c.target_strain, c.status.c_str(),
                      c.status == "ok" ? c.target_density : kNaN,
                      c.nearest_known ? c.nearest_depth_mm : kNaN, has ? c.clamped_density : kNaN,
                      has ? c.clamped_depth_mm : kNaN, c.sigma_mm, has ? c.buildable_density : kNaN,
                      c.buildable_ok ? c.buildable_depth_mm : kNaN, c.buildable_ok ? 1 : 0,
                      c.buildable_extrapolated ? 1 : 0, has ? c.cell_mm : kNaN, d.tier.tier.c_str(),
                      d.tier.band, c.buildable_ok ? c.buildable_depth_mm * (1 - d.tier.band) : kNaN,
                      c.buildable_ok ? c.buildable_depth_mm * (1 + d.tier.band) : kNaN);
        csv << blank_nans(line);
      }
      write_text(out_path("face" + id + "_columns.csv"), csv.str());
      const std::string what = rec.topology + ", " + fx.material_id + " at " + temp_label + ", " +
                               std::to_string(fx.beads_per_wall) + " bead(s) of " +
                               fmtd(fx.min_extrudable_width_mm, 2) + " mm";
      const std::string band = "tier " + d.tier.tier + ", +/-" + fmtd(100 * d.tier.band, 0) +
                               " % on depth. Not a certificate.";
      write_text(out_path("face" + id + "_buildable_depth.svg"),
                 heatmap_svg(st, bdepth, "Face " + id + " - what can be built: squish depth under the design load",
                             {what, "clamped to the table, then smoothed (Gaussian, sigma = half the local cell): "
                                    "a heuristic C2 replaces",
                              band},
                             "mm", 2));
      write_text(out_path("face" + id + "_density.svg"),
                 heatmap_svg(st, dens, "Face " + id + " - printed-core relative density (buildable)",
                             {what, "axis: " + set.density_basis + "; table " + fmtd(set.density_min(), 3) +
                                        " .. " + fmtd(set.density_max(), 3)},
                             "rho", 3));
      write_text(out_path("face" + id + "_cell_size.svg"),
                 heatmap_svg(st, cell, "Face " + id + " - planning cell size at that density",
                             {what, rec.topology == "gyroid" ? "gyroid L = 3.0915 t / rho, t = beads x bead width"
                                                             : "honeycomb d = 2 t / rho, t = beads x bead width"},
                             "mm", 2));
      write_text(out_path("face" + id + "_tier_flags.svg"),
                 category_svg(st, cat,
                              {{"ok (measured, <= 0.20 strain)", "#2a9d8f"},
                               {"extrapolated (0.20 - 0.25 strain)", "#e9c46a"},
                               {"too firm: cannot squish that deep", "#457b9d"},
                               {"too soft: cannot stay that shallow", "#e76f51"},
                               {"beyond the data (> 0.25 strain)", "#9b2226"},
                               {"no lattice in this column", "#bbbbbb"}},
                              "Face " + id + " - tier and flags per column",
                              {what, band,
                               "colour = the drawn target's status (clamped where it is not ok) or the "
                               "buildable column's zone"}));
    }
    face_json.push_back(fo.str());
  }

  // check stamps
  if (refusal_code.empty()) {
    for (const JobFlexibleCheckStamp& cs : fx.check_stamps) {
      std::size_t i = 0;
      while (i < loaded.size() && loaded[i]->face_region_id != cs.face_region_id) ++i;
      const Stack& st = stacks[i];
      std::vector<double> rho(st.columns.size(), 0.0);
      for (std::size_t k = 0; k < st.columns.size(); ++k)
        rho[k] = designs[i].columns[k].status == "no_lattice" ? 0.0 : designs[i].columns[k].buildable_density;
      const StampCheck c = check_stamp(set, st, rho, cs.stamp, bp, designs[i].tier);
      const std::string name = "check_" + safe_name(cs.stamp.name) + "_face" + std::to_string(cs.face_region_id);
      std::vector<double> depth(st.columns.size(), kNaN);
      std::vector<std::string> special(st.columns.size());
      for (std::size_t k = 0; k < st.columns.size(); ++k)
        special[k] = c.status[k] == "beyond_data" ? "#9b2226" : c.status[k].empty() ? "#f4f4f4" : "";
      std::ostringstream csv;
      csv << "iu,iv,u_mm,v_mm,depth_mm,status\n";
      for (std::size_t k = 0; k < st.columns.size(); ++k) {
        if (c.depth_mm[k] >= 0.0) depth[k] = c.depth_mm[k];
        if (c.status[k].empty()) continue;
        char line[256];
        std::snprintf(line, sizeof(line), "%d,%d,%.4f,%.4f,%.5f,%s\n", st.columns[k].iu, st.columns[k].iv,
                      st.columns[k].u_mm, st.columns[k].v_mm, c.depth_mm[k] >= 0 ? c.depth_mm[k] : kNaN,
                      c.status[k].c_str());
        csv << blank_nans(line);
      }
      write_text(out_path(name + ".csv"), csv.str());
      std::vector<std::string> notes = {
          (cs.stamp.rigid ? "rigid" : "soft") + std::string(" stamp, ") + fmtd(cs.stamp.force_n, 1) +
              " N, width " + fmtd(c.stamp_width_mm, 1) + " mm, largest cell under it " +
              fmtd(c.local_cell_mm, 1) + " mm" + (c.narrow ? " - NARROWER THAN 3 CELLS (least accurate, R9)" : ""),
          "tier " + c.tier.tier + ", +/-" + fmtd(100 * c.tier.band, 0) +
              " % on depth; no sideways spreading: dents have sharper edges than real life (R9)"};
      notes.push_back("dark red: " + std::to_string(c.beyond_data_columns) +
                      " columns squished past the tested strain (no number, R8); pale: not under the stamp");
      if (!c.ok) notes.push_back("REFUSED: " + c.refusal.reason);
      write_text(out_path(name + ".svg"),
                 heatmap_svg(st, depth, "Check: \"" + cs.stamp.name + "\" on face " + std::to_string(cs.face_region_id) +
                                            " - dent depth",
                             notes, "mm", 2, &special));
      check_json.push_back(Obj()
                               .add("name", jstr(cs.stamp.name))
                               .add("stamp", stamp_json(cs.stamp))
                               .add("face_region_id", jnum(cs.face_region_id))
                               .add("mode", jstr(cs.stamp.rigid ? "rigid" : "soft"))
                               .add("force_n", jnum(cs.stamp.force_n))
                               .add("ok", jbool(c.ok))
                               .add("refusal", c.refusal.refused()
                                                   ? Obj().add("code", jstr(c.refusal.code))
                                                         .add("reason", jstr(c.refusal.reason)).str()
                                                   : "null")
                               .add("stamp_width_mm", jnum(c.stamp_width_mm))
                               .add("local_cell_mm", jnum(c.local_cell_mm))
                               .add("narrower_than_3_cells", jbool(c.narrow))
                               .add("pressed_columns", jnum(c.pressed_columns))
                               .add("extrapolated_columns", jnum(c.extrapolated_columns))
                               .add("beyond_data_columns", jnum(c.beyond_data_columns))
                               .add("rigid_unlatticed_columns", jnum(c.rigid_unlatticed_columns))
                               .add("max_depth_mm", jnum(c.max_depth_mm))
                               .add("rigid_depth_mm", cs.stamp.rigid && c.ok ? jnum(c.rigid_depth_mm) : "null")
                               .add("force_off_face_n", jnum(c.force_off_face_n))
                               .add("off_face", jbool(c.off_face))
                               .add("tier", Obj().add("tier", jstr(c.tier.tier)).add("band", jnum(c.tier.band)).str())
                               .str());
    }
    std::vector<int> ids;
    for (const JobFlexibleFace* f : loaded) ids.push_back(f->face_region_id);
    write_text(out_path("field_xz_density.svg"),
               field_slice_svg(field, false, "Density field - slice through the middle of the part (XZ)",
                               {"buildable core density per voxel, with the handover between stacks",
                                "blended over one cell of the larger local cell size (R11)"},
                               ids));
    write_text(out_path("field_xz_owner.svg"),
               field_slice_svg(field, true, "Which loaded face each voxel follows (XZ slice)",
                               {"nearest loaded face; the blend band is where two colours meet"}, ids));
  }

  // ── the receipt ──
  std::vector<std::string> resting;
  for (const JobFlexibleFace& f : fx.faces)
    if (f.role == "resting")
      resting.push_back(Obj().add("face_region_id", jnum(f.face_region_id)).add("skin_on", jbool(f.skin_on)).str());
  std::vector<std::string> hv, cf;
  for (const Handover& h : field.handovers)
    hv.push_back(Obj().add("face_a", jnum(h.face_a)).add("face_b", jnum(h.face_b))
                     .add("overlap_mm3", jnum(h.overlap_mm3)).add("blended_mm3", jnum(h.blended_mm3)).str());
  for (const StackConflict& c : conflicts)
    cf.push_back(Obj().add("face_a", jnum(c.face_a)).add("face_b", jnum(c.face_b))
                     .add("overlap_mm3", jnum(c.overlap_mm3)).add("axis_angle_deg", jnum(c.axis_angle_deg)).str());
  double dmin = 1e300, dmax = -1e300;
  for (double d : field.density)
    if (d > 0.0) {
      dmin = std::min(dmin, d);
      dmax = std::max(dmax, d);
    }
  const auto mat = data.catalogue.materials.find(fx.material_id);
  Obj r;
  r.add("stage", jstr("flexible"))
      .add("task", jstr("2026-09-28-flexible-squish-maths (C1)"))
      .add("model", jstr("lookup-and-invert over measured compression curves; NOT FEA, no certificate "
                         "(DECISIONS 2026-09-27 items 1-2)"))
      .add("refusal", refusal_code.empty() ? "null"
                                           : Obj().add("code", jstr(refusal_code)).add("reason", jstr(refusal_reason)).str())
      .add("material", Obj().add("id", jstr(fx.material_id))
                            .add("display_name", mat != data.catalogue.materials.end() ? jstr(mat->second.display_name) : "null")
                            .add("tier", mat != data.catalogue.materials.end() ? jstr(mat->second.tier) : "null")
                            .str())
      .add("tested_temperatures_c", jarr(tested_temperatures(data, fx.material_id)))
      .add("temperature_notes", [&] {
        Obj o;
        for (double t : tested_temperatures(data, fx.material_id)) {
          const std::string n = temperature_note(data, fx.material_id, t);
          if (!n.empty()) o.add(fmtd(t, 0), jstr(n));
        }
        return o.str();
      }())
      .add("recommendation", recommendation_json(rec, fx.topology,
                                                 fx.nozzle_temp_auto ? jstr("auto") : jnum(fx.nozzle_temp_c)))
      .add("topology", rec.chosen ? jstr(rec.topology) : "null")
      .add("nozzle_temp_c", rec.chosen ? jnum(rec.temp_c) : "null")
      .add("feel", jstr(fx.feel))
      .add("beads_per_wall", jnum(fx.beads_per_wall))
      .add("bead_width_mm", jnum(fx.min_extrudable_width_mm))
      .add("bead_width_key", jstr("min_extrudable_width_mm"))
      .add("wall_mm", jnum(fx.beads_per_wall * fx.min_extrudable_width_mm))
      .add("strain_convention", jstr(kStrainConvention))
      .add("density_basis", refusal_code.empty() ? jstr(set.density_basis) : "null")
      .add("table_density_range", refusal_code.empty() ? "[" + jnum(set.density_min()) + ", " + jnum(set.density_max()) + "]" : "null")
      .add("strain_zones", refusal_code.empty()
                               ? Obj().add("measured_to", jnum(set.strain_measured_max()))
                                     .add("extrapolated_to", jnum(set.strain_limit()))
                                     .add("refused_beyond", jnum(set.strain_limit())).str()
                               : "null")
      .add("error_band_defaults", Obj().add("literature_same_material", jnum(data.catalogue.error_bands.literature_same_material))
                                       .add("calibrated", jnum(data.catalogue.error_bands.calibrated))
                                       .add("proxy", jnum(data.catalogue.error_bands.proxy))
                                       .add("estimated", jnum(data.catalogue.error_bands.proxy))
                                       .add("status", jstr(data.catalogue.error_bands.status)).str())
      .add("buildable_smoothing", Obj().add("rule", jstr("clamp to the reachable range, then Gaussian sigma = 0.5 x local cell size (R14)"))
                                       .add("gyroid_cell", jstr("L = 3.0915 t / rho"))
                                       .add("honeycomb_cell", jstr("d = 2 t / rho"))
                                       .add("heuristic", jbool(true))
                                       .add("replaced_by", jstr("C2's realised lattice")).str())
      .add("build_direction", jvec(build))
      .add("resolution", jnum(job.resolution))
      .add("voxel_mm", jnum(grid.spacing))
      .add("column_pitch_mm", jnum(pitch))
      .add("lattice_region", Obj().add("regions", jlist([&] {
                                    std::vector<std::string> v;
                                    for (const JobLatticeRegion& g : fx.regions) v.push_back(region_json(g));
                                    return v;
                                  }()))
                                  .add("voxels", jnum(static_cast<double>(lattice_voxels)))
                                  .add("volume_mm3", jnum(lattice_voxels * grid.voxel_volume())).str())
      .add("faces", jlist(face_json))
      .add("resting_faces", jlist(resting))
      .add("conflicts", jlist(cf))
      .add("handover", jlist(hv))
      .add("field", refusal_code.empty()
                        ? Obj().add("lattice_voxels", jnum(static_cast<double>(field.lattice_voxels)))
                              .add("assigned_voxels", jnum(static_cast<double>(field.assigned_voxels)))
                              .add("unassigned_voxels", jnum(static_cast<double>(field.unassigned_voxels)))
                              .add("density_min", dmin <= dmax ? jnum(dmin) : "null")
                              .add("density_max", dmin <= dmax ? jnum(dmax) : "null").str()
                        : "null")
      .add("check_stamps", jlist(check_json))
      .add("not_modelled", jlist({jstr("loading rate"), jstr("creep and compression set"), jstr("fatigue"),
                                  jstr("temperature of use"),
                                  jstr("first-cycle stiffness: the tables are the 4th cycle; a new part is firmer for its first few squeezes"),
                                  jstr("sideways load spreading: dents have sharper edges than real life, and a small press on a big pad sinks less than shown"),
                                  jstr("buckling beyond what the curves hold"), jstr("skin bending")}));
  std::vector<std::string> files_j;
  for (const std::string& f : result.files) files_j.push_back(jstr(f));
  files_j.push_back(jstr("run_info.json"));
  r.add("files", jlist(files_j));
  result.receipt_json = r.str();
  result.refused = !refusal_code.empty();
  result.refusal_code = refusal_code;
  result.refusal_reason = refusal_reason;

  const std::string run_info =
      "{\n  \"cli_version\": " + jstr(provenance.cli_version) + ",\n  \"fingerprint\": " +
      jstr(provenance.fingerprint) + ",\n  \"build_time\": " + jstr(provenance.build_time) +
      ",\n  \"mode\": \"flexible\",\n  \"job_mode\": " + jstr(job.mode) + ",\n  \"material\": " +
      jstr(job.material) + ",\n  \"source_format\": " +
      jstr(job.source_format.empty() ? lower_ext(job.model) : job.source_format) +
      ",\n  \"resolution\": " + jnum(job.resolution) + ",\n  \"flexible\": " + result.receipt_json +
      "\n}\n";
  write_text(out_path("run_info.json"), run_info);
  return result;
}

}  // namespace topopt
