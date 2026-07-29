#pragma once

// STREAMING 3MF writer (handoff 2026-07-28-lattice-generation-production).
//
// A TriangleSink that writes a valid 3MF (an OPC/zip package) with peak memory
// FLAT in the output size — the same streaming guarantee as StreamingStlWriter,
// so a multi-gigabyte lattice is a disk cost, not a memory cost. This exists
// because the production 3MF writer (topopt/threemf.hpp, write_3mf_file) is
// lib3mf-backed and builds the WHOLE mesh in RAM first; PR 201 confirmed lib3mf is
// not streamable, so re-using it would silently reintroduce the memory wall this
// feature was closed on. This writer never holds the mesh.
//
// HOW it streams without buffering the mesh in RAM: the 3D/3dmodel.model XML part
// is streamed to a TEMPORARY FILE on disk (flat RAM, incremental CRC-32 and byte
// count), then copied into a minimal hand-rolled zip as a STORED (uncompressed)
// entry whose CRC/size are therefore known before its local header — no
// general-purpose "data descriptor", which the widest set of zip readers accept.
// The mesh is written as an UNSHARED triangle soup (three fresh vertices per
// triangle, indices 3i/3i+1/3i+2), matching the STL body and the interpenetrating
// union the slicer accepts. This writer depends on NOTHING but the C++ stdlib
// (no lib3mf), so it is always available; write_3mf_file remains the lib3mf path
// for small in-memory meshes and for re-import (read_3mf_file).
//
// TRADE-OFF (honest): a STORED zip is uncompressed, so a streaming .3mf is larger
// on disk than a lib3mf-deflated one. That is the price of not holding the mesh in
// RAM; the STL is the primary, most compact streaming artifact.

#include <cstdint>
#include <fstream>
#include <stdexcept>
#include <string>

#include "topopt/mesh.hpp"  // Vec3, TriangleSink

namespace topopt {

// Thrown for any streaming-3MF write failure (unopenable output/temp file, a
// write/close error). Distinct from ThreeMfError (the lib3mf path) so a caller can
// tell which writer failed.
class ThreeMfStreamError : public std::runtime_error {
 public:
  explicit ThreeMfStreamError(const std::string& msg) : std::runtime_error(msg) {}
};

class StreamingThreeMfWriter : public TriangleSink {
 public:
  // Open `path` (the .3mf) and begin the model part in a sibling temp file
  // (`path` + ".model.tmp"). Throws ThreeMfStreamError if either cannot be opened.
  explicit StreamingThreeMfWriter(const std::string& path);
  ~StreamingThreeMfWriter() override;  // removes the temp file if still present

  StreamingThreeMfWriter(const StreamingThreeMfWriter&) = delete;
  StreamingThreeMfWriter& operator=(const StreamingThreeMfWriter&) = delete;

  // Append one triangle as three fresh vertices. Throws after finish().
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override;

  // Close the model XML, assemble the zip package, and remove the temp file.
  // Idempotent. Throws ThreeMfStreamError on any I/O failure.
  void finish();

  std::uint64_t triangle_count() const { return tri_count_; }

 private:
  void put(const char* s, std::size_t n);   // write to model temp + update crc/len
  void put(const std::string& s);

  std::string path_;
  std::string tmp_path_;
  std::ofstream model_;        // the streamed 3D/3dmodel.model part
  std::uint64_t tri_count_ = 0;
  std::uint64_t model_len_ = 0;
  std::uint32_t model_crc_ = 0xFFFFFFFFu;  // in-progress CRC-32 (pre-final XOR)
  bool finished_ = false;
};

}  // namespace topopt
