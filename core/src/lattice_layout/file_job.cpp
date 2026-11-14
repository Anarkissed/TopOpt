// Lattice rebuild: the lattice file job. See lattice_layout_file.hpp and
// docs/design/lattice-rebuild/04-layout-file-job.md.
#include "topopt/lattice_layout_file.hpp"

#include <chrono>
#include <cstdio>
#include <exception>
#include <fstream>
#include <sstream>
#include <utility>

#include "../flexible/json.hpp"        // the always-built strict JSON reader (no new parser)
#include "topopt/face_overrides.hpp"   // import_part_file_resolved
#include "topopt/lattice.hpp"          // lattice_topology_from_id, lattice_topology_is_sheet
#include "topopt/stl.hpp"

namespace topopt::lattice_layout {
namespace {
namespace json = topopt::flexible::json;

double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

// ── reading the job ───────────────────────────────────────────────────────────
double num(const json::Value& o, const char* key, double otherwise, const std::string& where) {
  const json::Value* v = json::find(o, key);
  return v ? json::as_number(*v, where + "." + key) : otherwise;
}
int whole(const json::Value& o, const char* key, int otherwise, const std::string& where) {
  const json::Value* v = json::find(o, key);
  return v ? json::as_int(*v, where + "." + key) : otherwise;
}
bool flag(const json::Value& o, const char* key, bool otherwise, const std::string& where) {
  const json::Value* v = json::find(o, key);
  return v ? json::as_bool(*v, where + "." + key) : otherwise;
}
std::string text(const json::Value& o, const char* key, const std::string& otherwise,
                 const std::string& where) {
  const json::Value* v = json::find(o, key);
  return v ? json::as_string(*v, where + "." + key) : otherwise;
}
std::vector<int> wholes(const json::Value& o, const char* key, const std::string& where) {
  std::vector<int> out;
  const json::Value* v = json::find(o, key);
  if (!v) return out;
  const std::string at = where + "." + key;
  for (const json::Value& e : json::as_array(*v, at).arr) out.push_back(json::as_int(e, at));
  return out;
}
std::vector<double> nums(const json::Value& o, const char* key, const std::string& where) {
  std::vector<double> out;
  const json::Value* v = json::find(o, key);
  if (!v) return out;
  const std::string at = where + "." + key;
  for (const json::Value& e : json::as_array(*v, at).arr) out.push_back(json::as_number(e, at));
  return out;
}
// A list of yes/no: true/false, or the bridge's own 1/0.
std::vector<bool> flags(const json::Value& o, const char* key, const std::string& where) {
  std::vector<bool> out;
  const json::Value* v = json::find(o, key);
  if (!v) return out;
  const std::string at = where + "." + key;
  for (const json::Value& e : json::as_array(*v, at).arr) {
    if (e.is_bool()) { out.push_back(e.boolean); continue; }
    const int n = json::as_int(e, at);
    if (n != 0 && n != 1) json::fail(at, "each entry must be true, false, 1 or 0");
    out.push_back(n == 1);
  }
  return out;
}

// A flattened list of lists, as the bridge sends it: item i's entries are counts[i]
// values of `values`, after the earlier items'.
std::vector<std::vector<int>> unflatten(const std::vector<int>& counts, const std::vector<int>& values,
                                        const std::string& what) {
  std::vector<std::vector<int>> out;
  std::size_t at = 0;
  for (int c : counts) {
    if (c < 0 || at + static_cast<std::size_t>(c) > values.size())
      json::fail(what, "the face counts run past the faces listed");
    out.emplace_back(values.begin() + static_cast<long>(at), values.begin() + static_cast<long>(at + c));
    at += static_cast<std::size_t>(c);
  }
  if (at != values.size()) json::fail(what, "faces are listed that no count claims");
  return out;
}

Algorithm algorithm_from(const std::string& s, const std::string& where) {
  if (s == "uniform") return Algorithm::Uniform;
  if (s == "default_grade") return Algorithm::DefaultGrade;
  if (s == "stepped") return Algorithm::Stepped;
  json::fail(where, "unknown algorithm \"" + s + "\" (uniform | default_grade | stepped)");
}

// The bridge's LatticeLayoutSettings, key for key (lattice_layout_bridge.cpp, settings_from),
// and two more that core's Settings has: small_cells_in_thin_walls and one_grid ("Let walls cut cells").
Settings settings_from(const json::Value& in, const std::string& w) {
  json::reject_unknown(
      in,
      {"all_lattice", "bead_mm", "min_strut_lines", "min_wall_mm", "rim_mm", "cover_mm",
       "region_ids", "region_no_lattice", "region_depth_mm", "region_expand_mm",
       "region_face_counts", "region_faces", "protect_ids", "protect_depth_mm",
       "protect_face_counts", "protect_faces", "topology", "algorithm", "cell_mm", "cell_max_mm",
       "cell_min_mm", "min_cells_across", "grade_to_shape", "band_mm", "band_cell_mm",
       "per_region", "dial", "dial_region", "dial_value", "strut_width_mm", "allow_quilt",
       "strength", "small_cells_in_thin_walls", "one_grid", "bars", "join_loose", "skin", "skin_width_mm",
       "skin_reach_cells", "drop_loose"},
      w);
  Settings s;
  s.start = flag(in, "all_lattice", false, w) ? Start::AllLattice : Start::AllSolid;
  s.bead_mm = num(in, "bead_mm", s.bead_mm, w);
  s.min_strut_lines = num(in, "min_strut_lines", s.min_strut_lines, w);
  s.min_wall_mm = num(in, "min_wall_mm", s.min_wall_mm, w);
  s.rim_mm = num(in, "rim_mm", s.rim_mm, w);
  s.cover_mm = num(in, "cover_mm", s.cover_mm, w);

  const std::vector<int> ids = wholes(in, "region_ids", w);
  const std::vector<bool> no_lattice = flags(in, "region_no_lattice", w);
  const std::vector<double> depth = nums(in, "region_depth_mm", w);
  const std::vector<double> expand = nums(in, "region_expand_mm", w);
  const std::vector<int> counts = wholes(in, "region_face_counts", w);
  const std::size_t nr = ids.size();
  if (no_lattice.size() != nr || depth.size() != nr || expand.size() != nr || counts.size() != nr)
    json::fail(w, "the region lists (region_ids, region_no_lattice, region_depth_mm, "
                  "region_expand_mm, region_face_counts) are not all one length");
  const auto rf = unflatten(counts, wholes(in, "region_faces", w), w + ".region_faces");
  for (std::size_t r = 0; r < nr; ++r) {
    Settings::RegionAsk a;
    a.id = ids[r];
    a.role = no_lattice[r] ? Role::NoLattice : Role::Lattice;
    a.faces = rf[r];
    a.depth_mm = depth[r];
    a.expand_mm = expand[r];
    s.regions.push_back(std::move(a));
  }
  const std::vector<int> pids = wholes(in, "protect_ids", w);
  const std::vector<double> pdepth = nums(in, "protect_depth_mm", w);
  const std::vector<int> pcounts = wholes(in, "protect_face_counts", w);
  const std::size_t np = pids.size();
  if (pdepth.size() != np || pcounts.size() != np)
    json::fail(w, "the Protect skin lists (protect_ids, protect_depth_mm, protect_face_counts) "
                  "are not all one length");
  const auto pf = unflatten(pcounts, wholes(in, "protect_faces", w), w + ".protect_faces");
  for (std::size_t p = 0; p < np; ++p) s.protect.push_back({pids[p], pf[p], pdepth[p]});

  s.cells.algorithm = algorithm_from(text(in, "algorithm", "default_grade", w), w + ".algorithm");
  try {
    s.cells.topology = lattice_topology_from_id(text(in, "topology", "octet", w));
  } catch (const std::exception& e) {
    json::fail(w + ".topology", e.what());
  }
  s.cells.cell_mm = num(in, "cell_mm", s.cells.cell_mm, w);
  s.cells.cell_max_mm = num(in, "cell_max_mm", s.cells.cell_max_mm, w);
  s.cells.cell_min_mm = num(in, "cell_min_mm", s.cells.cell_min_mm, w);
  s.cells.min_cells_across = whole(in, "min_cells_across", s.cells.min_cells_across, w);
  s.cells.grade_to_shape = flag(in, "grade_to_shape", s.cells.grade_to_shape, w);
  s.cells.band_mm = num(in, "band_mm", s.cells.band_mm, w);
  s.cells.band_cell_mm = num(in, "band_cell_mm", s.cells.band_cell_mm, w);

  s.struts.mode = flag(in, "per_region", false, w) ? Density::PerRegion : Density::Uniform;
  s.struts.dial = num(in, "dial", s.struts.dial, w);
  const std::vector<int> dial_region = wholes(in, "dial_region", w);
  const std::vector<double> dial_value = nums(in, "dial_value", w);
  if (dial_region.size() != dial_value.size())
    json::fail(w, "dial_region and dial_value are not one length");
  for (std::size_t i = 0; i < dial_region.size(); ++i)
    s.struts.region_dial.push_back({dial_region[i], dial_value[i]});
  s.struts.width_mm = num(in, "strut_width_mm", s.struts.width_mm, w);
  s.struts.allow_quilt = flag(in, "allow_quilt", s.struts.allow_quilt, w);
  s.struts.strength = num(in, "strength", s.struts.strength, w);
  s.small_cells_in_thin_walls = flag(in, "small_cells_in_thin_walls", s.small_cells_in_thin_walls, w);
  s.one_grid = flag(in, "one_grid", s.one_grid, w);

  s.bars = flag(in, "bars", s.bars, w);
  s.join_loose = flag(in, "join_loose", s.join_loose, w);
  s.skin = flag(in, "skin", s.skin, w);
  s.skin_spec.width_mm = num(in, "skin_width_mm", s.skin_spec.width_mm, w);
  s.skin_spec.reach_cells = num(in, "skin_reach_cells", s.skin_spec.reach_cells, w);
  s.drop_loose = flag(in, "drop_loose", s.drop_loose, w);
  return s;
}

FileOptions options_from(const json::Value& in, const std::string& w) {
  json::reject_unknown(in,
                       {"pitch_mm", "bar_sides", "block_mm", "grow_mm", "clean_mm", "part_mm",
                        "fill_under_mm3", "bridge_rise", "post_mm", "layer_mm", "pixel_mm", "most_passes",
                        "leave_out", "keep_if_not_clean"},
                       w);
  FileOptions o;
  o.pitch_mm = num(in, "pitch_mm", o.pitch_mm, w);
  o.mesh.bar_sides = whole(in, "bar_sides", o.mesh.bar_sides, w);
  o.mesh.block_mm = num(in, "block_mm", o.mesh.block_mm, w);
  o.mesh.grow_mm = num(in, "grow_mm", o.mesh.grow_mm, w);
  o.mesh.clean_mm = num(in, "clean_mm", o.mesh.clean_mm, w);
  o.mesh.part_mm = num(in, "part_mm", o.mesh.part_mm, w);
  o.mesh.fill_under_mm3 = num(in, "fill_under_mm3", o.mesh.fill_under_mm3, w);
  o.mesh.bridge_rise = num(in, "bridge_rise", o.mesh.bridge_rise, w);
  o.mesh.post_mm = num(in, "post_mm", o.mesh.post_mm, w);
  o.layers.layer_mm = num(in, "layer_mm", o.layers.layer_mm, w);
  o.layers.pixel_mm = num(in, "pixel_mm", o.layers.pixel_mm, w);
  o.most_passes = whole(in, "most_passes", o.most_passes, w);
  o.leave_out = flag(in, "leave_out", o.leave_out, w);
  o.keep_if_not_clean = flag(in, "keep_if_not_clean", o.keep_if_not_clean, w);
  if (!(o.layers.layer_mm > 0.0)) json::fail(w + ".layer_mm", "must be above 0");
  if (!(o.layers.pixel_mm > 0.0)) json::fail(w + ".pixel_mm", "must be above 0");
  if (o.most_passes < 1) json::fail(w + ".most_passes", "must be 1 or more");
  if (!(o.pitch_mm > 0.0)) json::fail(w + ".pitch_mm", "must be above 0");
  if (o.mesh.bar_sides < 3) json::fail(w + ".bar_sides", "must be 3 or more");
  if (!(o.mesh.block_mm > 0.0)) json::fail(w + ".block_mm", "must be above 0");
  return o;
}

// ── the result ────────────────────────────────────────────────────────────────
struct Refusal {
  const char* code;
  int exit_code;
};
// 3 = the part or the settings cannot give a file (the maker can change them);
// 1 = anything else.
constexpr Refusal kJobUnreadable{"job_unreadable", 1};
constexpr Refusal kModelUnreadable{"model_unreadable", 3};
constexpr Refusal kModelEmpty{"model_empty", 3};
constexpr Refusal kPartNotClosed{"part_not_closed", 3};
constexpr Refusal kRegionFacesMissing{"region_faces_missing", 3};
constexpr Refusal kProtectFacesMissing{"protect_faces_missing", 3};
constexpr Refusal kTypeNotSupported{"type_not_supported", 3};
constexpr Refusal kNoCells{"no_cells", 3};
constexpr Refusal kNoStruts{"no_struts", 3};
constexpr Refusal kMeshUnavailable{"mesh_unavailable", 3};
constexpr Refusal kMeshFailed{"mesh_failed", 1};
// The file would have something starting in mid-air when printed (his rule P8 b): not written.
constexpr Refusal kWouldNotPrint{"would_not_print", 3};
constexpr Refusal kCannotWrite{"cannot_write", 1};
constexpr Refusal kCancelled{"cancelled", 1};
constexpr Refusal kError{"error", 1};

void refuse(FileResult& r, const Refusal& which, const std::string& why, const std::string& detail = {}) {
  r.ok = false;
  r.code = which.code;
  r.exit_code = which.exit_code;
  r.why = why;
  r.detail = detail;
}

// "3", "3 and 5", "3, 5 and 9".
std::string listed(const std::vector<int>& ids) {
  std::string out;
  for (std::size_t i = 0; i < ids.size(); ++i) {
    if (i) out += i + 1 == ids.size() ? " and " : ", ";
    out += std::to_string(ids[i]);
  }
  return out;
}
std::string faces_missing(const char* one, const char* many, const std::vector<int>& ids) {
  const bool single = ids.size() == 1;
  return std::string(single ? one : many) + " " + listed(ids) +
         (single ? " points at faces this part does not have. Pick its faces again."
                 : " point at faces this part does not have. Pick their faces again.");
}

std::string escaped(const std::string& in) {
  std::string out;
  for (const char c : in) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char b[8];
          std::snprintf(b, sizeof b, "\\u%04x", static_cast<unsigned>(c));
          out += b;
        } else {
          out += c;
        }
    }
  }
  return out;
}
std::string base_name(const std::string& path) {
  const std::string::size_type slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}
std::string folder_of(const std::string& path) {
  const std::string::size_type slash = path.find_last_of('/');
  if (slash == std::string::npos) return ".";
  if (slash == 0) return "/";
  return path.substr(0, slash);
}
std::size_t size_of_file(const std::string& path) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  return f ? static_cast<std::size_t>(f.tellg()) : 0;
}
void say(void (*said)(const char*), const char* line) {
  if (said) said(line);
}
}  // namespace

// ── THE ONE PLACE THE MESH IS MADE ────────────────────────────────────────────
// (LatticeReview's build-and-check-the-layers loop replaces this body.)
TriangleMesh make_file_mesh(const Session& session, const Outcome& outcome, const FileOptions& options,
                            FileReport& report, const std::atomic<bool>* stop) {
  report = FileReport{};
  const Domain* domain = session.domain();
  if (!domain) {
    report.mesh.why = "The lattice was not laid before its file was asked for.";
    return TriangleMesh{};
  }
  const OpenSpace open = read_open_space(*domain, outcome.layout, options.pitch_mm, options.threads, stop);
  report.open_boxes = open.boxes.size();
  report.ms_open_space = open.ms;
  // Made, checked layer by layer, and made again until it prints (P8).
  PrintableSpec spec;
  spec.mesh = options.mesh;
  spec.mesh.threads = options.threads;
  spec.mesh.stop = stop;
  spec.layers = options.layers;
  spec.layers.threads = options.threads;
  spec.layers.stop = stop;
  spec.most_passes = options.most_passes;
  spec.leave_out = options.leave_out;
  PrintableReport made;
  TriangleMesh mesh = build_printable_mesh(session.measure(), *domain, outcome.layout, outcome.bars, open, spec, &made);
  report.mesh = made.mesh;
  report.builds = made.passes;
  report.ms_carve = made.ms_carve;
  report.layers = made.layers;
  report.print_clean = made.clean;
  report.found_per_pass = made.found_per_pass;
  report.left_out_at = made.drop_at;
  report.posts = made.posts;
  if (made.mesh.ok) {
    report.bed_contact_mm2 = made.layers.bed_mm2;
    report.midair_starts = static_cast<int>(made.layers.mid_air.size());
  }
  return mesh;
}

FileJob parse_file_job(const std::string& json_text) {
  try {
    const json::Value doc = json::parse(json_text, "job.json");
    const std::string w = "job.json";
    json::as_object(doc, w);
    json::reject_unknown(doc, {"mode", "model", "output", "linear_deflection", "threads", "layout", "mesh"}, w);
    const std::string mode = json::as_string(json::require(doc, "mode", w), w + ".mode");
    if (mode != "lattice_file") json::fail(w + ".mode", "must be \"lattice_file\", not \"" + mode + "\"");
    FileJob job;
    job.model = json::as_string(json::require(doc, "model", w), w + ".model");
    if (job.model.empty()) json::fail(w + ".model", "must name the part's file");
    job.output = text(doc, "output", job.output, w);
    // A bare file name: the STL always lands in the output folder, wherever the job came from.
    if (job.output.empty() || job.output == "." || job.output == ".." ||
        job.output.find_first_of("/\\") != std::string::npos)
      json::fail(w + ".output", "must be a file name with no folder in it");
    if (job.output == kFileResultName) json::fail(w + ".output", "is the result file's own name");
    job.linear_deflection = num(doc, "linear_deflection", 0.0, w);
    if (const json::Value* v = json::find(doc, "layout"))
      job.settings = settings_from(json::as_object(*v, w + ".layout"), w + ".layout");
    if (const json::Value* v = json::find(doc, "mesh"))
      job.options = options_from(json::as_object(*v, w + ".mesh"), w + ".mesh");
    job.options.threads = whole(doc, "threads", 0, w);
    if (job.options.threads < 0) json::fail(w + ".threads", "must be 0 (every core) or more");
    return job;
  } catch (const FileJobError&) {
    throw;
  } catch (const std::exception& e) {
    throw FileJobError(e.what());
  }
}

FileResult make_lattice_file(StepModel model, const FileJob& job, const std::string& stl_path,
                             const std::atomic<bool>* stop, void (*said)(const char*)) {
  FileResult r;
  const auto t_all = std::chrono::steady_clock::now();
  const auto done = [&]() -> FileResult& {
    r.ms_total += ms_since(t_all);
    return r;
  };
  try {
    r.faces = model.face_count;
    r.part_triangles = model.mesh.triangles.size();
    if (model.mesh.triangles.empty()) {
      refuse(r, kModelEmpty, "The part's file has no surface in it, so there is nothing to put lattice in.");
      return done();
    }
    // Before the long work: the faces every region and Protect skin names must be the part's.
    {
      std::vector<int> regions, skins;
      for (const Settings::RegionAsk& a : job.settings.regions)
        if (faces_mesh(model, a.faces).triangles.empty()) regions.push_back(a.id);
      for (const Settings::ProtectAsk& a : job.settings.protect)
        if (faces_mesh(model, a.faces).triangles.empty()) skins.push_back(a.id);
      if (!regions.empty()) {
        r.empty_regions = regions;
        refuse(r, kRegionFacesMissing, faces_missing("Region", "Regions", regions));
        return done();
      }
      if (!skins.empty()) {
        refuse(r, kProtectFacesMissing, faces_missing("Protect skin", "Protect skins", skins));
        return done();
      }
    }
    if (lattice_topology_is_sheet(job.settings.cells.topology)) {
      refuse(r, kTypeNotSupported,
             "This lattice type is made of sheets, and a lattice file can only be made from the "
             "types made of struts so far. Pick a strut type.");
      return done();
    }
    if (!mesh_available()) {
      refuse(r, kMeshUnavailable,
             "The worker on the Mac was built without the part that makes lattice files, so it "
             "cannot make one. Update the worker.");
      return done();
    }

    say(said, "measuring the part");
    auto t0 = std::chrono::steady_clock::now();
    Session session(std::move(model));
    r.ms_measure = ms_since(t0);
    r.open_edges = session.open_edges();
    if (r.open_edges != 0) {
      refuse(r, kPartNotClosed,
             "The part's surface has gaps in it (" + std::to_string(r.open_edges) +
                 (r.open_edges == 1 ? " open edge" : " open edges") +
                 "), so its inside cannot be told from its outside. Repair the model and send it again.");
      return done();
    }

    say(said, "laying the lattice");
    const Outcome out = session.lay(job.settings, job.options.threads, stop);
    if (out.cancelled) {
      refuse(r, kCancelled, "Stopped before the lattice file was finished. Nothing was made.");
      return done();
    }
    r.cells = out.layout.cells.size();
    r.solid_pieces = out.layout.solid.size();
    r.bars = out.bars.bars.size();
    r.at_one_line = out.struts.at_bead;
    r.at_widest = out.struts.at_ceiling;
    r.stubs = out.bars.stubs;
    r.joined = out.bars.joined;
    r.dropped = out.bars.dropped;
    r.pieces = out.pieces.pieces;
    r.adrift = out.pieces.adrift;
    r.stepped_edges = out.stepped_edges.size();
    r.floor_cell_mm = out.layout.floor_cell_mm;
    r.min_strut_mm = out.layout.min_strut_mm;
    r.open_look = out.layout.open_look;
    r.touch = out.layout.touch;
    r.empty_regions = out.empty_regions;
    r.ms_read = out.ms_read;
    r.ms_cells = out.ms_cells;
    r.ms_bars = out.ms_bars;
    if (!out.empty_regions.empty()) {
      refuse(r, kRegionFacesMissing, faces_missing("Region", "Regions", out.empty_regions));
      return done();
    }
    if (out.layout.cells.empty()) {
      refuse(r, kNoCells,
             "No lattice cell fits anywhere in this part with these settings, so there is no lattice "
             "to make. Try a smaller cell, a deeper region, or more of the part.");
      return done();
    }
    if (out.bars.bars.empty()) {
      refuse(r, kNoStruts,
             "The lattice here has no struts left to print, so no file was made. Try a smaller cell "
             "or a deeper region.");
      return done();
    }

    say(said, "making the file");
    const TriangleMesh mesh = make_file_mesh(session, out, job.options, r.made, stop);
    if (!r.made.mesh.ok || mesh.empty()) {
      refuse(r, kMeshFailed,
             r.made.mesh.why.empty() ? "The lattice file could not be put together. Nothing was made."
                                     : r.made.mesh.why);
      return done();
    }
    if (!r.made.print_clean && !job.options.keep_if_not_clean) {
      const std::size_t mid = r.made.layers.mid_air.size(), one = r.made.layers.one_ended.size(),
                        far = r.made.layers.long_bridges.size();
      char line[320];
      std::snprintf(line, sizeof line,
                    "After %d tries the lattice still has %zu place%s that would start printing in mid-air, %zu overhang%s "
                    "held at one end only and %zu bridge%s longer than a printer can span. No file was made. A larger cell "
                    "or a Protect skin near those places usually fixes it.",
                    r.made.builds, mid, mid == 1 ? "" : "s", one, one == 1 ? "" : "s", far, far == 1 ? "" : "s");
      refuse(r, kWouldNotPrint, line);
      return done();
    }

    say(said, "saving the file");
    t0 = std::chrono::steady_clock::now();
    // Written beside its target and moved in only when whole: a failed job never leaves
    // half a file, nor replaces an earlier good one.
    const std::string part = stl_path + ".part";
    const std::size_t want = 84 + 50 * mesh.triangles.size();
    bool written = false;
    std::string write_detail;
    try {
      write_stl_file(part, mesh, StlFormat::Binary);
      written = size_of_file(part) == want;
      if (!written) write_detail = "the file is not the size its triangles need";
    } catch (const std::exception& e) {
      write_detail = e.what();
    }
    if (written && std::rename(part.c_str(), stl_path.c_str()) != 0) {
      written = false;
      write_detail = "cannot move the file into " + stl_path;
    }
    r.ms_write = ms_since(t0);
    if (!written) {
      std::remove(part.c_str());
      refuse(r, kCannotWrite,
             "The lattice file could not be saved on the Mac (the folder is missing or the disk is full).",
             write_detail);
      return done();
    }
    r.file = stl_path;
    r.file_bytes = want;
    r.ok = true;
    r.code = "ok";
    r.exit_code = 0;
  } catch (const LayCancelled&) {
    refuse(r, kCancelled, "Stopped before the lattice file was finished. Nothing was made.");
  } catch (const std::exception& e) {
    refuse(r, kError, "Something went wrong while making the lattice file, and nothing was made.", e.what());
  } catch (...) {
    refuse(r, kError, "Something went wrong while making the lattice file, and nothing was made.");
  }
  return done();
}

FileResult run_file_job(const std::string& job_path, const std::string& out_dir, int threads,
                        void (*said)(const char*)) {
  FileResult r;
  const auto t_all = std::chrono::steady_clock::now();
  const auto run = [&] {
    FileJob job;
    {
      std::ifstream f(job_path, std::ios::binary);
      if (!f) {
        refuse(r, kJobUnreadable, "The lattice job could not be opened on the Mac, so nothing was made.",
               "cannot open " + job_path);
        return;
      }
      std::ostringstream all;
      all << f.rdbuf();
      try {
        job = parse_file_job(all.str());
      } catch (const std::exception& e) {
        refuse(r, kJobUnreadable,
               "The lattice job sent to the Mac could not be read, so nothing was made.", e.what());
        return;
      }
    }
    if (threads > 0) job.options.threads = threads;
    const std::string model_path =
        !job.model.empty() && job.model[0] == '/' ? job.model : folder_of(job_path) + "/" + job.model;
    say(said, "opening the part");
    const auto t0 = std::chrono::steady_clock::now();
    StepModel model;
    try {
      StepTessellation tess;
      if (job.linear_deflection > 0.0) tess.linear_deflection = job.linear_deflection;
      model = import_part_file_resolved(model_path, tess);
    } catch (const std::exception& e) {
      refuse(r, kModelUnreadable,
             "The part's file could not be opened on the Mac, so no lattice file was made.", e.what());
      return;
    } catch (...) {
      refuse(r, kModelUnreadable,
             "The part's file could not be opened on the Mac, so no lattice file was made.");
      return;
    }
    const double ms_import = ms_since(t0);
    r = make_lattice_file(std::move(model), job, out_dir + "/" + job.output, nullptr, said);
    r.ms_import = ms_import;
  };
  run();
  r.ms_total = ms_since(t_all);
  // The result file, whatever happened.
  const std::string result_path = out_dir + "/" + kFileResultName;
  std::ofstream f(result_path, std::ios::binary | std::ios::trunc);
  f << file_result_json(r);
  f.close();
  if (!f && r.ok) {
    std::remove(r.file.c_str());
    refuse(r, kCannotWrite,
           "The lattice file could not be saved on the Mac (the folder is missing or the disk is full).",
           "cannot write " + result_path);
    r.file.clear();
    r.file_bytes = 0;
  }
  return r;
}

std::string file_result_json(const FileResult& r) {
  std::string o;
  char b[512];
  const auto count = [](std::size_t n) { return static_cast<unsigned long long>(n); };
  o += "{\n";
  o += std::string("  \"ok\": ") + (r.ok ? "true" : "false") + ",\n";
  o += "  \"code\": \"" + escaped(r.code) + "\",\n";
  o += "  \"why\": \"" + escaped(r.why) + "\",\n";
  o += "  \"detail\": \"" + escaped(r.detail) + "\",\n";
  o += "  \"file\": \"" + escaped(base_name(r.file)) + "\",\n";
  std::snprintf(b, sizeof b, "  \"file_bytes\": %llu,\n", count(r.file_bytes));
  o += b;
  std::snprintf(b, sizeof b, "  \"part\": {\"faces\": %d, \"triangles\": %llu, \"open_edges\": %llu},\n",
                r.faces, count(r.part_triangles), count(r.open_edges));
  o += b;
  std::snprintf(b, sizeof b,
                "  \"layout\": {\"cells\": %llu, \"solid_pieces\": %llu, \"bars\": %llu, "
                "\"at_one_line\": %llu, \"at_widest\": %llu, \"stubs\": %llu, \"joined\": %llu, "
                "\"dropped\": %llu, \"pieces\": %llu, \"adrift\": %llu, \"stepped_edges\": %llu,\n",
                count(r.cells), count(r.solid_pieces), count(r.bars), count(r.at_one_line),
                count(r.at_widest), count(r.stubs), count(r.joined), count(r.dropped), count(r.pieces),
                count(r.adrift), count(r.stepped_edges));
  o += b;
  std::snprintf(b, sizeof b,
                "    \"floor_cell_mm\": %.9g, \"min_strut_mm\": %.9g, \"open_look\": %.9g, "
                "\"touch\": %.9g, \"empty_regions\": [",
                r.floor_cell_mm, r.min_strut_mm, r.open_look, r.touch);
  o += b;
  for (std::size_t i = 0; i < r.empty_regions.size(); ++i)
    o += (i ? ", " : "") + std::to_string(r.empty_regions[i]);
  o += "]},\n";
  const MeshReport& m = r.made.mesh;
  std::snprintf(b, sizeof b,
                "  \"mesh\": {\"triangles\": %llu, \"mm3\": %.9g, \"part_mm3\": %.9g, \"struts_mm3\": %.9g, "
                "\"solid_mm3\": %.9g, \"bars\": %llu, \"bridges\": %llu, \"balls\": %llu,\n",
                count(m.triangles), m.mm3, m.part_mm3, m.struts_mm3, m.solid_mm3, count(m.bars),
                count(m.bridges), count(m.balls));
  o += b;
  std::snprintf(b, sizeof b,
                "    \"bars_left_out\": %llu, \"bars_left_out_mm\": %.9g, \"drop_unanswered\": %llu, "
                "\"posts\": %llu, \"posts_mm\": %.9g, \"solid_pieces\": %llu,\n",
                count(m.bars_left_out), m.bars_left_out_mm, count(m.drop_unanswered), count(m.posts),
                m.posts_mm, count(m.solid_pieces));
  o += b;
  std::snprintf(b, sizeof b,
                "    \"slivers_left_out\": %llu, \"slivers_mm3\": %.9g, \"touching_places\": %llu, "
                "\"air_pockets\": %llu, \"air_pockets_mm3\": %.9g, \"sealed_spaces\": %llu,\n",
                count(m.slivers_left_out), m.slivers_mm3, count(m.touching_places), count(m.air_pockets),
                m.air_pockets_mm3, count(m.sealed_spaces));
  o += b;
  std::snprintf(b, sizeof b,
                "    \"loose_bits\": %llu, \"loose_mm3\": %.9g, \"flat_triangles\": %llu, "
                "\"open_boxes\": %llu, \"builds\": %d},\n",
                count(m.loose_bits), m.loose_mm3, count(m.flat_triangles), count(r.made.open_boxes),
                r.made.builds);
  o += b;
  {
    // His print rules, as measured on the mesh the file holds, and what the loop did to get there.
    const LayerReport& l = r.made.layers;
    std::snprintf(b, sizeof b,
                  "  \"print_check\": {\"bed_contact_mm2\": %.9g, \"midair_starts\": %d, \"clean\": %s, \"passes\": %d,\n"
                  "    \"one_ended\": %llu, \"long_bridges\": %llu, \"longest_bridge_reach_mm\": %.9g, \"bed_flat\": %s, \"first_layer_mm2\": %.9g, "
                  "\"sloped_underside_mm2\": %.9g,\n    \"layers\": %d, \"thin_islands\": %llu, \"thin_layers\": %d,\n",
                  r.made.bed_contact_mm2, r.made.midair_starts, r.made.print_clean ? "true" : "false", r.made.builds,
                  count(l.one_ended.size()), count(l.long_bridges.size()), l.longest_reach_mm, l.bed_flat() ? "true" : "false", l.first_layer_mm2,
                  l.sloped_mm2, l.layers, count(l.thin_islands), l.thin_layers);
    o += b;
    o += "    \"found_per_pass\": [";
    for (std::size_t i = 0; i < r.made.found_per_pass.size(); ++i) {
      std::snprintf(b, sizeof b, "%s%d", i ? ", " : "", r.made.found_per_pass[i]);
      o += b;
    }
    o += "],\n    \"left_out_at\": [";
    for (std::size_t i = 0; i < r.made.left_out_at.size(); ++i) {
      const Vec3& p = r.made.left_out_at[i];
      std::snprintf(b, sizeof b, "%s[%.4f, %.4f, %.4f]", i ? ", " : "", p.x, p.y, p.z);
      o += b;
    }
    o += "],\n    \"posts\": [";
    for (std::size_t i = 0; i < r.made.posts.size(); ++i) {
      const MeshSpec::Post& p = r.made.posts[i];
      std::snprintf(b, sizeof b, "%s[%.4f, %.4f, %.4f, %.4f]", i ? ", " : "", p.x, p.y, p.z_bottom, p.z_top);
      o += b;
    }
    o += "]},\n";
  }
  std::snprintf(b, sizeof b,
                "  \"ms\": {\"import\": %.1f, \"measure\": %.1f, \"read\": %.1f, \"cells\": %.1f, "
                "\"bars\": %.1f, \"open_space\": %.1f, \"carve\": %.1f, \"struts\": %.1f, \"solid\": %.1f, "
                "\"finish\": %.1f, \"write\": %.1f, \"total\": %.1f}\n",
                r.ms_import, r.ms_measure, r.ms_read, r.ms_cells, r.ms_bars, r.made.ms_open_space, r.made.ms_carve,
                m.ms_struts, m.ms_solid, m.ms_finish, r.ms_write, r.ms_total);
  o += b;
  o += "}\n";
  return o;
}

}  // namespace topopt::lattice_layout
