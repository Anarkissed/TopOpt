#pragma once

#include <string>
#include <vector>

#include "topopt/part.hpp"
#include "topopt/segment.hpp"
#include "topopt/step.hpp"

namespace topopt {

// ---------------------------------------------------------------------------
// FACE OVERRIDES — the sidecar that makes an imported mesh SELF-DESCRIBING
// (handoff 2026-07-24, paint mode).
//
// The bridge is stateless: every re-import (live face tagging, keep-clear
// derivation, and the final run_job) reads the model back from disk and
// re-segments it. For a tuned threshold or a painted selection to survive that,
// the choice cannot live only in app memory — it has to travel WITH the file.
// The unit-handling design already set the precedent: the app bakes the unit
// into its working-copy STL once, and every stateless downstream call re-reads a
// file that is already correct, so no unit threads through the bridge or the job
// schema. This does the same for the face partition.
//
// The app writes a `FaceOverrides` sidecar next to its working-copy STL. The ONE
// import choke point every stateless consumer already routes through
// (`import_part_file`) applies it, so the pseudo-faces a re-import produces are
// exactly the ones the user saw and painted — with ZERO change to any bridge or
// job-schema signature. Two independent refinements travel in it:
//
//   * `dihedral_threshold_deg` / `planar_region_cone_deg` retune the base
//     segmentation (SegmentOptions). A user who hit fragmentation, or a leak the
//     default missed, gets the partition they chose — and, crucially, the RUN
//     uses that same partition, so tapped face ids still line up.
//
//   * `paint_faces` are EXPLICIT triangle sets — the paint-mode safety net, the
//     guarantee that a bad auto-segmentation is never a dead end. Each set is
//     appended as a NEW pseudo-face above the segmentation's ids, so a painted
//     selection is just another `face_id`: tag_step_face, mask_step_face, the
//     clearance rasterizer, the design box and the optimizer are all untouched,
//     because every one of them already keys on `triangle_face` alone.
//
// Determinism is a hard requirement (ids are persisted in a project and must
// survive a re-import). The sidecar is canonical text, triangle indices are
// stored ascending, and `paint_faces` are appended in list order.

struct FaceOverrides {
  // Base-segmentation retuning. `dihedral_threshold_deg <= 0` leaves the
  // SegmentOptions default (35). `planar_region_cone_deg < 0` means "unset"
  // (leave the default 40) — note 0 is a MEANINGFUL value there (disable the
  // planar cone), which is why the sentinel is negative rather than zero.
  double dihedral_threshold_deg = 0.0;
  double planar_region_cone_deg = -1.0;

  // Each inner vector holds the triangle indices (into the imported, welded
  // mesh's `triangles`) of ONE painted pseudo-face, ascending. The outer order
  // is the order ids are appended, and is part of the contract.
  std::vector<std::vector<int>> paint_faces;

  bool empty() const {
    return dihedral_threshold_deg <= 0.0 && planar_region_cone_deg < 0.0 &&
           paint_faces.empty();
  }
};

// The SegmentOptions implied by `ov`: defaults, with the two retuning fields
// applied when set. This is what an import should segment a mesh with so that a
// re-import reproduces what the user saw.
SegmentOptions segment_options_from(const FaceOverrides& ov);

// Append each painted triangle set to `model` as a new pseudo-face: reassign
// those triangles' `triangle_face` to a fresh id (face_count, face_count+1, ...),
// append a `fit_pseudo_face` StepFaceInfo for each, and bump `face_count`. A
// triangle named by a painted set is MOVED to it (a triangle belongs to exactly
// one face — the app's "a face belongs to one group" rule; if two painted sets
// name the same triangle, the later set wins, matching last-stroke-wins paint).
//
// Empty `ov.paint_faces` leaves `model` byte-identical. Throws
// std::invalid_argument if a triangle index is out of range or a painted set is
// empty (an empty selection is never a face).
void apply_face_overrides(StepModel& model, const FaceOverrides& ov);

// The sidecar path for a model path: the model path with ".faces" appended (a
// sibling file, e.g. "part.stl" -> "part.stl.faces"). A pure string function; it
// does not touch the filesystem.
std::string face_overrides_sidecar_path(const std::string& model_path);

// Serialize / parse the canonical sidecar text. `save` overwrites `path`.
// `load` returns an empty FaceOverrides if the file does not exist (the common
// case — no tuning, no paint), and throws std::runtime_error on a file that
// exists but is malformed (a corrupt sidecar must fail loudly, never silently
// drop a user's painted Load face). No JSON dependency (ARCHITECTURE locks the
// dependency set): a tiny line-based format, one directive per line.
void save_face_overrides(const std::string& path, const FaceOverrides& ov);
FaceOverrides load_face_overrides(const std::string& path);

// import_part_file(path), then apply the sidecar sitting next to `path` if one
// exists. This is the resolved-model choke point the bridge and run_job route
// through so live tagging, keep-clear and the run all agree with the partition
// the user saw and painted. With no sidecar it is exactly import_part_file.
StepModel import_part_file_resolved(const std::string& path,
                                    const StepTessellation& tess = {});

}  // namespace topopt
