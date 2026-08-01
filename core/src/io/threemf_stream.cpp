// Streaming 3MF writer (handoff 2026-07-28-lattice-generation-production). See
// topopt/threemf_stream.hpp for the design. Self-contained: a minimal OPC/zip
// packager (STORED entries, no data descriptor) over a temp-file model part.

#include "topopt/threemf_stream.hpp"

#include <cstdio>
#include <cstring>
#include <vector>

namespace topopt {
namespace {

// --- CRC-32 (IEEE 802.3, the zip/OPC polynomial), reflected table ------------
const std::uint32_t* crc_table() {
  static std::uint32_t t[256];
  static bool built = false;
  if (!built) {
    for (std::uint32_t i = 0; i < 256; ++i) {
      std::uint32_t c = i;
      for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      t[i] = c;
    }
    built = true;
  }
  return t;
}

// Update a running CRC (pre-final-XOR state, i.e. start at 0xFFFFFFFF, XOR
// 0xFFFFFFFF at the end).
std::uint32_t crc_update(std::uint32_t crc, const char* p, std::size_t n) {
  const std::uint32_t* t = crc_table();
  const unsigned char* u = reinterpret_cast<const unsigned char*>(p);
  for (std::size_t i = 0; i < n; ++i) crc = t[(crc ^ u[i]) & 0xFF] ^ (crc >> 8);
  return crc;
}

std::uint32_t crc32_of(const std::string& s) {
  return crc_update(0xFFFFFFFFu, s.data(), s.size()) ^ 0xFFFFFFFFu;
}

// --- Little-endian field appenders (zip is little-endian) --------------------
void le16(std::string& out, std::uint16_t v) {
  out.push_back(static_cast<char>(v & 0xFF));
  out.push_back(static_cast<char>((v >> 8) & 0xFF));
}
void le32(std::string& out, std::uint32_t v) {
  out.push_back(static_cast<char>(v & 0xFF));
  out.push_back(static_cast<char>((v >> 8) & 0xFF));
  out.push_back(static_cast<char>((v >> 16) & 0xFF));
  out.push_back(static_cast<char>((v >> 24) & 0xFF));
}

// One STORED zip entry, ready to serialize.
struct ZipEntry {
  std::string name;
  std::string data;   // empty for the streamed model part (copied from temp)
  std::uint32_t crc = 0;
  std::uint64_t size = 0;  // == compressed size (stored)
  std::uint32_t offset = 0;  // local-header offset, filled during write
  bool from_temp = false;    // model part: data lives in the temp file
};

std::string local_header(const ZipEntry& e) {
  std::string h;
  le32(h, 0x04034b50u);        // local file header signature
  le16(h, 20);                 // version needed to extract (2.0)
  le16(h, 0);                  // general purpose flags (none; sizes known)
  le16(h, 0);                  // compression method 0 = store
  le16(h, 0);                  // mod time (fixed -> deterministic)
  le16(h, 0);                  // mod date (fixed -> deterministic)
  le32(h, e.crc);
  le32(h, static_cast<std::uint32_t>(e.size));   // compressed size
  le32(h, static_cast<std::uint32_t>(e.size));   // uncompressed size
  le16(h, static_cast<std::uint16_t>(e.name.size()));
  le16(h, 0);                  // extra field length
  h += e.name;
  return h;
}

std::string central_header(const ZipEntry& e) {
  std::string h;
  le32(h, 0x02014b50u);        // central directory header signature
  le16(h, 20);                 // version made by
  le16(h, 20);                 // version needed
  le16(h, 0);                  // flags
  le16(h, 0);                  // method (store)
  le16(h, 0);                  // mod time
  le16(h, 0);                  // mod date
  le32(h, e.crc);
  le32(h, static_cast<std::uint32_t>(e.size));
  le32(h, static_cast<std::uint32_t>(e.size));
  le16(h, static_cast<std::uint16_t>(e.name.size()));
  le16(h, 0);                  // extra length
  le16(h, 0);                  // comment length
  le16(h, 0);                  // disk number start
  le16(h, 0);                  // internal attributes
  le32(h, 0);                  // external attributes
  le32(h, e.offset);           // local header offset
  h += e.name;
  return h;
}

const char* kContentTypes =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n"
    "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
    "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-"
    "package.relationships+xml\"/>"
    "<Default Extension=\"model\" ContentType=\"application/vnd.ms-package."
    "3dmanufacturing-3dmodel+xml\"/></Types>";

const char* kRels =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n"
    "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/"
    "relationships\">"
    "<Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" "
    "Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>"
    "</Relationships>";

const char* kModelHead =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n"
    "<model unit=\"millimeter\" xml:lang=\"en-US\" "
    "xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\r\n"
    " <resources>\r\n  <object id=\"1\" type=\"model\">\r\n   <mesh>\r\n"
    "    <vertices>\r\n";

}  // namespace

StreamingThreeMfWriter::StreamingThreeMfWriter(const std::string& path)
    : path_(path), tmp_path_(path + ".model.tmp") {
  model_.open(tmp_path_, std::ios::binary);
  if (!model_)
    throw ThreeMfStreamError("cannot open 3MF model temp file: " + tmp_path_);
  // Fail fast if the final path is unwritable, before streaming a large temp.
  {
    std::ofstream probe(path_, std::ios::binary);
    if (!probe)
      throw ThreeMfStreamError("cannot open 3MF file for writing: " + path_);
  }
  put(kModelHead, std::strlen(kModelHead));
}

void StreamingThreeMfWriter::put(const char* s, std::size_t n) {
  model_.write(s, static_cast<std::streamsize>(n));
  if (!model_)
    throw ThreeMfStreamError("failed writing 3MF model temp: " + tmp_path_);
  model_crc_ = crc_update(model_crc_, s, n);
  model_len_ += n;
}

void StreamingThreeMfWriter::put(const std::string& s) { put(s.data(), s.size()); }

void StreamingThreeMfWriter::add_triangle(const Vec3& a, const Vec3& b,
                                          const Vec3& c) {
  if (finished_)
    throw ThreeMfStreamError("StreamingThreeMfWriter: add_triangle after finish()");
  char buf[192];
  const Vec3* vs[3] = {&a, &b, &c};
  for (const Vec3* v : vs) {
    // Fixed 6-decimal form: deterministic and non-scientific (some slicer XML
    // parsers dislike exponents); ~1e-6 mm precision, matching lib3mf's fidelity.
    const int n = std::snprintf(buf, sizeof(buf),
                                "     <vertex x=\"%.6f\" y=\"%.6f\" z=\"%.6f\"/>\r\n",
                                v->x, v->y, v->z);
    put(buf, static_cast<std::size_t>(n));
  }
  ++tri_count_;
}

void StreamingThreeMfWriter::finish() {
  if (finished_) return;
  finished_ = true;

  // Close vertices, emit the triangle refs (implicit soup indices), close model.
  put("    </vertices>\r\n    <triangles>\r\n");
  char buf[128];
  for (std::uint64_t i = 0; i < tri_count_; ++i) {
    const unsigned long long b = 3ull * i;
    const int n = std::snprintf(
        buf, sizeof(buf), "     <triangle v1=\"%llu\" v2=\"%llu\" v3=\"%llu\"/>\r\n",
        b, b + 1, b + 2);
    put(buf, static_cast<std::size_t>(n));
  }
  // The build item carries NO transform, which 3MF reads as the identity —
  // deliberately and permanently (handoff 2026-08-01-bake-build-orientation). A
  // build transform is ADVICE that "place on bed" / "auto-orient" / "arrange"
  // reset, so an orientation living here is one the slicer may discard. The
  // certified orientation is baked into the VERTICES upstream (run_job wraps
  // this sink in a RotatingTriangleSink), and this stays identity as belt and
  // braces. Do NOT add a transform attribute here.
  put("    </triangles>\r\n   </mesh>\r\n  </object>\r\n </resources>\r\n"
      " <build>\r\n  <item objectid=\"1\"/>\r\n </build>\r\n</model>\r\n");
  model_.flush();
  model_.close();
  if (!model_)
    throw ThreeMfStreamError("failed finalizing 3MF model temp: " + tmp_path_);
  const std::uint32_t model_crc = model_crc_ ^ 0xFFFFFFFFu;

  // Assemble the package.
  std::vector<ZipEntry> entries(3);
  entries[0].name = "[Content_Types].xml";
  entries[0].data = kContentTypes;
  entries[1].name = "_rels/.rels";
  entries[1].data = kRels;
  entries[2].name = "3D/3dmodel.model";
  entries[2].from_temp = true;
  entries[2].size = model_len_;
  entries[2].crc = model_crc;
  entries[0].crc = crc32_of(entries[0].data);
  entries[0].size = entries[0].data.size();
  entries[1].crc = crc32_of(entries[1].data);
  entries[1].size = entries[1].data.size();

  std::ofstream zip(path_, std::ios::binary | std::ios::trunc);
  if (!zip) throw ThreeMfStreamError("cannot open 3MF file for writing: " + path_);

  std::uint32_t offset = 0;
  for (auto& e : entries) {
    e.offset = offset;
    const std::string lh = local_header(e);
    zip.write(lh.data(), static_cast<std::streamsize>(lh.size()));
    offset += static_cast<std::uint32_t>(lh.size());
    if (e.from_temp) {
      std::ifstream in(tmp_path_, std::ios::binary);
      if (!in) throw ThreeMfStreamError("cannot re-open 3MF model temp: " + tmp_path_);
      char chunk[1 << 16];
      while (in) {
        in.read(chunk, sizeof(chunk));
        const std::streamsize got = in.gcount();
        if (got > 0) zip.write(chunk, got);
      }
      offset += static_cast<std::uint32_t>(e.size);
    } else {
      zip.write(e.data.data(), static_cast<std::streamsize>(e.data.size()));
      offset += static_cast<std::uint32_t>(e.data.size());
    }
    if (!zip) throw ThreeMfStreamError("failed writing 3MF package: " + path_);
  }

  const std::uint32_t cd_offset = offset;
  std::string cd;
  for (const auto& e : entries) cd += central_header(e);
  zip.write(cd.data(), static_cast<std::streamsize>(cd.size()));

  std::string eocd;
  le32(eocd, 0x06054b50u);                        // EOCD signature
  le16(eocd, 0);                                  // disk number
  le16(eocd, 0);                                  // cd start disk
  le16(eocd, static_cast<std::uint16_t>(entries.size()));  // entries this disk
  le16(eocd, static_cast<std::uint16_t>(entries.size()));  // total entries
  le32(eocd, static_cast<std::uint32_t>(cd.size()));       // cd size
  le32(eocd, cd_offset);                          // cd offset
  le16(eocd, 0);                                  // comment length
  zip.write(eocd.data(), static_cast<std::streamsize>(eocd.size()));
  zip.flush();
  if (!zip) throw ThreeMfStreamError("failed writing 3MF directory: " + path_);
  zip.close();
  if (!zip) throw ThreeMfStreamError("failed closing 3MF file: " + path_);

  std::remove(tmp_path_.c_str());
}

StreamingThreeMfWriter::~StreamingThreeMfWriter() {
  if (model_.is_open()) model_.close();
  if (!finished_) std::remove(tmp_path_.c_str());  // clean a half-written temp
}

}  // namespace topopt
