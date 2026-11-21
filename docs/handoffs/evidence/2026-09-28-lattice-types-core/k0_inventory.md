# K0 — the octet-only inventory (02-core-spec §1)

Written BEFORE any code, as required. Line numbers are from the merged head
(`478ad2c7` + `Sync: merge main`), re-grepped rather than taken from the spec — the
spec's were at `daa764c4` and several had drifted.

Classification, per the spec:
- **(a) topology-free** — the mention is a comment, a receipt string that only carries
  a name, or code that already dispatches on a topology argument correctly.
- **(b) needs a per-type number** — the code takes (or could take) a topology and
  returns *octet's* number.
- **(c) needs new logic** — the code assumes octet's geometry, or hard-codes the id.

## 0. Scope of the census

366 case-insensitive `octet` mentions across 34 files in `core/src` + `core/include`.
Filtering to lines that are not pure comments leaves the behavioural sites below. The
comment-only remainder is category (a) and is listed in aggregate at the end.

**What is already per-type, and is the reason this round is feasible at all:**
`LatticeTopology` already carries all ten ids, `lattice_cubic_tensor`,
`lattice_rho_min/max`, `lattice_resolved_rows`, `lattice_topology_certifiable` and
`lattice_certifiable_topology_names` are already per-type, and the six strut types'
tensor rows are landed. The certification half of the work is done. What is octet-only
is the *generator* and the *practical numbers*.

## 1. The generator — category (c)

| Site | What is octet-only |
|---|---|
| `include/topopt/lattice_gen.hpp:47` | `enum class LatticeGenTopology : int { Octet };` — one value |
| `src/mesh/lattice_gen.cpp:854,869` | name table and `lattice_gen_topology_names()` iterate `{Octet}` |
| `src/mesh/lattice_gen.cpp:887` | `if (topo != LatticeGenTopology::Octet) throw "only Octet is implemented"` |
| `src/cli/run_job.cpp` ×6 | `generate_lattice(LatticeGenTopology::Octet, …)`, `generate_lattice_stepped(…Octet…)`, `generate_lattice_multilevel(…Octet…)` at :2376, :2378, :2380, :2442, :2445, :2447 |
| `src/orient/build_orientation.cpp:118` | `generate_lattice(LatticeGenTopology::Octet, …)` |

## 2. The numbers — category (b)

### 2a. `octet_strut_diameter_mm(rho, cell)` — 44 call sites, none topology-aware

| File | Sites | Notes |
|---|---|---|
| `src/cli/run_job.cpp` | 20 | receipt strut sizes, radius lambdas for every emit path (:6707, :6871, :6881, :7047, :7083, :7095, :7107, :7122, :7171, :7185), forecast and refusal text |
| `src/fea/lattice.cpp` | 10 | inside `lattice_cell_printability_floor_mm` (:437, :457, :462, :474) and `lattice_min_density_for_strut` (:517, :560, :569, :635) — **both take a `topo` argument and ignore it** |
| `src/simp/grading.cpp` | 7 | the grading law's own printability tests (:260, :606, :701, :751, :890, :1023, :1079, :1182) |
| `src/simp/cell_plan.cpp` | 6 | the cell plan's menu and floors (:61, :70, :200, :362, :410, :661) |
| `src/simp/lattice_density_field.cpp` | 1 | :133 |
| `include/topopt/lattice.hpp` | 1 | :633, inside `octet_aesthetic_density_ceiling()` |

**This is the single largest item in the round.** Every one of these is a density →
strut-diameter conversion, and the function name states whose measurement it is.

### 2b. `octet_relative_density(cell, radius)` — 11 call sites

| File | Sites |
|---|---|
| `src/mesh/stepped_plan.cpp` | 4 (:33, :53 and the include note) |
| `src/cli/run_job.cpp` | 3 (:6714, :9679, :11091 — the uniform-lattice band check) |
| `src/fea/strut_strength.cpp` | 1 |
| `include/topopt/lattice.hpp` | 3 (declaration + doc) |

### 2c. Floors that return one number for every type

| Site | Today | Needs |
|---|---|---|
| `src/fea/lattice.cpp:314` `lattice_cells_per_member_min(topo)` | **5** for every type; its own comment calls it a placeholder | per type (02 §2.3), and T4 expects it to RISE for SC, BCC, Diamond, Kelvin |
| `src/fea/lattice.cpp:329` `lattice_percolation_cells_per_member_min(topo)` | **1.0** for every type; octet, axial, ρ≈0.199 only | per type |
| `include/topopt/lattice.hpp:210` `aesthetic_cells_per_member_hard_floor(topo)` | octet's 2-cell rule | per-type re-measurement |
| `include/topopt/lattice.hpp:610,627` `kOctetAestheticStrutPerCell`, `octet_aesthetic_density_ceiling()` | **takes no topology at all** | per type (R11), bisected through that type's own table |
| `src/fea/lattice.cpp:387` `kOctetDiaCellMm`, `:388` `kOctetDia` | octet's 8-row diameter table at a 4 mm cell | one table per type |
| `src/fea/lattice.cpp:639` `octet_relative_density` | octet voxelisation at vpc48 | the same function per type |
| `src/fea/strut_strength.cpp:27` `kOctetStrutLaw` | octet's 9-row law | per type or the stated refusal (R10 — it already refuses) |

## 3. Hard-coded ids that must read the job — category (c)

| Site | What it does |
|---|---|
| `src/cli/job.cpp:1229`, `:1735` | `topology` must be `"octet"` — the parse gate for both `lattice` and `grading` |
| `src/cli/job.cpp:1385-1386` | the region `relative_density` band is checked against `lattice_rho_min/max(Octet)` regardless of the job's topology |
| `src/cli/run_job.cpp:2705` | `post.topology = LatticeTopology::Octet; // job schema restricts topology to octet` |
| `src/cli/run_job.cpp:5386`, `:8252`, `:9143` | `gp.topology = LatticeTopology::Octet;` — the grading law's topology, set three times |
| `src/cli/run_job.cpp:12150` | `options.multiscale_topology = LatticeTopology::Octet;` |
| `src/cli/run_job.cpp:1553`, `:1582`, `:1588`, `:4060`, `:11134`, `:12126`, `:12130` | `fit_region_cells(job, LatticeTopology::Octet, …)`, `refuse_unprintable_stated_density(… Octet …)`, and two local `const LatticeTopology topo = LatticeTopology::Octet;` |
| `src/cli/run_job.cpp:4683`, `:6068`, `:12252` | `lattice_cells_per_member_min(LatticeTopology::Octet)` |
| `src/cli/run_job.cpp:6102`, `:6104` | `lattice_derive_cell_for_member(LatticeTopology::Octet, …)` |
| `src/cli/run_job.cpp:9680-9681`, `:11092-11093` | uniform-lattice band bounds from octet |
| `src/orient/build_orientation.cpp:87` | `if (topo != LatticeTopology::Octet) return {};` — build-orientation facts are octet-only |
| `src/orient/build_orientation.cpp:238` | `facts.lattice->topology == LatticeTopology::Octet` |
| `src/simp/analyze.cpp:465` | `lattice->topology == LatticeTopology::Octet` gate |
| `src/simp/lattice_density_field.cpp:127`, `:171` | `if (topo != LatticeTopology::Octet)` gates |

**★ Most of these sit inside `run_job.cpp`'s anonymous namespaces** (`:67-7774`,
`:7934-8739`, `:10673-10933`), so no unit test can reach them. Per this week's working
rule, any decision among them that I touch gets lifted — to a header if it is a schema
or law fact, or out of the namespace into an internal header without moving the body
(the `production_loadcase_from_job` precedent).

## 4. Struct defaults that are octet — category (a), with a caveat

`grading.hpp:172`, `cell_plan.hpp:187`, `lattice_material.hpp:92`, `analyze.hpp:52`
and `:159`, `pipeline.hpp:499` and `:559` all default a `LatticeTopology` member to
`Octet`. These are (a) — harmless while every caller sets them — but they are exactly
the shape of a silent default. The rule for this round is that a caller that fails to
set one must refuse, not inherit octet. I will assert on that rather than trust it.

## 5. Receipt string fields — category (a)

`observability.hpp:708`, `:753`, `:879`, `:1413` carry `"octet"` as the only value
their comments contemplate (`lattice_topology`, `lattice_export_topology`,
`grading_topology`, `multiscale_topology`). They are plain strings, so they need no
new logic — only the real topology written into them, and octet's value unchanged.

## 6. Comment-only remainder — category (a)

The balance of the 366 mentions is prose: the tensor-library provenance notes in
`lattice.hpp:55-74`, the legs-only caveat, `beam_network.cpp:1562,1572`,
`observability.cpp:1827`, `run_job.cpp`'s `"describes"` strings at :3659-3668 and the
resolution caveat at :3961, and `job.cpp:1901,2055`. Several state octet's geometry as
fact and will need rewording as types land; none changes behaviour.

## 7. What this means for the order of work

The inventory says the round is dominated by ONE substitution — `octet_strut_diameter_mm`
at 44 sites — and that it cannot be done by search-and-replace, because 20 of those
sites are inside `run_job.cpp`'s anonymous namespaces and 10 are inside two functions
(`lattice_cell_printability_floor_mm`, `lattice_min_density_for_strut`) that already
take a topology and ignore it. Fixing those two functions first makes most of the rest
follow, and R9 (octet byte-identical) gives an exact test: octet's results must not
move by one bit while the plumbing changes underneath.
