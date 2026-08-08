#!/bin/sh
# Regenerates every measurement in
# docs/handoffs/2026-08-09-reference-implementation-bakeoff.md.
#
# ★ NEITHER THIRD-PARTY LIBRARY IS IN THIS REPOSITORY (bar R6). This script
# clones both into $SCRATCH, which defaults to a directory OUTSIDE the repo.
# Set SCRATCH to put them somewhere else. Commits of record are in
# third_party_commits.txt; this script clones the tips, so a re-run may pick up
# newer ones — check against that file before comparing numbers.
#
# Cost on the machine of record: ~4 min of installs, ~20 min for the
# from-scratch timing run, ~4 min for the SDF arm, ~5 min for the controls,
# ~3 min for PicoGK. The sequential arm (run_seq_arm.sh) is ~100 min and is NOT
# run by default.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRATCH="${SCRATCH:-${TMPDIR:-/tmp}/refimpl-bakeoff}"
mkdir -p "$SCRATCH"
echo "repo    $REPO"
echo "scratch $SCRATCH"

# ── the three harnesses ─────────────────────────────────────────────────────
cd "$REPO"
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j8 --target portable_problem_export \
                              external_field_surface_probe design_rung_dump

# ── S1: his problem, out of core ────────────────────────────────────────────
mkdir -p "$SCRATCH/problem"
./build/portable_problem_export "$HERE/M2_verticalStand.step" \
    core/src/materials/materials.json "$SCRATCH/problem" \
    | tee "$HERE/s1_portable_problem_export.txt"
cp "$SCRATCH/problem/problem.json" "$HERE/s1_problem.json"

# his converged rungs, as float64 + the shipped STL extraction
mkdir -p "$SCRATCH/simp_rungs"
./build/design_rung_dump "$HERE/s2_simp_baseline/design.bin" "$SCRATCH/simp_rungs" --stl
python3 "$HERE/s3_dump_von_mises.py" \
    "$REPO/evidence/2026-08-03-multiscale-lattice-to/m2_multiscale_final/fields.bin" \
    0.68 "$SCRATCH/simp_rungs/vm_0.68.f64"

# ── GridapTopOpt ────────────────────────────────────────────────────────────
cd "$SCRATCH"
[ -d GridapTopOpt.jl ] || git clone --depth 50 https://github.com/zjwegert/GridapTopOpt.jl.git
mkdir -p env
GTO_PATH="$SCRATCH/GridapTopOpt.jl" JULIA_PROJECT="$SCRATCH/env" julia --startup-file=no -e '
  using Pkg; t0=time(); Pkg.develop(path=ENV["GTO_PATH"]); Pkg.instantiate()
  Pkg.add(["Gridap","GridapDistributed","GridapPETSc","GridapSolvers","PartitionedArrays",
           "GridapEmbedded","STLCutters","JLD2","SparseMatricesCSR","MPI","JSON"])
  println("INSTALL_SECONDS=", round(time()-t0,digits=1))'
cp "$HERE/his_part_ALM.jl" "$HERE/edt.jl" "$HERE/verify_labelling.jl" \
   "$HERE/diag_scale.jl" "$HERE/diag_edt.jl" "$HERE/diag_reinit_full.jl" \
   "$HERE/run_sdf_arm.sh" "$HERE/run_controls.sh" "$SCRATCH/"
chmod +x "$SCRATCH"/run_*.sh

JULIA_PROJECT="$SCRATCH/env" julia --startup-file=no "$SCRATCH/verify_labelling.jl" \
    | tee "$HERE/s2_labelling_control.txt"
JULIA_PROJECT="$SCRATCH/env" julia --startup-file=no "$SCRATCH/his_part_ALM.jl" \
    "$SCRATCH/problem" "$SCRATCH/time_full" 0.68 3 1 > "$HERE/s2_from_scratch_timing.log" 2>&1
"$SCRATCH/run_sdf_arm.sh"  > "$HERE/s2_sdf_arm.log" 2>&1
"$SCRATCH/run_controls.sh" > "$HERE/s2_controls.log" 2>&1

# ── the measurement, with every arm and every control ───────────────────────
cd "$REPO"
set -- "$HERE/s2_simp_baseline/design.bin" "$HERE/M2_verticalStand.step" "$HERE"
for vf in 0.68 0.52 0.38 0.26; do set -- "$@" "GTO-SDF=$SCRATCH/out_sdf_$vf/rho_cells"; done
for vf in 0.68 0.26; do
  set -- "$@" "CTRL-eta0.5=$SCRATCH/out_eta0.5_$vf/rho_cells" \
              "CTRL-eta1.0=$SCRATCH/out_eta1.0_$vf/rho_cells" \
              "CTRL-EDT-noreinit=$SCRATCH/out_noreinit_$vf/rho_cells" \
              "GTO-SDF-nodelattice=$SCRATCH/out_sdf_$vf/rho_nodes"
done
set -- "$@" "GTO-ALM-3iter-UNCONV=$SCRATCH/time_full/rho_cells"
./build/external_field_surface_probe "$@" > "$HERE/s2_surface_probe.txt" 2>&1
python3 "$HERE/r2_reproduces_pr319.py" | tee "$HERE/r2_reproduces_pr319.txt"

# ── PicoGK ──────────────────────────────────────────────────────────────────
cd "$SCRATCH"
for r in PicoGK LEAP71_ShapeKernel LEAP71_LatticeLibrary; do
  [ -d "$r" ] || git clone --depth 1 "https://github.com/leap71/$r.git"
done
[ -d dotnet ] || { curl -sSL https://dot.net/v1/dotnet-install.sh -o di.sh
                   sh di.sh --channel 9.0 --install-dir "$SCRATCH/dotnet" --no-path; }
export DOTNET_ROOT="$SCRATCH/dotnet"; export PATH="$SCRATCH/dotnet:$PATH"
export DYLD_LIBRARY_PATH="$SCRATCH/PicoGK/native/osx-arm64:$DYLD_LIBRARY_PATH"
mkdir -p s3_lattice && cp "$HERE/s3_lattice_Program.cs" s3_lattice/Program.cs
# the .csproj is regenerated here rather than committed: it only globs the three
# clones and pins net9.0 + SkiaSharp, and it has no measurement in it.
cat > s3_lattice/s3_lattice.csproj <<'CSPROJ'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings><Nullable>disable</Nullable>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks><AssemblyName>s3_lattice</AssemblyName>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <NoWarn>$(NoWarn);1591;CS0168;CS0219</NoWarn>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="Program.cs" />
    <Compile Include="../PicoGK/**/*.cs" Exclude="../PicoGK/**/obj/**;../PicoGK/**/bin/**" />
    <Compile Include="../LEAP71_ShapeKernel/ShapeKernel/**/*.cs" />
    <Compile Include="../LEAP71_LatticeLibrary/LatticeLibrary/**/*.cs" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="SkiaSharp" Version="3.119.0" />
    <EmbeddedResource Include="../PicoGK/assets/ViewerEnvironment.zip">
      <LogicalName>PicoGK.Resources.Environment.zip</LogicalName></EmbeddedResource>
    <EmbeddedResource Include="../PicoGK/assets/Jost.ttf">
      <LogicalName>PicoGK.Resources.Font.ttf</LogicalName></EmbeddedResource>
    <None Include="../PicoGK/native/osx-arm64/*.dylib" CopyToOutputDirectory="PreserveNewest" />
  </ItemGroup>
</Project>
CSPROJ
cd s3_lattice && dotnet build -c Release
mkdir -p "$HERE/s3"
for spec in "rho:rung_0.68.f64:1.0:4.6026:-1" "vm:vm_0.68.f64:0.0168868:4.6026:-1" \
            "vm:vm_0.68.f64:0.0168868:2.0:-1"  "vm:vm_0.68.f64:0.0168868:8.0:-1" \
            "vx0.45:vm_0.68.f64:0.0168868:4.6026:0.45" \
            "vx0.30:vm_0.68.f64:0.0168868:4.6026:0.30" \
            "vx0.20:vm_0.68.f64:0.0168868:4.6026:0.20"; do
  tag=$(echo "$spec"|cut -d: -f1); f=$(echo "$spec"|cut -d: -f2)
  dm=$(echo "$spec"|cut -d: -f3); cell=$(echo "$spec"|cut -d: -f4)
  vx=$(echo "$spec"|cut -d: -f5)
  out="$SCRATCH/out_s3_${tag}_${cell}"; mkdir -p "$out"
  dotnet run -c Release --no-build -- "$SCRATCH/problem" "$SCRATCH/simp_rungs/$f" \
      "$SCRATCH/simp_rungs/rung_0.68.stl" "$out" "$cell" "$dm" "$vx" > "$out/run.log" 2>&1
  cp "$out/run.log" "$HERE/s3/out_s3_${tag}_${cell}.log"
  gzip -c "$out/grading_profile.csv" > "$HERE/s3/out_s3_${tag}_${cell}_grading_profile.csv.gz"
done

# ── the bars ────────────────────────────────────────────────────────────────
cd "$REPO"
git diff main -- core/src core/include app/TopOptKit/Sources | tee /dev/stderr | wc -l
cmake --build build -j8 && ctest --test-dir build --output-on-failure > "$HERE/ctest.txt" 2>&1
echo "REPRODUCE_DONE"
