// rss_probe.cpp — P2 evidence harness (handoff 2026-07-28-lattice-generation).
// NOT a CI test. Streams a full N^3 octet block (cell L, radius r) to a binary STL
// (and optionally a streaming 3MF) via the PRODUCTION generator + streaming
// writers, and reports peak RSS (getrusage high-water mark), output size and wall
// time. One process per size so ru_maxrss is that run's own peak. If peak RSS
// stays flat while the output grows past 100 MB, streaming survived the move to
// production (the property PR 201 measured and BLOCKED-STOP protects).
//
// Build: see build_rss_probe.sh. Run: rss_probe <N> <L_mm> <r_mm> <out.stl> [3mf]

#include <sys/resource.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

#include "topopt/lattice_gen.hpp"
#include "topopt/stl.hpp"
#include "topopt/threemf_stream.hpp"

using namespace topopt;

static double peak_rss_mb() {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return static_cast<double>(ru.ru_maxrss) / (1024.0 * 1024.0);  // bytes on macOS
}
static double now_s() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}
static long file_size(const std::string& p) {
  FILE* f = std::fopen(p.c_str(), "rb");
  if (!f) return -1;
  std::fseek(f, 0, SEEK_END);
  long n = std::ftell(f);
  std::fclose(f);
  return n;
}

int main(int argc, char** argv) {
  if (argc < 5) {
    std::fprintf(stderr, "usage: %s <N> <L_mm> <r_mm> <out.stl> [3mf]\n", argv[0]);
    return 2;
  }
  const int N = std::atoi(argv[1]);
  const double L = std::atof(argv[2]);
  const double r = std::atof(argv[3]);
  const std::string out = argv[4];
  const bool do_3mf = argc > 5 && std::strcmp(argv[5], "3mf") == 0;

  LatticeRegion R;
  R.nx = R.ny = R.nz = N;
  R.cell_mm = L;
  R.latticed = nullptr;  // full block
  LatticeRadiusField G;
  G.uniform_mm = r;
  G.nseg = 8;

  const double rss_before = peak_rss_mb();
  const double t0 = now_s();
  LatticeGenStats st;
  {
    StreamingStlWriter w(out);
    st = generate_lattice(LatticeGenTopology::Octet, R, G, w);
    w.finish();
  }
  const double t_stl = now_s() - t0;
  const double rss_after_stl = peak_rss_mb();

  long mf_bytes = -1;
  double t_3mf = 0;
  double rss_after_3mf = rss_after_stl;
  if (do_3mf) {
    const std::string mf = out.substr(0, out.size() - 4) + ".3mf";
    const double t1 = now_s();
    StreamingThreeMfWriter w(mf);
    generate_lattice(LatticeGenTopology::Octet, R, G, w);
    w.finish();
    t_3mf = now_s() - t1;
    rss_after_3mf = peak_rss_mb();
    mf_bytes = file_size(mf);
  }

  std::printf(
      "N=%d L=%.1f r=%.2f cells=%lld tris=%llu | STL: %.1f MB %.3fs | "
      "peak_rss: before=%.1f afterSTL=%.1f%s MB",
      N, L, r, st.latticed_cells, (unsigned long long)st.triangles,
      file_size(out) / 1e6, t_stl, rss_before, rss_after_stl,
      do_3mf ? "" : "");
  if (do_3mf)
    std::printf(" | 3MF: %.1f MB %.3fs afterRSS=%.1f", mf_bytes / 1e6, t_3mf,
                rss_after_3mf);
  std::printf("\n");

  // Machine-parseable CSV row for the evidence table.
  if (const char* csv = std::getenv("RSS_CSV")) {
    FILE* f = std::fopen(csv, "a");
    if (f) {
      std::fprintf(f, "%d,%.1f,%.2f,%lld,%llu,%ld,%.3f,%.1f,%.1f,%ld,%.3f,%.1f\n",
                   N, L, r, st.latticed_cells, (unsigned long long)st.triangles,
                   file_size(out), t_stl, rss_before, rss_after_stl, mf_bytes,
                   t_3mf, rss_after_3mf);
      std::fclose(f);
    }
  }
  return 0;
}
