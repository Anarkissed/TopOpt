#pragma once

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

}  // namespace topopt
