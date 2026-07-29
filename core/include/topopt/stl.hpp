#pragma once

#include <cstdint>
#include <fstream>
#include <stdexcept>
#include <string>

#include "topopt/mesh.hpp"

namespace topopt {

// Which on-disk STL encoding a file was detected as.
enum class StlFormat { Ascii, Binary };

// Thrown for any STL import failure: an unreadable file, malformed or truncated
// data, or (from import_stl_file) a mesh that fails the watertight check. The
// message describes the cause.
class StlError : public std::runtime_error {
 public:
  explicit StlError(const std::string& msg) : std::runtime_error(msg) {}
};

// A parsed STL: the welded mesh plus the encoding it was read from.
struct StlMesh {
  TriangleMesh mesh;
  StlFormat format = StlFormat::Ascii;
};

// Read an STL file (ASCII or binary, auto-detected) into a welded TriangleMesh.
// This parses geometry only and does NOT enforce watertightness, so a caller
// can inspect an open mesh's WatertightReport. Throws StlError if the file
// cannot be opened or the data is malformed / truncated.
StlMesh read_stl_file(const std::string& path);

// Read the file and require the result to be watertight (closed + 2-manifold).
// Returns the mesh on success; throws StlError with a diagnostic naming the
// boundary and non-manifold edge counts otherwise. This is the pipeline's STL
// entry point (ARCHITECTURE.md §5: import -> watertight check).
TriangleMesh import_stl_file(const std::string& path);

// Write `mesh` to an STL file (ROADMAP M6.1, secondary export format;
// ARCHITECTURE §4 "STL secondary"). `format` selects the on-disk encoding:
// Binary (default) stores each coordinate as a 32-bit float (the standard STL
// precision); Ascii writes full double precision. Each facet's normal is
// computed from its winding (a degenerate triangle gets a zero normal);
// topopt's own reader ignores it, but other tools expect it. Vertex order and
// triangle winding are preserved verbatim, so a mesh that is watertight before
// export re-imports (read_stl_file, which welds by exact coordinate) watertight.
// Throws StlError if the file cannot be opened for writing.
void write_stl_file(const std::string& path, const TriangleMesh& mesh,
                    StlFormat format = StlFormat::Binary);

// A STREAMING binary-STL writer (handoff 2026-07-28-lattice-generation-production).
// A TriangleSink that writes each triangle's 50-byte facet record straight to disk
// and holds NO mesh, so peak memory is flat in the output size — the property that
// lets a multi-gigabyte lattice be a disk cost, not a memory cost. The on-disk
// bytes are IDENTICAL to write_stl_file(mesh, Binary) fed the same triangles in the
// same order: the same 80-byte "topopt binary STL export" header, the same
// winding-derived facet normal, the same little-endian float record. The triangle
// count is unknown until the end, so it is written as a placeholder at offset 80
// and patched by a seek-back in finish() (which the destructor also calls). After
// finish() the writer is closed; further add_triangle() throws.
//
// The output is an UNSHARED triangle soup (three fresh vertices per triangle, like
// every binary STL body); topology is only defined after a reader welds by
// coordinate. That is exactly how the harness (and the certified print) emitted the
// lattice, so the union with the part shell is the interpenetrating soup the slicer
// accepts.
class StreamingStlWriter : public TriangleSink {
 public:
  // Open `path` and write the 80-byte header + placeholder triangle count. Throws
  // StlError if the file cannot be opened for writing.
  explicit StreamingStlWriter(const std::string& path);
  ~StreamingStlWriter() override;  // finish() if not already called (best-effort)

  StreamingStlWriter(const StreamingStlWriter&) = delete;
  StreamingStlWriter& operator=(const StreamingStlWriter&) = delete;

  // Append one facet. Throws StlError after finish(), or on a write failure.
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override;

  // Patch the header count and close the file. Idempotent. Throws StlError on a
  // seek/write/close failure (a truncated file would otherwise pass silently).
  void finish();

  std::uint32_t triangle_count() const { return count_; }

 private:
  std::ofstream os_;
  std::string path_;
  std::uint32_t count_ = 0;
  bool finished_ = false;
};

}  // namespace topopt
