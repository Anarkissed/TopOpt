// THE PRINT FRAME: "rotate at the door" (his print orientation, 2026-11-23; spec 2c, piece P2).
//
// A job may say which way is up when the part is printed: the job key "print_frame": {"up": [x, y, z]} (the up in the
// part's own coordinates, the model frame). Every geometric input of the job is turned ONCE, right after it is read
// (the part, its faces' planes and axes, zones, cut pieces, the stress results, the strength job's loads and boxes),
// so that every engine runs unchanged in a frame where up IS +Z: the PRINT frame. The file is written in that frame
// (standing on the chosen face, its lowest point at z = 0), and every position the job reports is turned back to the
// model frame, so the app's drawings keep working.
//
// No "print_frame" key: nothing here runs, and every byte is as before.
//
// Along one of the part's six axes the turn is an exact signed permutation of the coordinates (no rounding: x, -x, y
// ... only), so the turned inputs are the very numbers a copy of the part turned by hand would hold, and the voxel
// grids of the stress results permute exactly. A negated 0 is written +0 (0 - x, never -x), so a turned file never
// holds a "-0". Any other up (Phase 2, decision D5 as he changed it 11-23 evening: the 45 degree sides, and edges):
// a rotation, and the stress grids resampled (trilinear, the same pitch; turn_grid_values).
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {

struct StepModel;
struct VoxelGrid;
struct JobDescription;
struct KeepRegion;

struct PrintFrame {
  bool on = false;               // false: the identity, and nothing is turned (today's jobs, byte for byte)
  // true: the up is one of the six axes and the turn is the exact signed permutation below. false (Phase 2, his 11-23
  // evening: the 45 degree sides, and edges): any up, the rotation R, rounded as any rotation is; the voxel grids
  // (stress) are then RESAMPLED (trilinear, the same pitch) into the print frame, and fields.bin back.
  bool exact = true;
  Vec3 up{0.0, 0.0, 1.0};        // the up, in the model frame (unit)
  // exact: print[a] = sign[a] * model[perm[a]] + t[a]
  int perm[3] = {0, 1, 2};
  int sign[3] = {1, 1, 1};
  // print = R model + t, row by row (exact: the permutation's own matrix)
  double R[9] = {1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0};
  Vec3 t{0.0, 0.0, 0.0};         // after the turn: only z, so the part's lowest point is at z = 0
  Vec3 rot(const Vec3& v) const;     // R v
  Vec3 rot_t(const Vec3& v) const;   // R^T v

  Vec3 point_to_print(const Vec3& p) const;
  Vec3 dir_to_print(const Vec3& d) const;
  Vec3 point_to_model(const Vec3& q) const;
  Vec3 dir_to_model(const Vec3& d) const;
  // A symmetric tensor in Voigt order (xx, yy, zz, xy, yz, zx): R s R^T, and back.
  void tensor_to_print(const double* in, double* out) const;
  // The rotation R (print = R model + t), row by row.
  std::array<double, 9> rotation_row_major() const;
  // An axis-aligned box [lo, hi] turned: still axis-aligned (a signed permutation), its corners re-sorted.
  void box_to_print(Vec3& lo, Vec3& hi) const;
  void box_to_model(Vec3& lo, Vec3& hi) const;
  // Six numbers by axis (-x, +x, -y, +y, -z, +z) measured in the print frame, re-labelled by the model's axes.
  void axis_six_to_model(const double in[6], double out[6]) const;
};

// The frame whose up is `up` (model frame). Along one of the six axes (within 1e-6 after it is made unit): the exact
// permutation. Any other up (Phase 2): the shortest rotation taking it to +Z. A zero or not finite up: false and `why`
// says so in plain words. The translation is 0 until print_frame_set_base.
bool print_frame_for_up(const Vec3& up, PrintFrame& out, std::string* why = nullptr);
// The base: t = (0, 0, -lowest z of the turned vertices), so the turned part stands on z = 0.
void print_frame_set_base(PrintFrame& f, const TriangleMesh& model_mesh);

// ── THE DOOR (inputs) ──────────────────────────────────────────────────────────────────────────────────────────────
void turn_mesh(const PrintFrame& f, TriangleMesh& m);
// The mesh and every face's plane (origin, normal) and cylinder axis (point, direction). Face ids are kept.
void turn_step_model(const PrintFrame& f, StepModel& m);
void turn_keep_region(const PrintFrame& f, KeepRegion& k);
// The strength job (a topology job of mode "lattice_part"): every vector, point and box of it, its service gravity
// (loads.build_dir and gravity.direction: the same physical service, turned with the part), and its BUILD direction
// stated as the print frame's up (+Z). Its model file is turned where it is opened (turn_step_model).
void turn_job_description(const PrintFrame& f, JobDescription& job);

// A voxel grid's values, turned with the grid (an exact permutation of the voxels): `n` the grid's dims and `origin`
// its low corner, `comp` values per voxel. `kind`: 0 scalars, 3 vectors, 6 Voigt tensors. Returns the turned values
// and sets the turned dims and origin. `to_print` false turns from the print frame back to the model frame.
std::vector<double> turn_grid_values(const PrintFrame& f, bool to_print, const int n[3], Vec3 origin, double spacing,
                                     const std::vector<double>& values, int kind, int n_out[3], Vec3& origin_out);
std::vector<float> turn_grid_values_f(const PrintFrame& f, bool to_print, const int n[3], Vec3 origin, double spacing,
                                      const std::vector<float>& values, int kind, int n_out[3], Vec3& origin_out);
// A NODE grid's (n + 1 per axis) vectors (3 per node), turned: displacements.
std::vector<float> turn_node_vectors_f(const PrintFrame& f, bool to_print, const int n[3],
                                       const std::vector<float>& values);

// ── THE WAY OUT (outputs) ──────────────────────────────────────────────────────────────────────────────────────────
// fields.bin (fields.hpp, v1), written in the print frame by a check that ran there: rewritten in the model frame (the
// grid permuted exactly, displacements turned as vectors, every appended block permuted). False: `why`.
bool turn_fields_file_to_model(const PrintFrame& f, const std::string& path, std::string* why = nullptr);
// The report's block: {"up": [..], "rotation_row_major": [9], "translation_mm": [3]}.
std::string print_frame_json(const PrintFrame& f);

// TEST ONLY (the mutation guard of tests/validation/test_print_frame.cpp): each set bit leaves one input unturned, so
// the test proves that each is needed. 0 in every real run.
enum PrintFrameSkip : unsigned {
  kSkipNone = 0,
  kSkipModel = 1u << 0,
  kSkipZones = 1u << 1,
  kSkipTensor = 1u << 2,
  kSkipStrengthJob = 1u << 3,
  kSkipStrengthModel = 1u << 4,
  kSkipReportBack = 1u << 5,
};
extern unsigned g_print_frame_test_skip;

}  // namespace topopt
