// geneo_byteid_xbuild.cpp — P1 cross-build byte-identical proof.
//
// Uses ONLY the public topopt API (no phase-2 symbols), so it links against BOTH the
// phase-2 library (hook present, default-off) AND a stashed PRE-CHANGE library. Runs a
// small production ladder and prints one FNV-1a hash over the certified outputs
// (densities, compliance, margins, accepts). If the hash matches across the two builds,
// the phase-2 production change (a default-null preconditioner hook) is byte-identical
// with the hook off — the MG-CG / Jacobi-CG paths are untouched.
//
// BUILD (against whichever libtopopt.a is present):
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/geneo_byteid_xbuild.cpp core/build/libtopopt.a -o core/build/geneo_byteid_xbuild

#include <cstdint>
#include <cstdio>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {
struct Fnv { std::uint64_t h = 1469598103934665603ULL;
  void add(const void* p, std::size_t n){ auto* b=(const unsigned char*)p; for(std::size_t i=0;i<n;++i){ h^=b[i]; h*=1099511628211ULL; } }
  void d(double v){ add(&v,sizeof v); } void i(long long v){ add(&v,sizeof v); } };

VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny, int t, double h) {
  VoxelGrid g; g.nx=span; g.ny=ny; g.nz=arm; g.spacing=h; g.origin=Vec3{0,0,0};
  g.tags.assign((std::size_t)span*ny*arm, VoxelTag::Empty);
  for (int k=0;k<arm;++k) for (int j=0;j<ny;++j) for (int i=0;i<span;++i) if (i<t||k<t) g.set_tag(i,j,k,VoxelTag::Interior);
  for (int j=0;j<ny;++j) for (int i=0;i<t;++i) g.set_tag(i,j,arm-1,VoxelTag::Fixture);
  bcs.clear();
  for (int b=0;b<=ny;++b) for (int a=0;a<=t;++a){ int n=fea_node_index(g,a,b,arm); bcs.push_back({n,0,0.0}); bcs.push_back({n,1,0.0}); bcs.push_back({n,2,0.0}); }
  for (int k=0;k<t;++k) for (int j=0;j<ny;++j) g.set_tag(span-1,j,k,VoxelTag::Load);
  return g;
}
Material fdm(){ Material m; m.youngs_modulus_mpa=3500; m.yield_strength_mpa=55; m.density_g_cm3=1.24; m.z_knockdown=0.55; m.poisson=0.33; m.family="fdm"; return m; }
}  // namespace

int main() {
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, 16,16,4,4, 1.0);
  std::vector<NodalLoad> loads = traction_loads(part, VoxelTag::Load, Vec3{0,0,-30});
  MinimizePlasticOptions o; configure_production_options(o);
  o.volume_fraction_ladder = {0.30, 0.21}; o.margin_stop = 0.0;
  o.external_loads = loads; o.gravity = 0.0; o.gravity_direction = Vec3{0,0,-1};
  o.infill_percent = 100.0;
  DesignBox box; box.min=Vec3{-8,-8.64,-8}; box.max=Vec3{24,12.64,24}; o.design_box=box;
  o.freeze_imported_part=false; o.simp.max_iterations=8;
  SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  MinimizePlasticResult r = minimize_plastic(part, fdm(), "fdm", bcs, rules, o);
  Fnv f;
  for (const auto& v : r.evaluated) {
    for (double d : v.optimization.physical_density) f.d(d);
    f.d(v.optimization.compliance); f.d(v.report.margin.worst_case); f.d(v.report.margin_effective);
    f.i(v.accepted?1:0);
  }
  std::printf("rungs=%zu fnv=%016llx\n", r.evaluated.size(), (unsigned long long)f.h);
  return 0;
}
