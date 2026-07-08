#include "topopt/stl.hpp"

#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <ostream>
#include <iterator>
#include <map>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {
namespace {

// --- Little-endian byte decoding (binary STL is defined little-endian) -------
// Assembling the integer explicitly makes the parser correct regardless of the
// host's byte order.

uint32_t read_le_u32(const unsigned char* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

float read_le_float(const unsigned char* p) {
  uint32_t bits = read_le_u32(p);
  float f;
  std::memcpy(&f, &bits, sizeof(f));
  return f;
}

// Weld a flat list of raw per-facet vertices into a shared-vertex mesh. STL
// writes each vertex identically wherever facets meet, so exact-coordinate
// matching is the correct weld here (no epsilon — that would risk collapsing
// distinct nearby vertices). Insertion order is preserved for determinism.
TriangleMesh weld(const std::vector<Vec3>& raw) {
  TriangleMesh mesh;
  std::map<std::tuple<double, double, double>, int> index;
  auto id_of = [&](const Vec3& v) -> int {
    auto key = std::make_tuple(v.x, v.y, v.z);
    auto it = index.find(key);
    if (it != index.end()) return it->second;
    int idx = static_cast<int>(mesh.vertices.size());
    mesh.vertices.push_back(v);
    index.emplace(key, idx);
    return idx;
  };
  for (std::size_t i = 0; i + 2 < raw.size(); i += 3) {
    mesh.triangles.push_back(
        {id_of(raw[i]), id_of(raw[i + 1]), id_of(raw[i + 2])});
  }
  return mesh;
}

// Detect ASCII vs binary. An ASCII STL starts with the "solid" keyword and
// contains "facet" records. A binary STL's 80-byte header may coincidentally
// begin with "solid", so we additionally require the literal "facet" token that
// every ASCII file has and binary triangle data does not.
StlFormat detect_format(const std::string& bytes) {
  std::size_t i = 0;
  while (i < bytes.size() &&
         std::isspace(static_cast<unsigned char>(bytes[i]))) {
    ++i;
  }
  bool starts_solid = false;
  if (bytes.size() - i >= 5) {
    starts_solid = std::tolower(static_cast<unsigned char>(bytes[i])) == 's' &&
                   std::tolower(static_cast<unsigned char>(bytes[i + 1])) == 'o' &&
                   std::tolower(static_cast<unsigned char>(bytes[i + 2])) == 'l' &&
                   std::tolower(static_cast<unsigned char>(bytes[i + 3])) == 'i' &&
                   std::tolower(static_cast<unsigned char>(bytes[i + 4])) == 'd';
  }
  bool has_facet = bytes.find("facet") != std::string::npos;
  return (starts_solid && has_facet) ? StlFormat::Ascii : StlFormat::Binary;
}

std::vector<Vec3> parse_ascii(const std::string& bytes) {
  std::istringstream in(bytes);
  std::string tok;
  std::vector<Vec3> raw;
  while (in >> tok) {
    if (tok == "vertex") {
      Vec3 v;
      if (!(in >> v.x >> v.y >> v.z)) {
        throw StlError("malformed vertex line in ASCII STL");
      }
      raw.push_back(v);
    }
  }
  if (raw.size() % 3 != 0) {
    throw StlError("ASCII STL vertex count is not a multiple of 3");
  }
  return raw;
}

std::vector<Vec3> parse_binary(const std::string& bytes) {
  // 80-byte header + uint32 triangle count + 50 bytes per triangle
  // (normal[3] + vertex[3][3] floats + 2-byte attribute).
  if (bytes.size() < 84) {
    throw StlError("binary STL shorter than its 84-byte header");
  }
  const unsigned char* d = reinterpret_cast<const unsigned char*>(bytes.data());
  uint32_t n = read_le_u32(d + 80);
  std::size_t expected = 84 + static_cast<std::size_t>(n) * 50;
  if (bytes.size() != expected) {
    throw StlError("binary STL size does not match its declared triangle count");
  }
  std::vector<Vec3> raw;
  raw.reserve(static_cast<std::size_t>(n) * 3);
  std::size_t off = 84;
  for (uint32_t t = 0; t < n; ++t) {
    const unsigned char* p = d + off + 12;  // skip the 12-byte facet normal
    for (int v = 0; v < 3; ++v) {
      Vec3 vert;
      vert.x = read_le_float(p + v * 12 + 0);
      vert.y = read_le_float(p + v * 12 + 4);
      vert.z = read_le_float(p + v * 12 + 8);
      raw.push_back(vert);
    }
    off += 50;
  }
  return raw;
}

}  // namespace

StlMesh read_stl_file(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw StlError("cannot open STL file: " + path);
  std::string bytes((std::istreambuf_iterator<char>(f)),
                    std::istreambuf_iterator<char>());

  StlMesh out;
  out.format = detect_format(bytes);
  std::vector<Vec3> raw = (out.format == StlFormat::Ascii) ? parse_ascii(bytes)
                                                           : parse_binary(bytes);
  out.mesh = weld(raw);
  return out;
}

TriangleMesh import_stl_file(const std::string& path) {
  StlMesh parsed = read_stl_file(path);
  WatertightReport r = check_watertight(parsed.mesh);
  if (!r.watertight) {
    throw StlError("STL mesh is not watertight: " +
                   std::to_string(r.boundary_edges) + " boundary edge(s), " +
                   std::to_string(r.non_manifold_edges) +
                   " non-manifold edge(s) in " + path);
  }
  return parsed.mesh;
}

namespace {

// --- Little-endian byte encoding (binary STL is defined little-endian) --------
// Mirror of the decoders above: assemble the bytes explicitly so the writer is
// correct regardless of the host's byte order.

void append_le_u32(std::string& out, uint32_t v) {
  out.push_back(static_cast<char>(v & 0xFF));
  out.push_back(static_cast<char>((v >> 8) & 0xFF));
  out.push_back(static_cast<char>((v >> 16) & 0xFF));
  out.push_back(static_cast<char>((v >> 24) & 0xFF));
}

void append_le_float(std::string& out, float f) {
  uint32_t bits;
  std::memcpy(&bits, &f, sizeof(bits));
  append_le_u32(out, bits);
}

// Facet normal from the triangle winding (right-hand rule). Returns a zero
// vector for a degenerate (zero-area) triangle rather than a NaN.
Vec3 facet_normal(const Vec3& a, const Vec3& b, const Vec3& c) {
  const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
  const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
  Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
  const double len = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
  if (len > 0.0) {
    n.x /= len;
    n.y /= len;
    n.z /= len;
  }
  return n;
}

void write_binary_stl(std::ostream& out, const TriangleMesh& mesh) {
  // 80-byte header. It must NOT begin with "solid" or the auto-detector would
  // misread the file as ASCII; a descriptive tag both documents the file and
  // avoids that ambiguity.
  std::string header = "topopt binary STL export";
  header.resize(80, '\0');
  out.write(header.data(), 80);

  std::string body;
  body.reserve(mesh.triangles.size() * 50);
  append_le_u32(body, static_cast<uint32_t>(mesh.triangles.size()));
  for (const auto& tri : mesh.triangles) {
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(tri[2])];
    const Vec3 n = facet_normal(a, b, c);
    append_le_float(body, static_cast<float>(n.x));
    append_le_float(body, static_cast<float>(n.y));
    append_le_float(body, static_cast<float>(n.z));
    for (const Vec3* v : {&a, &b, &c}) {
      append_le_float(body, static_cast<float>(v->x));
      append_le_float(body, static_cast<float>(v->y));
      append_le_float(body, static_cast<float>(v->z));
    }
    body.push_back('\0');  // 2-byte attribute byte count, 0
    body.push_back('\0');
  }
  out.write(body.data(), static_cast<std::streamsize>(body.size()));
}

// Full-precision (17 significant digits round-trips an IEEE-754 double) ASCII
// float formatting.
std::string ascii_num(double x) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.17g", x);
  return buf;
}

void write_ascii_stl(std::ostream& out, const TriangleMesh& mesh) {
  out << "solid topopt\n";
  for (const auto& tri : mesh.triangles) {
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(tri[2])];
    const Vec3 n = facet_normal(a, b, c);
    out << "  facet normal " << ascii_num(n.x) << ' ' << ascii_num(n.y) << ' '
        << ascii_num(n.z) << "\n    outer loop\n";
    for (const Vec3* v : {&a, &b, &c}) {
      out << "      vertex " << ascii_num(v->x) << ' ' << ascii_num(v->y) << ' '
          << ascii_num(v->z) << '\n';
    }
    out << "    endloop\n  endfacet\n";
  }
  out << "endsolid topopt\n";
}

}  // namespace

void write_stl_file(const std::string& path, const TriangleMesh& mesh,
                    StlFormat format) {
  std::ofstream f(path, std::ios::binary);
  if (!f) throw StlError("cannot open STL file for writing: " + path);
  if (format == StlFormat::Binary) {
    write_binary_stl(f, mesh);
  } else {
    write_ascii_stl(f, mesh);
  }
  if (!f) throw StlError("failed writing STL file: " + path);
}

}  // namespace topopt
