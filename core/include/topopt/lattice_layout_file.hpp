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
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"

namespace topopt::lattice_layout {

// How the mesh is made from a layout.
struct FileOptions {
  double pitch_mm = 0.25;   // how finely each cell's shape is read (read_open_space)
  MeshSpec mesh;            // its `threads` and `stop` are set from the two below
  int threads = 0;          // 0 = every core
};

// What making the mesh found.
struct FileReport {
  MeshReport mesh;              // of the mesh returned (the last build)
  std::size_t open_boxes = 0;   // the open space read from the cells
  double ms_open_space = 0.0;
  int builds = 0;               // how many times the mesh was built
  // His print rules (a) and (b) of 2026-11-12, as measured on the mesh returned:
  // the bridge's LatticeLayoutResult carries the same two. -1 = not measured.
  double bed_contact_mm2 = -1.0;
  int midair_starts = -1;
};

// THE ONE PLACE THE MESH IS MADE for a file: the open space of the layout's cells, then
// the mesh of the layout and its bars in the part. `session` is the one `outcome` was
// laid by, and has not been laid again since (its domain is the outcome's).
// A stop flag (`stop`, when given) gives the work up by throwing LayCancelled.
// The mesh is empty and `report.mesh.why` says why when it cannot be made.
TriangleMesh make_file_mesh(const Session& session, const Outcome& outcome,
                            const FileOptions& options, FileReport& report,
                            const std::atomic<bool>* stop = nullptr);

// One job, as read from job.json.
struct FileJob {
  std::string model;                    // the part's file; relative to the job file's folder
  std::string output = "lattice.stl";   // the STL's name; relative to the output folder
  double linear_deflection = 0.0;       // <= 0: core's default (STEP only), as the bridge's open
  Settings settings;
  FileOptions options;
};

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
  std::string file;     // the STL written
  std::size_t file_bytes = 0;
  // The part.
  int faces = 0;
  std::size_t part_triangles = 0, open_edges = 0;
  // The layout (the bridge's LatticeLayoutResult counts, under the same names).
  std::size_t cells = 0, solid_pieces = 0, bars = 0, at_one_line = 0, at_widest = 0;
  std::size_t stubs = 0, joined = 0, dropped = 0, pieces = 0, adrift = 0, stepped_edges = 0;
  double floor_cell_mm = 0.0, min_strut_mm = 0.0, open_look = 0.0, touch = 0.0;
  std::vector<int> empty_regions;
  // The mesh.
  FileReport made;
  // Where the time went, ms.
  double ms_import = 0.0, ms_measure = 0.0, ms_read = 0.0, ms_cells = 0.0, ms_bars = 0.0;
  double ms_write = 0.0, ms_total = 0.0;
};

// The whole job for a part already in memory: checks it, lays it, makes the mesh, writes
// the STL at `stl_path`. Never throws: every failure is a FileResult with its plain line.
// `said`, when given, is called with a short line as each step starts (the CLI prints it).
FileResult make_lattice_file(StepModel model, const FileJob& job, const std::string& stl_path,
                             const std::atomic<bool>* stop = nullptr,
                             void (*said)(const char*) = nullptr);

// The job as the CLI runs it: reads `job_path`, opens the model beside it (STEP, STL or
// 3MF, with the face sidecar: the faces the app saw), runs make_lattice_file into
// `out_dir` (which must exist), and writes `out_dir`/lattice_file.json whatever happened.
// `threads` > 0 overrides the job's own. Never throws.
FileResult run_file_job(const std::string& job_path, const std::string& out_dir, int threads = 0,
                        void (*said)(const char*) = nullptr);

// The result file's name, and its text.
inline constexpr const char* kFileResultName = "lattice_file.json";
std::string file_result_json(const FileResult& r);

}  // namespace topopt::lattice_layout
