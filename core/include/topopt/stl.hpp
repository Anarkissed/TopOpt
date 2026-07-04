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

}  // namespace topopt
