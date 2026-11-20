// Lattice rebuild: THE LATTICE FILE JOB (docs/design/lattice-rebuild/04-layout-file-job.md).
//
// The app draws the lattice from the layout on the device. The printable file is made
// from the SAME layout on the Mac: the worker runs `topopt-cli lattice-file job.json`,
// which opens the part, lays it with the settings the app sent (the fields of the
// bridge's LatticeLayoutSettings, under the same names), makes the mesh from the layout
// (lattice_layout_mesh.hpp) and writes a binary STL with a small result file beside it.
//
// Every way it can fail ends in ONE plain line a maker can read (`FileResult::why`),
// never a half-written file: the STL is written beside its target and moved in only when
// it is whole.
//
// Nothing here changes the layout engine or any other job. Always built (no OCCT, no
// Eigen of its own); a STEP model needs a build with OCCT, as everywhere else.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"

namespace topopt::lattice_layout {

// The writer's settings a file job starts from: MeshSpec's, with the blended foot on (O11: half the bar's width, for
// a weave's ends in the solid) and the round top on a weave's shallow struts (O14); nothing else changes.
inline MeshSpec file_mesh_defaults() {
  MeshSpec m;
  m.weave_foot_mm = -1.0;
  m.weave_round_top = true;
  return m;
}

// How the mesh is made from a layout.
struct FileOptions {
  double pitch_mm = 0.25;   // how finely each cell's shape is read (read_open_space)
  MeshSpec mesh = file_mesh_defaults();   // its `threads` and `stop` are set from the two below
  int threads = 0;          // 0 = every core
  // His print rules (P8): the mesh is made, checked layer by layer and made again until
  // nothing starts in mid-air (build_printable_mesh). A file that still has such a place
  // after `most_passes` is NOT written, unless `keep_if_not_clean` (for looking at it).
  LayerSpec layers;
  int most_passes = 10;
  bool leave_out = true;
  bool keep_if_not_clean = false;
  // OF4: mesh key "weave_mesh" ("tubes" or "merged"). Not given: Tubes for a job with a weave region (make_lattice_file
  // sets mesh.weave_mesh), the writer's own Merged otherwise (a job with no weave region is never changed by it).
  bool weave_mesh_asked = false;
};

// What making the mesh found.
struct FileReport {
  MeshReport mesh;              // of the mesh returned (the last build)
  std::size_t open_boxes = 0;   // the open space read from the cells
  double ms_open_space = 0.0;
  double ms_carve = 0.0;        // the part less the open space, carved once for every build
  int builds = 0;               // how many times the mesh was built
  // His print rules (a) and (b) of 2026-11-12, as measured on the mesh returned:
  // the bridge's LatticeLayoutResult carries the same two. -1 = not measured.
  double bed_contact_mm2 = -1.0;
  int midair_starts = -1;
  // The layer check of the mesh returned, and what the make-check-make loop did.
  LayerReport layers;
  bool print_clean = false;          // nothing starts in mid-air, nothing is held at one end only
  std::vector<int> found_per_pass;   // mid-air starts + one-ended overhangs, pass by pass
  std::vector<Vec3> left_out_at;     // where struts were left out (the preview can mark them)
  // OG2c (brief E6, leg C): PrintableReport's findings_at, relief_flushed, relief_rounds.
  std::vector<Vec3> findings_at;
  std::size_t relief_flushed = 0;
  int relief_rounds = 0;
  std::vector<std::array<Vec3, 2>> relief_flushed_at;   // OJ6: the bars made flush (their ends as given)
  std::vector<MeshSpec::Post> posts; // the posts added (the preview can draw them)
  std::size_t stands_added = 0;      // of `posts`, those under a weave's long shallow runs (O8)
  std::size_t weave_specks_ignored = 0, weave_held_ignored = 0;   // O10: PrintableReport's
  std::size_t part_overhangs = 0;   // PrintableReport's: the part's own overhangs, counted, never propped
  // O17, O18: PrintableReport's: what the sag pass did, and the bars the file was made of when it changed any (null:
  // the layout's own). `left_out_at` and `posts` are read against those.
  SagReport sags;
  std::shared_ptr<const Bars> sagged;
  // OF4: PrintableReport's: the tubes route was taken, its shells' counts, where the solid's triangles end and each
  // shell's first triangle in the mesh returned, how often the solid was made.
  bool tubes = false;
  WeaveShells shells;
  std::size_t base_triangles = 0;
  std::vector<std::size_t> shell_first_tri;
  int base_builds = 0;
  double ms_shells = 0.0;
  std::vector<PrintableReport::PassTime> pass_ms;   // OF4: per pass of the tubes route
};

// THE ONE PLACE THE MESH IS MADE for a file: the open space of the layout's cells, then
// the mesh of the layout and its bars in the part. `session` is the one `outcome` was
// laid by, and has not been laid again since (its domain is the outcome's).
// A stop flag (`stop`, when given) gives the work up by throwing LayCancelled.
// The mesh is empty and `report.mesh.why` says why when it cannot be made.
TriangleMesh make_file_mesh(const Session& session, const Outcome& outcome,
                            const FileOptions& options, FileReport& report,
                            const std::atomic<bool>* stop = nullptr);
// The same, of `bars` laid in `layout` (make_file_mesh reads only the outcome's layout and bars).
TriangleMesh make_file_mesh(const Session& session, const Layout& layout, const Bars& bars,
                            const FileOptions& options, FileReport& report,
                            const std::atomic<bool>* stop = nullptr);

// Brief E4, leg 2 (rule OS16): THE PRINT CHECK of the file, as the file job runs it (make_file_mesh: the solid carved,
// the sags lifted or given legs, made, checked layer by layer and made again), its mesh dropped. `bars` the bars the
// file is made of (the sag pass's when it changed any, else those given); `kept` per bar of them: in the file (not
// left out by the layer check's places, bars_present, nor by the owner's hold rules, weave_holds) — the bars the
// Organic strength check judges. Not ok: `why` (the mesh could not be made).
struct PrintChecked {
  bool ok = false;
  std::string why;
  FileReport made;
  Bars bars;
  std::vector<char> kept;
};
PrintChecked print_check_bars(const Session& session, const Layout& layout, const Bars& bars, const FileOptions& options,
                              const std::atomic<bool>* stop = nullptr);
// Of a print check's bars, which are in the file (the file job's own reading; `made` the check's report).
std::vector<char> bars_in_file(const Bars& made_bars, const FileReport& made, const std::vector<int>& weave_regions,
                               const FileOptions& options);
// The options a job's file is made with: OF4, the tubes route for a job with a weave region unless it asked.
FileOptions file_options_for(const FileOptions& asked, bool weave);
// OrganicAsk::print_check for `session` with `options`: the print check, its bars in place of those given.
std::function<std::string(const Layout&, Bars&)> print_check_hook(const Session& session, const FileOptions& options,
                                                                   const std::atomic<bool>* stop = nullptr);

// ── THE STRENGTH CHECK (Install 3, rule V4) ──────────────────────────────────
// The old engine's check of a regular lattice (run_job.cpp, certify_latticed_variant), fed from this layout. On the
// strength job's voxel grid a voxel is lattice when its centre is lattice of a laid cell (cell_holds: the rule the file
// is carved by, D14); its relative density is lattice_density_from_strut(type, cell, half the cell's strut), its cell
// size the cell's. A cell gets NO credit (its voxels are void in the composite solve, as the old open finish treats
// cut cells) when it is cut, when the file left out a bar of it (bar_left_out_at), or when the old band refuses its
// type or density. Everything else in the part is solid.
struct CreditGrid {
  Vec3 origin{};          // the grid's low corner; voxel (i,j,k) is origin + spacing * (i..i+1, ...)
  double spacing = 0.0;
  int nx = 0, ny = 0, nz = 0;
};
struct LatticeCredit {
  // Per voxel ((k * ny + j) * nx + i): the cell whose lattice holds its centre (-1: none), and whether it has credit.
  std::vector<std::int32_t> cell;
  std::vector<char> credited;
  // Per layout cell.
  std::vector<char> cell_credit;     // 1: credited
  std::vector<double> cell_rho;      // its relative density (0 when the type has no law for it)
  std::size_t cells_credited = 0, cells_no_credit = 0;
  std::size_t cut = 0, lost_bar = 0, out_of_band = 0;   // why no credit (a cell counted under its first reason)
};
// `solid`, when given, names the voxels to read (the part's); the rest are left -1. `left_out_at` is the file's
// FileReport::left_out_at (the places the mesh writer left bars out for). Same answer for any number of threads.
LatticeCredit lattice_credit(const Layout& layout, const Domain& domain, const Bars& bars,
                             const std::vector<Vec3>& left_out_at, const CreditGrid& grid,
                             const std::vector<char>* solid = nullptr, int threads = 0);

// What the file job hands the check, once its file is made.
struct StrengthAsk {
  const Session* session = nullptr;   // the one the outcome was laid by: its domain is the outcome's
  const Outcome* outcome = nullptr;
  const FileReport* made = nullptr;
  std::string job_path;               // the strength job's file
  std::string out_dir;                // where the file was written; the check's own files go beside it
  Vec3 part_lo{}, part_hi{};          // the part's box as the file job opened it
  int threads = 0;
  // Brief E2 (Organic: every lattice region a weave): the bars the file was made of, in the layout's order (the sag
  // lift's when it changed any), and per bar whether the file holds it (the writer's own rules: what the layer check
  // left out and the bridge rules); the job's light strut width. Null for a cell lattice.
  const Bars* bars = nullptr;
  const std::vector<char>* kept = nullptr;
  double light_width_mm = 0.0;
};
struct StrengthDone {
  bool ok = false;
  std::string code;                   // not ok: the refusal's word
  int exit_code = 1;
  std::string why, detail;            // not ok: one plain line, and the technical message
  std::string json;                   // ok (run): the `strength` block, an object
  std::vector<std::string> files;     // ok (run): the files written into out_dir, by bare name
  bool accepted = false;
};
// The check is the CLI's (run_job.cpp: lattice_file_strength_check): core's lattice layout is always built, and the
// old check needs the solver and the importer. `before` reads the strength job (cheap; no solve) and may refuse it;
// `run` makes the check on the laid lattice.
// `run_organic` (brief E2, Part A) is the Organic check, a frame of beams (lattice_layout_frame.hpp), asked when every
// lattice region of the job is a weave; a job with weave AND cell regions and a strength job is refused
// (strength_mixed).
struct StrengthCheck {
  std::function<StrengthDone(const std::string& job_path)> before;
  std::function<StrengthDone(const StrengthAsk& ask)> run;
  std::function<StrengthDone(const StrengthAsk& ask)> run_organic;
};

// One job, as read from job.json.
struct FileJob {
  std::string model;                    // the part's file; relative to the job file's folder
  std::string output = "lattice.stl";   // the STL's name; relative to the output folder
  double linear_deflection = 0.0;       // <= 0: core's default (STEP only), as the bridge's open
  // The stress result's file (key "demand"): a bare name, beside the job. Empty: none sent. run_file_job reads it
  // into settings.stress.demand; a caller of make_lattice_file puts the field there itself.
  std::string demand;
  // The strength check's job (key "strength_job", V4): a bare name in job.json, of a run job beside it of the kind the
  // old Lattice run takes ("mode": "lattice_part"). run_file_job makes it a path beside the job; a caller of
  // make_lattice_file gives the path. Empty: no check, and the result names none (V2).
  std::string strength_job;
  // Organic, Traced (layout key "region_weave"): the stress tensor's file (key "tensor"), a bare name beside the job,
  // as "demand". Empty: none sent. run_file_job reads it into `tensor_field`; a caller of make_lattice_file puts the
  // field there itself. A job with a weave region and no field is refused (no_stress_result, OR14).
  std::string tensor;
  std::shared_ptr<const TensorField> tensor_field;
  // Brief E2, item 11 (key "strengthened"): a strengthen round's strengthened.json, by a path from the job's folder
  // (or a whole path). run_file_job reads it (apply_strengthened): its stress input replaces the tensor, its reference is
  // stated, its floors are added. Empty: none.
  std::string strengthened;
  // OF5 (key "file_format"): "3mf" or "stl". Empty: 3MF when the file takes the tubes route (OF4), STL otherwise. A
  // 3MF is written where the STL would be, its ".stl" name ending ".3mf".
  std::string file_format;
  // The trace's ask (layout keys "organic_spacing_mm", or "organic_spacing_min_mm" with "organic_spacing_max_mm" and
  // "organic_spacing_exponent" (O12); "organic_width_mm"; the reference is the layout's "reference_mpa" and
  // "percentile"; "organic_shape_fit" (O13), true when not given); read only when a region is a weave. The Finish is
  // the regular layout keys' (OR30: "rim_mm", "cover_mm", "skin", "skin_width_mm").
  OrganicAsk organic;
  // Leg J item 3 (OJ3): the layout key "organic_groups", a list of {"regions": [ids], any organic_* key}: each group its
  // own ask (the layout's organic_* keys, then the group's own over them). Empty: one ask for every weave region
  // (`organic`), as before. Laid by Session::lay_organic with the groups (OP11).
  std::vector<OrganicGroup> organic_groups;
  Settings settings;
  FileOptions options;
};

// THE DEMAND FILE (a stress result for By stress, R16 to R18), little-endian:
//   8 bytes "TODEMAND", int32 version (1), int32 nx, ny, nz, float64 origin x, y, z, float64 spacing,
//   then nx*ny*nz float32 von Mises MPa in core's VoxelGrid order ((k * ny + j) * nx + i).
// Reading refuses a wrong magic, a version other than 1, a grid of no voxels, a file not exactly the size its grid
// needs, and any number that is not finite (or a spacing not above 0); `why` then says which, in plain words.
inline constexpr int kDemandVersion = 1;
bool read_demand_file(const std::string& path, DemandField& out, std::string* why = nullptr);
// Writes one (for tests and tools; the app writes its own). False when the file cannot be written or the field is empty.
bool write_demand_file(const std::string& path, const DemandField& field);

// THE TENSOR FILE (a stress result for Organic, Traced: the full tensor, so the trace has directions), little-endian:
//   8 bytes "TOTENSOR", int32 version (1), int32 nx, ny, nz, float64 origin x, y, z, float64 spacing,
//   then 6 float32 per voxel in core's VoxelGrid order ((k * ny + j) * nx + i), each voxel's six in TensorField's
//   order: xx, yy, zz, xy, yz, zx, MPa.
// Reading refuses what read_demand_file refuses (a wrong magic, a version other than 1, a grid of no voxels, a file
// not exactly the size its grid needs, any number that is not finite, a spacing not above 0); `why` says which.
inline constexpr int kTensorVersion = 1;
bool read_tensor_file(const std::string& path, TensorField& out, std::string* why = nullptr);
// Writes one (for tests and tools). Each value is written as a float32. False when the file cannot be written or the
// field is empty.
bool write_tensor_file(const std::string& path, const TensorField& field);

// THE SHALLOW-BAR TABLE of a weave (for the owner's bridge rules, OR8 to OR10): of the bars of `regions` (the weave
// regions), those lying under 30 degrees (bar_is_bridge), how they are held, and their WHOLE runs.
//   Held: an end is held when it is Node, Solid or Joined (on another bar or in the solid); Surface and Loose are not.
//   A whole run: shallow bars chained through joints where EXACTLY two shallow bars end (at one point: ends within a
//   hundredth of a micron are one, O6) and they
//   go on in line within 15 degrees. A shallow bar that chains to nothing is a run of one. A run's length is the sum
//   of its bars'.
//   Bands of run length: to 5 mm, over 5 to 10, over 10 to 20, over 20.
//   What the layer check did with each run (from the file's make-check-make loop): left out when any of its bars was
//   left out (by a place of `drop_at`, read as the file writer reads it: bars_present with `regions` at `layer_mm`, O10;
//   or by the owner's bridge rules: weave_holds after those places); else post when a post's top is within half the bar's width + 0.5 mm of
//   one of its bars; else kept.
//   The owner's bridge rules (O6 to O9, weave_holds after `drop_at`): `kept_any_length`, the shallow bars kept with
//   both ends held, at any length; `weave_left_unheld`, those left out because an end leads to nothing.
//   `stands_added` (O8) is not read from the bars: the file job fills it from the loop's report.
struct ShallowTable {
  std::size_t bars = 0;                        // shallow bars of the weave
  std::size_t held_both = 0, held_one = 0, held_none = 0;
  std::size_t runs = 0;
  double longest_run_mm = 0.0;
  struct Band { std::size_t runs = 0, kept = 0, left_out = 0, post = 0; };
  Band bands[4];                               // to 5 mm, 5 to 10, 10 to 20, over 20
  std::size_t kept_any_length = 0, weave_left_unheld = 0, stands_added = 0;
};
ShallowTable shallow_bar_table(const Bars& bars, const std::vector<int>& regions, const std::vector<Vec3>& drop_at,
                               const std::vector<MeshSpec::Post>& posts, double layer_mm = 0.2);

// A job that cannot be read. what() is the reader's own words (which key, what is wrong).
class FileJobError : public std::runtime_error {
 public:
  explicit FileJobError(const std::string& msg) : std::runtime_error(msg) {}
};

// Reads a job. Every key is optional but "mode" (must be "lattice_file") and "model"; a
// key it does not know is refused, so a misspelt setting is never silently dropped.
FileJob parse_file_job(const std::string& json_text);

struct FileResult {
  bool ok = false;
  // "ok", or which refusal: a stable word the app can key its own copy on.
  std::string code;
  std::string why;      // not ok: ONE plain line, for a maker
  std::string detail;   // not ok: the technical message behind it, if there is one (for a log)
  int exit_code = 1;    // 0 made, 3 refused (the part or the settings), 1 anything else
  std::string file;     // the STL (or 3MF, OF5) written
  std::size_t file_bytes = 0;
  // OF5: what was written: "3mf" or "stl", the route ("tubes" or "merged"), and whether the 3MF's model part was
  // deflated. The result file carries them (with the shells, those left out, and slicer_supports "off": the app tells
  // the owner to slice with supports off) for a job with a weave region only.
  std::string file_format, weave_mesh;
  bool sweep_on = false;   // OV1: the tubes were swept (organic_sweep)
  bool compressed = false;
  // The part.
  int faces = 0;
  std::size_t part_triangles = 0, open_edges = 0;
  // The layout (the bridge's LatticeLayoutResult counts, under the same names).
  std::size_t cells = 0, solid_pieces = 0, bars = 0, at_one_line = 0, at_widest = 0;
  std::size_t stubs = 0, joined = 0, dropped = 0, pieces = 0, adrift = 0, stepped_edges = 0;
  std::size_t thin_solid = 0;   // cut cells print rule P8 (f) made solid (Outcome::thin_solid)
  bool cells_by_stress = false; // cell size by stress was applied to the layout (Outcome::cells_by_stress, C22)
  double step_held_at = 0.0;    // C24: the part's size-step limit kept (Outcome::step_held_at); 0 when none was asked
  double floor_cell_mm = 0.0, min_strut_mm = 0.0, open_look = 0.0, touch = 0.0;
  std::vector<int> empty_regions;
  // By stress (StrutReport): whether the struts were graded by stress, the reference used, the highest stress any
  // cell read, and the cells at the light and the heavy end.
  bool by_stress = false;
  double reference_mpa = 0.0, highest_mpa = 0.0;
  std::size_t at_light = 0, at_heavy = 0;
  // Organic, Traced: the weave regions laid, the strands traced for them, the bars of those regions, the trace's time,
  // and the shallow-bar table (filled once the file is made).
  std::size_t weave_regions = 0, strands = 0, weave_bars = 0;
  double ms_trace = 0.0;
  // O12: the spacing the trace used over the weave regions' candidates (Outcome::spacing_*), mm; 0 with no weave.
  double spacing_smallest_mm = 0.0, spacing_largest_mm = 0.0, spacing_mean_mm = 0.0;
  // O16: the net skin's struts laid (Finish Skin on a weave region) and their length, mm.
  std::size_t net_struts = 0;
  double net_mm = 0.0;
  // G12: what Grown did (Outcome::grown); null for Traced and cube lattices (then not written).
  std::shared_ptr<const GrowReport> grown;
  // OG1, OG2 (brief E6): the gap rule (points lowered, bars over their cap), its diagnosis, and the relief.
  std::size_t gap_capped = 0, gap_broken = 0;
  GuardReport guard;   // OG5 (brief E9): Outcome::guard
  Outcome::Tight tight;
  Outcome::Relief relief;
  ShallowTable shallow;
  // The mesh.
  FileReport made;
  // The strength check (V4): ran, its `strength` block and whether it was accepted. Not run: nothing (V2).
  bool strength_ran = false;
  bool strength_accepted = false;
  std::string strength_json;
  double ms_strength = 0.0;
  // Where the time went, ms.
  double ms_import = 0.0, ms_measure = 0.0, ms_read = 0.0, ms_cells = 0.0, ms_bars = 0.0;
  double ms_write = 0.0, ms_total = 0.0;
};

// The whole job for a part already in memory: checks it, lays it, makes the mesh, writes
// the STL at `stl_path`. Never throws: every failure is a FileResult with its plain line.
// `said`, when given, is called with a short line as each step starts (the CLI prints it).
// With `job.strength_job`, the check (`strength`) reads it before the lattice is laid and checks the lattice once the
// file is written; a check that was asked for and could not run fails the job and leaves no file (V2). Asked for with
// no `strength` given: refused (strength_unavailable).
FileResult make_lattice_file(StepModel model, const FileJob& job, const std::string& stl_path,
                             const std::atomic<bool>* stop = nullptr,
                             void (*said)(const char*) = nullptr,
                             const StrengthCheck* strength = nullptr);

// The job as the CLI runs it: reads `job_path`, opens the model beside it (STEP, STL or
// 3MF, with the face sidecar: the faces the app saw), runs make_lattice_file into
// `out_dir` (which must exist), and writes `out_dir`/lattice_file.json whatever happened.
// `threads` > 0 overrides the job's own. Never throws.
FileResult run_file_job(const std::string& job_path, const std::string& out_dir, int threads = 0,
                        void (*said)(const char*) = nullptr, const StrengthCheck* strength = nullptr);

// Brief E2: what run_file_job reads before it makes anything: the job at `job_path` (`threads` > 0 overrides its own),
// its demand and tensor files, its "strengthened" (apply_strengthened), and the part beside it. False: `r` holds the
// refusal (as run_file_job would write it). Never throws.
bool load_file_job(const std::string& job_path, int threads, FileJob& job, StepModel& model, FileResult& r,
                   void (*said)(const char*) = nullptr);

// The result file's name, and its text.
inline constexpr const char* kFileResultName = "lattice_file.json";
std::string file_result_json(const FileResult& r);

}  // namespace topopt::lattice_layout
