#pragma once

#include <stdexcept>
#include <string>

#include "topopt/mesh.hpp"

namespace topopt {

// Thrown for any 3MF import/export failure: a file that cannot be opened or
// written, a malformed package, or (from read_3mf_file) a package with no mesh
// object. The message describes the cause and wraps the underlying lib3mf error.
class ThreeMfError : public std::runtime_error {
 public:
  explicit ThreeMfError(const std::string& msg) : std::runtime_error(msg) {}
};

// Write `mesh` to a 3MF file via lib3mf (ROADMAP M6.1, primary export format;
// ARCHITECTURE §4 "3MF primary (lib3mf)"). The mesh becomes a single mesh
// object referenced by one build item with the identity transform. 3MF stores
// coordinates as 32-bit floats, so a re-import (read_3mf_file) reproduces the
// geometry to float precision; vertex order and triangle winding are preserved,
// so a watertight mesh round-trips watertight. Throws ThreeMfError on any lib3mf
// failure (e.g. the output path cannot be written).
void write_3mf_file(const std::string& path, const TriangleMesh& mesh);

// Read the first mesh object of a 3MF file via lib3mf into a TriangleMesh
// (ROADMAP M6.1 round-trip: export -> re-import). Vertices and triangle indices
// are taken as stored (lib3mf does not re-weld), so this is the inverse of
// write_3mf_file. Throws ThreeMfError if the file cannot be read or contains no
// mesh object.
TriangleMesh read_3mf_file(const std::string& path);

}  // namespace topopt
