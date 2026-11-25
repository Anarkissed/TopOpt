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

#include <array>
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
#include "topopt/print_frame.hpp"
#include "topopt/print_orientation.hpp"
#include "topopt/step.hpp"
#include "topopt/support_paint.hpp"

namespace topopt::lattice_layout {

// The writer's settings a file job starts from: MeshSpec's, with the blended foot on (O11: half the bar's width, for
// a weave's ends in the solid) and the round top on a weave's shallow struts (O14); nothing else changes.
inline MeshSpec file_mesh_defaults() {
  MeshSpec m;
  m.weave_foot_mm = -1.0;
  m.weave_round_top = true;
  m.weave_bridge_domes = true;   // OS1 B
  m.tube_facet_mm = 0.03;        // OS1 A (his ruling R1)
  m.weave_fold_split = true;     // OS1 D
  return m;
}

// ── PRINT RESOLUTION (2026-11-25, his "Offer print resolutions when exporting. Full detail vs medium vs coarse. All with
// information about their file size estimates and resolution.") ────────────────────────────────────────────────────────
// Job key "print_resolution": "full" | "medium" | "coarse" (not given: full, the job as before). A level loosens only how
// finely the surface is written, never what prints: the layout, the cells, the struts' and walls' widths, the print check
// and the strength check are the same at every level.
//   FULL    the file as before, byte for byte (every strut type and the sheets).
//   MEDIUM  sheets: surface within 0.05 mm (the bound the simplifier holds; Full's 0.02), contoured on a cell of half the
//           thinnest wall (Full's third), never coarser than a 16th of the cell (Full's 24th; measured: as many
//           triangles, a third quicker). Struts: a round strut and its joint balls 8 sides (Full's 12) where the corners
//           then lie within 0.05 mm of the true round: every strut up to 1.4 mm wide (two lines, and more).
//   COARSE  the same at 0.1 mm: struts up to 2.9 mm wide go to 8 sides (so a two-line lattice's struts are Medium's).
// Walls stay at least two lines at every level: the sheets' bead guard and the floor's contoured wall
// (sheet_print_wall_mm) take the level's bound, so a two-line sheet prints a little thicker (its thinnest wall measured
// 0.95 mm at Full, 0.97 at Medium, 1.00 at Coarse; its plastic +5 % and +13 % on core's plate); a strut's flat sides are
// never nearer its centre than at Full. What the print check does is the same: no level leaves a strut out that Full
// keeps (a sheet's posts follow its surface, which the level moves by up to its bound).
// A job with an Organic (weave) region is made at Full only: another level is refused (job_unreadable).
enum class PrintResolution : std::uint8_t { Full = 0, Medium = 1, Coarse = 2 };
inline constexpr PrintResolution kPrintResolutions[3] = {PrintResolution::Full, PrintResolution::Medium,
                                                         PrintResolution::Coarse};
const char* print_resolution_id(PrintResolution level);      // "full" | "medium" | "coarse"
bool print_resolution_from_id(const std::string& id, PrintResolution& out);
struct PrintResolutionLevel {
  PrintResolution level = PrintResolution::Full;
  double surface_mm = 0.02;            // the sheets' bound, and the struts' corners (0 at Full: the struts as before)
  double strut_facet_mm = 0.0;         // MeshSpec::strut_facet_mm
  double sheet_dc_wall_share = 3.0;    // MeshSpec::sheet_dc_wall_share
  double sheet_dc_cell_share = 24.0;   // MeshSpec::sheet_dc_cell_share
  const char* name = "Full detail";    // his words for the level
  const char* words = "";              // the resolution in plain words: "surface within 0.05 mm"
};
PrintResolutionLevel print_resolution_level(PrintResolution level);

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
  // ★ 362 11-23: the job's own line-teller, handed to the print check (PrintableSpec::said). Null: nothing said.
  void (*said)(const char*) = nullptr;
  // OF4: mesh key "weave_mesh" ("tubes" or "merged"). Not given: Tubes for a job with a weave region (make_lattice_file
  // sets mesh.weave_mesh), the writer's own Merged otherwise (a job with no weave region is never changed by it).
  bool weave_mesh_asked = false;
};

// PRINT RESOLUTION: the options a level makes the file with. Full leaves `o` exactly as given (the file as before);
// Medium and Coarse set the sheets' bound and contouring cell and the struts' facets (print_resolution_level).
void apply_print_resolution(PrintResolution level, FileOptions& o);

// ── THE SIZE ESTIMATE PER LEVEL (before the file is made: from the layout alone) ─────────────────────────────────────
// What it reads, all of it the layout's and the part's (no mesh): the part's own triangles; the cells, and of them those
// cut by the part's surface; per round strut its radius and per joint its ball's (the writer's own reading: an end not on
// the surface is a joint, its ball the widest strut there); the bridges (square bars); per sheet field its type, cell and
// cells laid.
struct PrintSizeInputs {
  std::size_t part_triangles = 0;
  std::size_t cells = 0, cut_cells = 0;
  std::vector<float> strut_r;      // per round strut, mm
  std::vector<float> ball_r;       // per joint, mm
  std::size_t bridges = 0;
  struct Sheet { TpmsKind kind = TpmsKind::Gyroid; double cell_mm = 0.0, wall_mm = 0.0; std::size_t cells = 0; };
  std::vector<Sheet> sheets;
  int bar_sides = 12;              // MeshSpec::bar_sides of the job
  LatticeTopology topology = LatticeTopology::Octet;   // the layout's (a strut side's weight is its type's)
  bool weave = false;              // a weave (Organic) region: no estimate (Full only)
};
PrintSizeInputs print_size_inputs(const Layout& layout, const Bars& bars, const std::vector<SheetField>& sheets,
                                  std::size_t part_triangles, const FileOptions& options);
// One level's estimate. `triangles` from the calibrated model (lattice_layout/print_resolution.cpp, THE MODEL: fitted on
// core's fixtures at the three levels, its error stated there and held by test_print_resolution); `stl_bytes` is a
// binary STL of that many (84 + 50 T, exact for the count); `threemf_bytes` the deflated 3MF the job writes (indexed).
// `ms`: how long the Mac takes to make it, from a made job's own times (print_size_ms); -1 when not known.
struct PrintSizeEstimate {
  PrintResolution level = PrintResolution::Full;
  std::size_t triangles = 0;
  std::uint64_t stl_bytes = 0, threemf_bytes = 0;
  double ms = -1.0;
};
PrintSizeEstimate estimate_print_size(const PrintSizeInputs& in, PrintResolution level);
// The model behind it (for the test that fits and holds it): the terms at a level (0 the part's own triangles, 1 the cut
// cells, 2 the cells of a strut lattice, 3 every round strut's sides, 4 every joint ball's sphere triangles, 5 the
// bridges, 6 and 7 a gyroid's and a Schwarz-D's cell (mm) x cells) and each term's weight (a sheet's per level, a strut
// side's per type).
inline constexpr int kPrintSizeTerms = 8;
std::array<double, kPrintSizeTerms> print_size_terms(const PrintSizeInputs& in, PrintResolution level);
double print_size_weight(int term, PrintResolution level, LatticeTopology topology);
// The bytes of a file of `triangles` triangles: binary STL (exact) and the job's deflated 3MF (estimated).
std::uint64_t stl_bytes_for(std::size_t triangles);
std::uint64_t threemf_bytes_for(std::size_t triangles);

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
  std::size_t domes_flattened = 0;   // OS1 B (ruling R2): PrintableReport's
  std::vector<Vec3> flat_domes_at;   // leg U: PrintableReport's (the held-flat ends' places)
  int dome_rounds = 0;
  std::vector<MeshSpec::Post> posts; // the posts added (the preview can draw them)
  std::size_t stands_added = 0;      // of `posts`, those under a weave's long shallow runs (O8)
  std::size_t weave_specks_ignored = 0, weave_held_ignored = 0;   // O10: PrintableReport's
  std::size_t part_overhangs = 0;   // PrintableReport's: the part's own overhangs, counted, never propped
  std::vector<Vec3> part_overhang_at;   // P3: PrintableReport's: where (the last pass)
  std::size_t own_by_k1 = 0;   // K1: PrintableReport's (left to the slicer by his rule, judged by the far point)
  std::size_t posts_outside = 0;    // ★ 362 11-23, PrintableReport's (F2): posts not added, their column leaving the part
  bool stopped_repeating = false;   // ★ 362 11-23, PrintableReport's (F3): stopped, a try having nothing new to try
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
  // SHEETS (SPEC 1.4, 3.3; builder B fills these, empty / 0 for a strut type). Per voxel: its own density,
  // lattice_density_from_strut(type, its cell, half of sheet_wall_at(voxel centre)); 0 where `credited` is 0. The band
  // test is per voxel. Per layout cell: the cells across the member there (Domain::Probe::room_through over the cell,
  // rounded down; 0 not read). Voxels in a blend band (no credit, SPEC 1.5) and in the solid-wall membrane (solid).
  std::vector<float> voxel_rho;
  std::vector<std::int32_t> cell_across;
  std::size_t blend_band = 0, membrane = 0;
  // SHEETS (builder B, additive): per layout cell its sheet_cells.bin flags (SheetCellRecord::kCredited, kCut,
  // kBlendBand, kOutOfBand, kUnderFloor, kMembrane); the floor it was judged by, in cells across
  // (sheet_structural_floor_cells: 10 / 9 until builder D's tables); the cells under it (no credit, SPEC 3.3); the
  // voxels credited. Empty / 0 for a strut type.
  std::vector<std::uint32_t> cell_flags;
  double floor_cells = 0.0;
  std::size_t under_floor = 0, voxels_credited = 0;
  // ANALYZE GUARD (sheets): per layout cell, the member's width there (mm): the narrowest Domain::Probe::room_through
  // over the cell's held points, of which cell_across is the count; NaN where not read. Empty for a strut type.
  std::vector<float> cell_room_mm;
};
// `solid`, when given, names the voxels to read (the part's); the rest are left -1. `left_out_at` is the file's
// FileReport::left_out_at (the places the mesh writer left bars out for). Same answer for any number of threads.
//
// SHEETS (SPEC 1.4, 1.5, 3.3; builder B). For a sheet layout (sheet_kind_of) the same call credits by PLACE: the
// fields are the layout's own (sheet_fields, as Outcome::sheets), the blend seams every touching pair
// (sheet_seams) that Layout::membrane does not make a solid wall. Per cell: no credit when it is cut (until D's
// tables and the reviewer's ruling, kSheetCutCellsCredited), when the member there holds fewer than the floor of
// cells across (cell_across, read by Domain::Probe::room_through at the cell's held points; a member thinner than one
// cell reads 0 and is under it too; a cell none of whose points is held is not read), or when its own wall's
// density is out of the type's band (reported as for struts). Per voxel held by a cell that may be credited: its own
// density, lattice_density_from_strut(type, the cell, half of sheet_wall_at(the voxel centre)), banded per voxel
// (voxel_rho); no credit inside a blend band (|sheet_seam_mm| under half the band: blend_band, SPEC 1.5); a voxel the
// solid-wall membrane keeps from every cell is counted (membrane) and is solid in the check, as everything else
// no cell holds. `bars` and `left_out_at` are not read for a sheet (it has none).
LatticeCredit lattice_credit(const Layout& layout, const Domain& domain, const Bars& bars,
                             const std::vector<Vec3>& left_out_at, const CreditGrid& grid,
                             const std::vector<char>* solid = nullptr, int threads = 0);
// SPEC 3.3: a cut sheet cell is credited only with builder D's cut-layer rows in the law and the reviewer's ruling.
inline constexpr bool kSheetCutCellsCredited = false;
// The per-cell half of lattice_credit for a sheet layout, with no voxel grid: cell_credit, cell_rho, cell_across,
// cell_flags and the cell counts (the per-voxel vectors stay empty). The file job reads it for sheet_cells.bin when the
// check did not write one. For a strut layout: empty.
LatticeCredit lattice_credit_cells(const Layout& layout, const Domain& domain, int threads = 0);

// ANALYZE GUARD (sheets): THE MEMBER WIDTH the old check's cells-per-member guard reads for a sheet
// (LatticePosture::member_width_mm, "the width measured on the part's own surface"; analyze.cpp, bar L4), per voxel of
// the credit's grid: its cell's room (LatticeCredit::cell_room_mm: room_through over the cell's lattice, the measure the
// lay's Structural floor and the credit's cell_across are read by), else, where that was not read, room_through at the
// voxel centre; 0 where no cell holds the voxel. Without it the guard measures the voxel staircase, which reads a member
// about two voxels thinner than it is: a member near the floor then holds no voxel at the floor, no convex corner is
// joined to its member, and the corners read about one cell across (an all-lattice box ten cells across, refused).
// Empty for a strut layout (the guard reads the staircase for it, as before).
std::vector<double> sheet_member_width_mm(const Layout& layout, const Domain& domain, const LatticeCredit& credit,
                                          const CreditGrid& grid, int threads = 0);

// THE CHECK'S MARGIN PER VOXEL by the type's strut law (strut_strength.hpp: the bound the check's strut result reads,
// Kd vm + Kv |p| in the plane and Kild vm + Kilv |p| + the off-axis term across the layers, at the density each
// voxel is credited with: LatticeCredit::voxel_rho, else its cell's): min(yield / in-plane bound, z_knockdown x yield /
// interlayer bound), +infinity where nothing loads it; NaN where the voxel is not credited, or the type has no law.
// `stress_tensor_field` 6 per voxel of the credit's grid (Voigt [xx yy zz xy yz zx], true shear, MPa: the composite
// solve's FixedDesignAnalysis::stress_tensor_field). Throws std::invalid_argument when the sizes disagree.
std::vector<float> lattice_voxel_margins(LatticeTopology topo, const LatticeCredit& credit,
                                         const std::vector<double>& stress_tensor_field, const Vec3& build_dir,
                                         double yield_mpa, double z_knockdown);

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
  // P2 (print_frame.hpp): the job's print frame. On: the session, the bars and part_lo/hi are in the print frame; the
  // check turns its strength job (and that job's part) through the same door, and writes every position it reports,
  // and fields.bin, back in the model frame. Off: as before.
  PrintFrame frame;
  // P4 (Phase 2): the print-orientation candidates' ups, in the job's frame (print_candidates); the check judges
  // each (StrengthDone::orientation). Empty: none.
  std::vector<Vec3> orientation_ups;
};
struct StrengthDone {
  bool ok = false;
  std::string code;                   // not ok: the refusal's word
  int exit_code = 1;
  std::string why, detail;            // not ok: one plain line, and the technical message
  std::string json;                   // ok (run): the `strength` block, an object
  std::vector<std::string> files;     // ok (run): the files written into out_dir, by bare name
  bool accepted = false;
  // P4 (his print orientation): the six candidates' guessed strength and the part's own support, in the job's frame
  // (print_orientation.hpp); the file job adds the bed and writes "print_orientation". Not known: the check made none
  // (the cube check, so far).
  OrientationStrengthsN orientation;
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
  // P2, his print orientation (key "print_frame": {"up": [x, y, z]}, the up in the part's own coordinates; Phase 1: one
  // of its six axes). Not given: off, and the job is as before, byte for byte. On: load_file_job turns every input
  // through the door (print_frame.hpp, turn_file_job_inputs) once the part is open; the file is written standing on
  // the chosen face; the result's positions are turned back (turn_result_to_model) and it carries "print_frame".
  PrintFrame print_frame;
  // PRINT RESOLUTION (key "print_resolution"): the level the file is made at; `options` already carry it
  // (apply_print_resolution, in parse_file_job). Not given: Full.
  PrintResolution resolution = PrintResolution::Full;
};

// P2: the door for a lattice file job: the zones, the cut pieces' cuts (regions and Protect skins), the demand field and
// the tensor field. The part is turned where it is opened (turn_step_model). A strengthening's additions and width
// floors are NOT turned: a strengthening of a job with a print frame ran in that frame and wrote them there.
void turn_file_job_inputs(const PrintFrame& f, FileJob& job);
// The same door for a layout's own inputs (what the iPad's bridge session holds: its settings and its tensor). An
// Organic ask's build_dir must then be +Z (the print frame's up): the caller sets it.
void turn_layout_inputs(const PrintFrame& f, Settings& settings, std::shared_ptr<const TensorField>& tensor);

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
  std::size_t small_patch_cells = 0;   // K5: cells made solid for a Structural patch narrower than its count across
  std::vector<int> quilt_regions;      // K3: Outcome::quilt_regions (laid with the quilt: nothing else laid there)
  // 2026-11-24 (362, after reentrant on the cube's face region): a cell region whose struts the print check's leave-outs
  // took (nearly) all of: kEmptiedShare or more of its struts (skin bars not counted), at least kEmptiedFewest of them.
  // The file is still written, with nothing where the region's cells were (their space open, their struts gone); the app
  // shows the region as "Cannot Lattice" with `why`, one plain line with the cause, never a silent empty lattice.
  // Written as the result's "cannot_lattice" only when there is one (else the result is as it was).
  struct Emptied {
    int region = 0;
    std::size_t struts = 0, left_out = 0;
    std::string why;
  };
  std::vector<Emptied> emptied;
  std::vector<Layout::CellSearch> cell_search;   // K7, K8: Layout::cell_search (asked: CellSpec::cell_search, stretch_edges)
  // SHEETS: the laid fields and seams (Outcome::sheets, sheet_seams; the result's "sheets" and "sheet_seams", written
  // only for a sheet job). The seams' fell_back / why come from the file (the blend's loop), not the lay. In the result:
  //   "sheets": [{"region": 1, "kind": "gyroid" | "schwarz_d", "cell_mm": 8, "wall_min_mm": 0.9, "wall_max_mm": 0.9,
  //               "cells": 120}, ...]
  //   "sheet_seams": [{"regions": [1, 2], "seam": "solid_wall" | "blend", "fell_back": false, "why": ""}, ...]
  // The layout keys a sheet job reads (and the bridge's settings of the same names): "sheet_seam": "blend" |
  // "solid_wall" (Settings::sheet_seam; not given: solid_wall), "auto_by_cell": true | false (StrutSpec::auto_by_cell).
  std::vector<SheetField> sheets;
  std::vector<SheetSeamBand> sheet_seams;
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
  // P4: the print orientation ranking and recommendation ("print_orientation"), when the check gave its numbers.
  std::string orientation_json;
  // P3: the part's own overhang places the print check found (its last pass), and what was painted for them in the
  // 3MF (support_paint.hpp; `painted.at` in the model frame once the result is turned back). The result's
  // "slicer_supports" follows: "painted" (some painted), "needed" (places found, none could be painted: an STL, or no
  // part triangle under them), "off" (none found).
  std::size_t part_overhang_places = 0;
  SupportPaint painted;
  // P4 (Phase 2, his "edges held by supports"): the job stands the part on an EDGE; its stand supports (bands on the
  // edge's two faces, orientation_stand), painted when it stands (`stand.stands`).
  bool stand_edge = false;
  OrientationCandidate stand;
  std::size_t stand_triangles = 0;
  double stand_area_mm2 = 0.0;
  double ms_strength = 0.0;
  // Where the time went, ms.
  double ms_import = 0.0, ms_measure = 0.0, ms_read = 0.0, ms_cells = 0.0, ms_bars = 0.0;
  double ms_write = 0.0, ms_total = 0.0;
  // P2: the job's print frame (off: as before). On, the result's positions are in the model frame
  // (turn_result_to_model) and the file is in the print frame; the result says which ("print_frame").
  PrintFrame print_frame;
  // PRINT RESOLUTION: the level the file was made at, and the three levels' estimates (from the layout, before the file
  // was made; `sized` false when none was made: a weave job, or a refusal before the lay). The result's
  // "print_resolution" block (written for a cell lattice that was laid):
  //   {"level": "full", "levels": [{"level": "full", "name": "Full detail", "words": "surface within 0.02 mm",
  //     "triangles": N, "stl_bytes": N, "threemf_bytes": N, "ms": N}, ...medium, coarse]}
  // `ms` per level: how long the Mac takes to make that file (print_size_ms of this job's own times).
  PrintResolution resolution = PrintResolution::Full;
  bool sized = false;
  PrintSizeEstimate estimates[3];
};
// PRINT RESOLUTION: how long the Mac takes to make `level`'s file of a job, from a made job's own times: the job again
// without its strength check, the sheets' contouring and the write scaled to the level (calibrated with the triangles).
// -1 when `r` made no file.
double print_size_ms(const FileResult& r, PrintResolution level);
// P2: every position of a result made in the print frame, turned back to the model frame (once, before it is written).
// The strength block is turned where the check writes it.
void turn_result_to_model(const PrintFrame& f, FileResult& r);

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

// ── A PRINT COUPON PER STRUT TYPE (2026-11-24) ────────────────────────────────
// His rule: every type but the octet (proven at 8 mm) and bccz (8 mm, 2026-07-29) is "Not print-tested" until he prints
// a sample. The coupon is the 8 mm rim coupon's (printed 2026-11-11) made by THIS engine for any strut type: the old
// coupon's outline (lattice_coupon_solid: 45 x 40 x 35 mm, a tongue, a half-round top that cuts the cells at every
// angle), all lattice, 8 mm cells (smaller only where a wall needs it), two-line struts, Finish Skin over the cut cells,
// and a flat 2 mm plate fused in (a 2 mm Protect skin on its underside: one file, flat on the bed). It goes through the
// file job, so it is the print-checked file (made, checked layer by layer and made again) or a refusal in one line.
struct CouponAsk {
  LatticeTopology topology = LatticeTopology::Octet;
  double cell_mm = 8.0;
  double plate_mm = 2.0;
  double bead_mm = 0.45;
  int threads = 0;   // 0: every core
};
// The coupon's file job (its JSON), for the part saved as `model` (beside the job) whose underside is face
// `underside_face`.
std::string type_coupon_job(const CouponAsk& ask, const std::string& model, int underside_face);
// Writes into `out_dir` (which must exist): <type>_coupon_part.stl (the part), <type>_coupon_job.json, and what the file
// job writes there (<type>_coupon_lattice.stl, the file to print, and lattice_file.json). Never throws.
FileResult make_type_coupon(const CouponAsk& ask, const std::string& out_dir);

inline constexpr double kEmptiedShare = 0.9;
inline constexpr std::size_t kEmptiedFewest = 4;
// FileResult::emptied of a file made of `bars` (its cell regions; `weave_regions` are not read) with the print check's
// leave-out places `left_out_at` (FileReport::left_out_at; bars_present is the writer's own rule).
std::vector<FileResult::Emptied> emptied_regions(const Bars& bars, const std::vector<Vec3>& left_out_at,
                                                 const std::vector<int>& weave_regions);

// ── SHEETS: sheet_cells.bin (SPEC 1.6, the K4 colours and the Results card for a sheet, in place of bars.bin) ───
// Written by the strength check beside strength.json (builder B) for a sheet job; little-endian:
//   8 bytes "TOSHEET1", uint32 frame count F, uint32 cell count N, uint32 flags (0; reserved),
//   F frames of 12 float32: origin xyz, ax[0] xyz, ax[1] xyz, ax[2] xyz (the part's own MODEL frame, P2 turned back),
//   N records of 40 bytes, in the layout's cell order:
//     int32 region, int32 frame (index into the F frames), float32 lo a, b, c (frame mm, the cube's low corner),
//     float32 size_mm, float32 wall_mm (the cell's own wall, Cell::strut), float32 cells_across (0: not read),
//     float32 margin (the check's margin for the cell, its worst voxel's; NaN: not judged), uint32 flags.
inline constexpr char kSheetCellsMagic[8] = {'T', 'O', 'S', 'H', 'E', 'E', 'T', '1'};
inline constexpr const char* kSheetCellsName = "sheet_cells.bin";
struct SheetCellRecord {
  std::int32_t region = 0, frame = 0;
  float lo[3] = {0, 0, 0};
  float size_mm = 0.0f, wall_mm = 0.0f, cells_across = 0.0f;
  float margin = 0.0f;
  std::uint32_t flags = 0;
  // flags
  static constexpr std::uint32_t kCredited = 1, kCut = 2, kBlendBand = 4, kOutOfBand = 8, kUnderFloor = 16,
                                 kMembrane = 32;
};
static_assert(sizeof(SheetCellRecord) == 40, "sheet_cells.bin: 40 bytes a record");
struct SheetCellsFile {
  std::vector<Frame> frames;
  std::vector<SheetCellRecord> cells;
};
// The records of a laid sheet layout (frames, region, frame, lo, size, wall, cut flag; margin NaN, the rest 0): the
// check fills margin, cells_across and its flags. `frame` turns each frame into the model frame (P2).
SheetCellsFile sheet_cells_of(const Layout& layout, const PrintFrame& frame = PrintFrame{});
bool write_sheet_cells_file(const std::string& path, const SheetCellsFile& f);
// Refuses a wrong magic, a file not exactly the size its counts need, a frame index out of range, a number that is not
// finite (but a NaN margin); `why` says which.
bool read_sheet_cells_file(const std::string& path, SheetCellsFile& out, std::string* why = nullptr);

// SHEETS (builder B): sheet_cells.bin AS THE CHECK JUDGED IT: sheet_cells_of's records, each with its cells across
// (LatticeCredit::cell_across), its flags (cell_flags; kCut kept) and its margin, the smallest of `voxel_margin` over
// the voxels the cell holds (LatticeCredit::cell; lattice_voxel_margins: NaN where none is judged). `voxel_margin`
// empty: every margin NaN (the cells judged, the margins not). The credit must be of this layout.
SheetCellsFile sheet_cells_judged(const Layout& layout, const LatticeCredit& credit,
                                  const std::vector<float>& voxel_margin, const PrintFrame& frame = PrintFrame{});
// What the check writes for a sheet job beside strength.json: sheet_cells.bin (sheet_cells_judged) in `out_dir`, and
// the strength block's sheet keys, as `keys` (lines of the block, each indented four spaces and ending ",\n"):
//   "sheet_cells": "sheet_cells.bin",       the file, by its bare name (THE KEY the app fetches it by)
//   "sheet_credit": {"cells", "cells_credited", "cells_cut", "cells_out_of_band", "cells_under_floor",
//                    "cells_in_blend_band", "cells_by_membrane": counts of cells by their flags;
//                    "floor_cells": the floor judged by; "cut_cells_credited": kSheetCutCellsCredited;
//                    "voxels_credited", "voxels_blend_band", "voxels_membrane": the voxel counts (null with no grid);
//                    "margins": true when the records carry the check's margins}
// For a strut layout nothing is written (`file` and `keys` empty). Not ok: `why` (the file could not be written).
struct SheetCheckFiles {
  bool ok = true;
  std::string why;
  std::string file;   // kSheetCellsName when written
  std::string keys;
};
SheetCheckFiles write_sheet_check_files(const std::string& out_dir, const Layout& layout, const LatticeCredit& credit,
                                        const std::vector<float>& voxel_margin, const PrintFrame& frame = PrintFrame{});
// The strength block (an object's text, "{" first) with `keys` (write_sheet_check_files) put in right after its "{".
std::string strength_block_with(const std::string& block, const std::string& keys);

// The result file's name, and its text.
inline constexpr const char* kFileResultName = "lattice_file.json";
std::string file_result_json(const FileResult& r);

}  // namespace topopt::lattice_layout
