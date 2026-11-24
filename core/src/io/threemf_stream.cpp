// Streaming 3MF writer (handoff 2026-07-28-lattice-generation-production). See
// topopt/threemf_stream.hpp for the design. Self-contained: a minimal OPC/zip
// packager (STORED entries, no data descriptor) over a temp-file model part.

#include "topopt/threemf_stream.hpp"

#include <cstdio>
#include <cstring>
#include <vector>

#ifdef TOPOPT_HAVE_ZLIB
#include <zlib.h>
#endif

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
  std::uint64_t size = 0;  // uncompressed size
  std::uint64_t csize = 0;   // compressed size (== size when stored)
  std::uint16_t method = 0;  // 0 stored, 8 deflated (OF5)
  std::uint32_t offset = 0;  // local-header offset, filled during write
  bool from_temp = false;    // model part: data lives in the temp file
};

std::string local_header(const ZipEntry& e) {
  std::string h;
  le32(h, 0x04034b50u);        // local file header signature
  le16(h, 20);                 // version needed to extract (2.0)
  le16(h, 0);                  // general purpose flags (none; sizes known)
  le16(h, e.method);           // compression method 0 = store, 8 = deflate
  le16(h, 0);                  // mod time (fixed -> deterministic)
  le16(h, 0);                  // mod date (fixed -> deterministic)
  le32(h, e.crc);
  le32(h, static_cast<std::uint32_t>(e.csize));  // compressed size
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
  le16(h, e.method);           // method (store or deflate)
  le16(h, 0);                  // mod time
  le16(h, 0);                  // mod date
  le32(h, e.crc);
  le32(h, static_cast<std::uint32_t>(e.csize));
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

// P3: the same head declaring PrusaSlicer's namespace (its enforcer mark is slic3rpe:custom_supports).
const char* kModelHeadPainted =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n"
    "<model unit=\"millimeter\" xml:lang=\"en-US\" "
    "xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\" "
    "xmlns:slic3rpe=\"http://schemas.slic3r.org/3mf/2017/06\">\r\n"
    " <resources>\r\n  <object id=\"1\" type=\"model\">\r\n   <mesh>\r\n"
    "    <vertices>\r\n";

std::string xml_escaped(const std::string& s) {
  std::string o;
  for (const char ch : s) {
    if (ch == '&') o += "&amp;";
    else if (ch == '<') o += "&lt;";
    else if (ch == '>') o += "&gt;";
    else if (ch == '"') o += "&quot;";
    else o += ch;
  }
  return o;
}

}  // namespace

StreamingThreeMfWriter::StreamingThreeMfWriter(const std::string& path)
    : StreamingThreeMfWriter(path, Options{}) {}

bool StreamingThreeMfWriter::deflate_available() {
#ifdef TOPOPT_HAVE_ZLIB
  return true;
#else
  return false;
#endif
}

StreamingThreeMfWriter::StreamingThreeMfWriter(const std::string& path, const Options& options)
    : path_(path), tmp_path_(path + ".model.tmp"), options_(options) {
  model_.open(tmp_path_, std::ios::binary);
  if (!model_)
    throw ThreeMfStreamError("cannot open 3MF model temp file: " + tmp_path_);
  if (options_.indexed) {
    tris_path_ = path + ".tris.tmp";
    tris_.open(tris_path_, std::ios::binary);
    if (!tris_) throw ThreeMfStreamError("cannot open 3MF triangle temp file: " + tris_path_);
  }
  // Fail fast if the final path is unwritable, before streaming a large temp.
  {
    std::ofstream probe(path_, std::ios::binary);
    if (!probe)
      throw ThreeMfStreamError("cannot open 3MF file for writing: " + path_);
  }
  const char* head = options_.supports ? kModelHeadPainted : kModelHead;
  put(head, std::strlen(head));
}

void StreamingThreeMfWriter::put(const char* s, std::size_t n) {
  model_.write(s, static_cast<std::streamsize>(n));
  if (!model_)
    throw ThreeMfStreamError("failed writing 3MF model temp: " + tmp_path_);
  model_crc_ = crc_update(model_crc_, s, n);
  model_len_ += n;
}

void StreamingThreeMfWriter::put(const std::string& s) { put(s.data(), s.size()); }

std::uint64_t StreamingThreeMfWriter::add_vertex(const Vec3& v) {
  if (finished_ || !options_.indexed)
    throw ThreeMfStreamError("StreamingThreeMfWriter: add_vertex needs an indexed writer not yet finished");
  char buf[192];
  const int n = std::snprintf(buf, sizeof(buf), "     <vertex x=\"%.6f\" y=\"%.6f\" z=\"%.6f\"/>\r\n", v.x, v.y, v.z);
  put(buf, static_cast<std::size_t>(n));
  return vert_count_++;
}

void StreamingThreeMfWriter::add_indexed(std::uint64_t a, std::uint64_t b, std::uint64_t c) {
  add_indexed(a, b, c, false);
}

void StreamingThreeMfWriter::add_indexed(std::uint64_t a, std::uint64_t b, std::uint64_t c, bool paint) {
  if (finished_ || !options_.indexed)
    throw ThreeMfStreamError("StreamingThreeMfWriter: add_indexed needs an indexed writer not yet finished");
  if (a >= vert_count_ || b >= vert_count_ || c >= vert_count_)
    throw ThreeMfStreamError("StreamingThreeMfWriter: a triangle names a vertex not yet added");
  if (paint && !options_.supports)
    throw ThreeMfStreamError("StreamingThreeMfWriter: a painted triangle needs Options::supports");
  char buf[192];
  // P3: a whole triangle painted as a support enforcer: "4" in both slicers' triangle-selector code (state 1 << 2).
  const int n = std::snprintf(buf, sizeof(buf),
                              paint ? "     <triangle v1=\"%llu\" v2=\"%llu\" v3=\"%llu\" paint_supports=\"4\" "
                                      "slic3rpe:custom_supports=\"4\"/>\r\n"
                                    : "     <triangle v1=\"%llu\" v2=\"%llu\" v3=\"%llu\"/>\r\n",
                              static_cast<unsigned long long>(a), static_cast<unsigned long long>(b),
                              static_cast<unsigned long long>(c));
  painted_ += paint ? 1 : 0;
  tris_.write(buf, n);
  if (!tris_) throw ThreeMfStreamError("failed writing 3MF triangle temp: " + tris_path_);
  tris_len_ += static_cast<std::uint64_t>(n);
  ++tri_count_;
}

void StreamingThreeMfWriter::add_triangle(const Vec3& a, const Vec3& b,
                                          const Vec3& c) {
  if (finished_)
    throw ThreeMfStreamError("StreamingThreeMfWriter: add_triangle after finish()");
  if (options_.indexed) {
    const std::uint64_t i = add_vertex(a), j = add_vertex(b), k = add_vertex(c);
    add_indexed(i, j, k);
    return;
  }
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
  if (options_.indexed) {
    tris_.flush();
    tris_.close();
    if (!tris_) throw ThreeMfStreamError("failed finalizing 3MF triangle temp: " + tris_path_);
    std::ifstream in(tris_path_, std::ios::binary);
    if (!in) throw ThreeMfStreamError("cannot re-open 3MF triangle temp: " + tris_path_);
    std::vector<char> chunk(1 << 16);
    while (in) {
      in.read(chunk.data(), static_cast<std::streamsize>(chunk.size()));
      const std::streamsize got = in.gcount();
      if (got > 0) put(chunk.data(), static_cast<std::size_t>(got));
    }
    in.close();
    std::remove(tris_path_.c_str());
  }
  for (std::uint64_t i = 0; !options_.indexed && i < tri_count_; ++i) {
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
  entries[2].csize = model_len_;
  entries[2].crc = model_crc;
  entries[0].crc = crc32_of(entries[0].data);
  entries[0].size = entries[0].csize = entries[0].data.size();
  entries[1].crc = crc32_of(entries[1].data);
  entries[1].size = entries[1].csize = entries[1].data.size();
  // P3: support ON for the object, only the painted places supported (Bambu / Orca, then PrusaSlicer). PrusaSlicer
  // builds an object's volumes from its config, so its one volume names every triangle.
  if (options_.supports) {
    const std::string name = xml_escaped(options_.object_name);
    ZipEntry bambu, prusa;
    bambu.name = "Metadata/model_settings.config";
    bambu.data = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n  <object id=\"1\">\n"
                 "    <metadata key=\"name\" value=\"" + name + "\"/>\n"
                 "    <metadata key=\"enable_support\" value=\"1\"/>\n"
                 "    <metadata key=\"support_type\" value=\"" + xml_escaped(options_.support_type) + "\"/>\n"
                 "  </object>\n</config>\n";
    prusa.name = "Metadata/Slic3r_PE_model.config";
    prusa.data = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n <object id=\"1\" instances_count=\"1\">\n"
                 "  <metadata type=\"object\" key=\"name\" value=\"" + name + "\"/>\n"
                 "  <metadata type=\"object\" key=\"support_material\" value=\"1\"/>\n"
                 "  <metadata type=\"object\" key=\"support_material_auto\" value=\"0\"/>\n"
                 "  <volume firstid=\"0\" lastid=\"" + std::to_string(tri_count_ > 0 ? tri_count_ - 1 : 0) + "\">\n"
                 "   <metadata type=\"volume\" key=\"name\" value=\"" + name + "\"/>\n"
                 "  </volume>\n </object>\n</config>\n";
    for (ZipEntry* e : {&bambu, &prusa}) {
      e->crc = crc32_of(e->data);
      e->size = e->csize = e->data.size();
      entries.push_back(*e);
    }
  }
#ifdef TOPOPT_HAVE_ZLIB
  if (options_.deflate) entries[2].method = 8;
#endif

  std::ofstream zip(path_, std::ios::binary | std::ios::trunc);
  if (!zip) throw ThreeMfStreamError("cannot open 3MF file for writing: " + path_);

  std::uint32_t offset = 0;
  for (auto& e : entries) {
    e.offset = offset;
    const std::string lh = local_header(e);
    zip.write(lh.data(), static_cast<std::streamsize>(lh.size()));
    offset += static_cast<std::uint32_t>(lh.size());
    if (e.from_temp && e.method == 8) {
#ifdef TOPOPT_HAVE_ZLIB
      // OF5: deflated as it is copied; the compressed size is written back into the local header after.
      std::ifstream in(tmp_path_, std::ios::binary);
      if (!in) throw ThreeMfStreamError("cannot re-open 3MF model temp: " + tmp_path_);
      z_stream zs;
      std::memset(&zs, 0, sizeof zs);
      if (deflateInit2(&zs, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK)
        throw ThreeMfStreamError("cannot start deflating the 3MF model");
      std::vector<unsigned char> src(1 << 16), dst(1 << 16);
      std::uint64_t written = 0;
      bool more = true;
      while (more) {
        in.read(reinterpret_cast<char*>(src.data()), static_cast<std::streamsize>(src.size()));
        const std::streamsize got = in.gcount();
        more = static_cast<bool>(in) && got > 0;
        zs.next_in = src.data();
        zs.avail_in = static_cast<uInt>(got);
        const int flush = more ? Z_NO_FLUSH : Z_FINISH;
        int rc = Z_OK;
        do {
          zs.next_out = dst.data();
          zs.avail_out = static_cast<uInt>(dst.size());
          rc = deflate(&zs, flush);
          if (rc == Z_STREAM_ERROR) { deflateEnd(&zs); throw ThreeMfStreamError("deflating the 3MF model failed"); }
          const std::size_t have = dst.size() - zs.avail_out;
          zip.write(reinterpret_cast<const char*>(dst.data()), static_cast<std::streamsize>(have));
          written += have;
        } while (zs.avail_out == 0);
        if (!more && rc != Z_STREAM_END) { deflateEnd(&zs); throw ThreeMfStreamError("deflating the 3MF model did not end"); }
      }
      deflateEnd(&zs);
      e.csize = written;
      const std::streampos end = zip.tellp();
      zip.seekp(static_cast<std::streamoff>(e.offset) + 18);   // the local header's compressed size
      std::string cs;
      le32(cs, static_cast<std::uint32_t>(e.csize));
      zip.write(cs.data(), 4);
      zip.seekp(end);
      offset += static_cast<std::uint32_t>(e.csize);
      compressed_ = true;
#endif
    } else if (e.from_temp) {
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
  if (tris_.is_open()) tris_.close();
  if (!finished_) {   // clean a half-written temp
    std::remove(tmp_path_.c_str());
    if (!tris_path_.empty()) std::remove(tris_path_.c_str());
  }
}

}  // namespace topopt
