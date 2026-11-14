// lattice_types_probe_shared.inc -- the C2b cantilever (transverse_K, macro_grid; VERBATIM
// from graded_cell_size_probe.cpp) and the 6-connected component count, shared by
// lattice_types_probe.cpp (struts) and tpms_probe.cpp (sheets) so each method is one copy.
// Included inside an anonymous namespace, after tensor_library_nine_probe.cpp.

// transverse_K and macro_grid: VERBATIM from core/tests/harness/graded_cell_size_probe.cpp
// (PR 235's C2b), so the method is octet's to the operation.
constexpr double kStrain = 1e-3;
VoxelGrid macro_grid(double L, int ncx, int ncy, int ncz) {
  VoxelGrid g;
  g.nx = ncx; g.ny = ncy; g.nz = ncz; g.spacing = L; g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)ncx * ncy * ncz, VoxelTag::Interior);
  return g;
}
double transverse_K(const VoxelGrid& g, const std::vector<double>& ey,
                    const std::vector<char>& mask, const std::vector<double>& c11,
                    const std::vector<double>& c12, const std::vector<double>& c44,
                    bool lattice, double* ms = nullptr, long* nd = nullptr) {
  const double h = g.spacing;
  std::vector<char> issolid((std::size_t)fea_node_count(g), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k)) for (int n : fea_element_nodes(g, i, j, k)) issolid[n] = 1;
  const double delta = kStrain * (g.nz * h) * 2.0;   // a modest transverse drive
  std::vector<DirichletBC> bcs;
  std::vector<int> topnodes;
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i) {
      int nb = fea_node_index(g, i, j, 0);
      if (issolid[nb]) { bcs.push_back({nb, 0, 0.0}); bcs.push_back({nb, 1, 0.0}); bcs.push_back({nb, 2, 0.0}); }
      int nt = fea_node_index(g, i, j, g.nz);
      if (issolid[nt]) { bcs.push_back({nt, 0, delta}); bcs.push_back({nt, 2, 0.0}); topnodes.push_back(nt); }
    }
  if (nd) *nd = 3L * fea_node_count(g);
  FeaSolution sol;
  static const double rtol = [] { const char* s = std::getenv("TOPOPT_GCS_RESTOL"); return s ? std::atof(s) : 1e-6; }();
  // TOPOPT_BEND_MATFREE=1 (not in PR 235): the resolved solve through fea_solve_cg_matfree,
  // the same reduced system and stopping criterion with no assembled K. The assembled K
  // of a 9-cell sheet block at vpc24 (~20M dof) peaked at 39.5 GB and was killed on a
  // 16 GB machine. Unset = the verbatim path, so every earlier measurement reproduces.
  static const bool matfree = [] { const char* s = std::getenv("TOPOPT_BEND_MATFREE"); return s && s[0] == '1'; }();
  auto t0 = std::chrono::steady_clock::now();
  try {
    if (lattice) sol = fea_solve_cg_lattice(g, ey, mask, c11, c12, c44, kNu, bcs, {}, 1e-7, 40000, nullptr);
    else if (matfree) sol = fea_solve_cg_matfree(g, ey, kNu, bcs, {}, rtol, 40000, nullptr, nullptr);
    else sol = fea_solve_cg(g, ey, kNu, bcs, {}, rtol, 40000, nullptr, nullptr);
  } catch (const std::exception& e) { std::fprintf(stderr, "  [transverse_K unconverged: %s]\n", e.what()); return -1.0; }
  if (ms) *ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  std::vector<double> react(3L * fea_node_count(g), 0.0);
  const Hex8Stiffness KeIso1 = hex8_stiffness(1.0, kNu, h);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        std::array<double, 24> ue{}; int edof[24];
        for (int a = 0; a < 8; ++a) for (int c = 0; c < 3; ++c) { edof[3*a+c] = 3*en[a]+c; ue[3*a+c] = sol.at(en[a], c); }
        Hex8Stiffness Ke;
        if (lattice && !mask.empty() && mask[e]) Ke = hex8_stiffness_cubic(c11[e], c12[e], c44[e], h);
        else { Ke = KeIso1; const double f = ey[e]; for (auto& v : Ke.k) v *= f; }
        for (int rr = 0; rr < 24; ++rr) { double s = 0; for (int c = 0; c < 24; ++c) s += Ke(rr, c) * ue[c]; react[edof[rr]] += s; }
      }
  double Fx = 0; for (int n : topnodes) Fx += react[3 * n + 0];
  return std::fabs(Fx) / delta;
}
// 6-connected components of the solid voxels; whether one of them touches both ends.
struct Comp { int n = 0; bool spanning = false; long long largest = 0, solid = 0; };
Comp components(const VoxelGrid& g) {
  Comp out;
  std::vector<int> lab(g.voxel_count(), -1);
  std::vector<std::size_t> stack;
  for (std::size_t s0 = 0; s0 < g.voxel_count(); ++s0) {
    if (g.tags[s0] == VoxelTag::Empty || lab[s0] >= 0) continue;
    const int id = out.n++;
    bool lo = false, hi = false;
    long long size = 0;
    stack.push_back(s0);
    lab[s0] = id;
    while (!stack.empty()) {
      const std::size_t e = stack.back(); stack.pop_back();
      ++size;
      const int i = int(e % g.nx), j = int((e / g.nx) % g.ny), k = int(e / (std::size_t(g.nx) * g.ny));
      if (k == 0) lo = true;
      if (k == g.nz - 1) hi = true;
      const int nb[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
      for (auto& d : nb) {
        const int a = i + d[0], b = j + d[1], c = k + d[2];
        if (a < 0 || b < 0 || c < 0 || a >= g.nx || b >= g.ny || c >= g.nz) continue;
        const std::size_t f = g.index(a, b, c);
        if (g.tags[f] == VoxelTag::Empty || lab[f] >= 0) continue;
        lab[f] = id;
        stack.push_back(f);
      }
    }
    out.solid += size;
    out.largest = std::max(out.largest, size);
    if (lo && hi) out.spanning = true;
  }
  return out;
}
