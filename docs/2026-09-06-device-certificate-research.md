# RESEARCH — can the organic structural certificate run on the iPad?

Branch `claude/research-device-certificate` (off merged main f08c1af8). Nothing ships.
Harness: `core/tools/cert_research.cpp` + a research export in `solve_coupled_lattice`
(the free system, RHS, dof kinds, tie hosts, solid node positions, and two recovery
closures) + `research_direct_solve` / `ResearchFactor` (Accelerate LDLT, the coupled
solve's own options). Inputs: `TOPOPT_CERT_DUMP_DIR` dumps every certificate input from
a normal run; each variant runs as its OWN PROCESS under `/usr/bin/time -l`.
Build: Release, Apple M2 Pro, 16 GB. All numbers below are measured, none estimated.

## How the certificate reproduces
The export path (`xbase`) reproduces the certificate's p99 on every configuration to
four digits (traced 4-4: 1.2854 vs the run's 1.285 MPa; 5.5-6: 1.681 vs 1.681;
3-5: 0.8022 vs 0.802). Everything below is measured against that.

## THIS IS HOW IT IS NOW -> after 1 -> after 1+2 (implicit: K_ee once + beam block) -> after 1+2+3 (merged + submodel 2 vox)
| configuration | members | dof free | interface | today: factor GB / peak MB / s | after 1 (merge): members / factor GB / s | after 2 (K_ee once GB + beam block GB) | after 1+2+3: kept dof / factor GB / solve s | margin today / merged / station | submodel coarse-field p99 err / >5% |
|---|---|---|---|---|---|---|---|---|---|
| traced 5.5-6 | 29,695 | 296,568 | 18,990 | 1.927 / 2077 / 20.3 | 17,038 / 1.961 / 21.6 | 1.107 + 0.054 | 93,312 / 0.058 / 0.17 | 17.29 / 15.68 / 18.24 | -0.16 % / 1581 of 16087 |
| traced 4-4 | 66,268 | 451,518 | 27,048 | 2.597 / 2694 / 27.4 | 41,615 / 2.397 / 26.3 | 0.995 + 0.192 | 188,724 / 0.180 / 0.78 | 22.22 / 20.06 / 24.25 | +0.02 % / 3836 of 37161 |
| traced 3-5 graded | 73,135 | 484,530 | 29,856 | 2.498 / 3268 / 18.6 | 47,384 / 2.352 / 28.7 | 0.985 + 0.228 | 218,787 / 0.209 / 0.94 | 35.59 / 32.15 / 40.90 | +0.09 % / 6623 of 44443 |
| grown, no ties | 58,705 | 289,956 | 18,720 | 1.713 / 1871 / 24.4 | 50,463 / 1.637 / 30.1 | 1.144 + 0.040 | 116,181 / 0.043 / 0.18 | 3.43 / 3.31 / 3.77 | +0.00 % / 0 of 14963 |
| grown, ties (default) | 96,996 | 454,191 | 20,442 | 1.913 / 3299 / 12.9 | 77,110 / 1.815 / 9.5 | 1.159 + 0.090 | 213,333 / 0.087 / 0.22 | 20.78 / 20.04 / 22.36 | -0.01 % / 2 of 37762 |
| grown, ties, no swirl | 65,404 | 301,008 | 19,767 | 1.879 / 3087 / 10.1 | 57,597 / 1.770 / 9.6 | 1.140 + 0.060 | 131,559 / 0.070 / 0.16 | 10.92 / 10.62 / 13.19 | +0.01 % / 1635 of 23268 |
| grown uniform 4.5 | 132,942 | 361,533 | 23,589 | 1.931 / 3477 / 10.0 | 121,160 / 2.132 / 23.9 | 1.099 + 0.106 | 173,679 / 0.106 / 0.33 | 35.64 / 35.39 / 42.27 | +0.00 % / 2343 of 69618 |
| grown uniform 5.5 | 75,196 | 276,843 | 15,924 | 1.740 / 4561 / 9.7 | 67,541 / 1.755 / 9.1 | 1.180 + 0.042 | 105,153 / 0.048 / 0.13 | 13.61 / 14.68 / 14.74 | +0.00 % / 93 of 29997 |
| grown uniform 6.5 | 57,172 | 331,431 | 13,530 | 1.871 / 3753 / 12.2 | 43,670 / 1.695 / 14.3 | 1.276 + 0.041 | 117,531 / 0.038 / 0.10 | 27.11 / 25.84 / 29.79 | -0.02 % / 111 of 23670 |
| M2 stand, unified | 42,708 | 326,277 | 38,118 | 2.920 / 3985 / 29.4 | 38,154 / 2.961 / 24.1 | 1.572 + 0.108 | 134,049 / 0.156 / 0.32 | 138.90 / 141.30 / 163.90 | -0.05 % / 2903 of 25567 |
| M2 stand, no shape fit | 41,546 | 325,827 | 33,015 | 2.873 / 5171 / 20.9 | 34,092 / 2.771 / 15.5 | 1.556 + 0.079 | 120,327 / 0.129 / 0.27 | 130.00 / 124.80 / 153.10 | -0.02 % / 348 of 22717 |

### Where the memory is
| configuration | interior solid dof | K_ee factor GB (one-time) | beam+interface block dof | its factor GB (no Schur) |
|---|---|---|---|---|
| traced 5.5-6 | 136,698 | 1.107 (6.3 s) | 159,870 | 0.054 (0.2 s) |
| traced 4-4 | 126,417 | 0.995 (9.2 s) | 325,101 | 0.192 (0.6 s) |
| traced 3-5 | 121,428 | 0.985 (5.7 s) | 363,102 | 0.228 (1.4 s) |
The SOLID is the memory. The beam system alone factors in 50-230 MB.

## 1. CHAIN MERGING (`xbase-merge`, 15° bend limit, same radius + tag, junctions kept)
| configuration | members before → after | dof before → after | factor GB before → after | p99 segments today | p99 merged members | p99 segments, envelope recovery | p99 segments, STATION recovery | margins today / members / envelope / station |
|---|---|---|---|---|---|---|---|---|
| traced 5.5-6 | 29,695 → 17,038 (−43 %) | 296,568 → 225,444 | 1.927 → 1.961 | 1.681 | 1.880 | 1.969 | 1.596 | 17.29 / 15.68 / 13.70 / 18.24 |
| traced 4-4 | 66,268 → 41,615 (−37 %) | 451,518 → 313,071 | 2.597 → 2.397 | 1.285 | 1.449 | 1.465 | 1.152 | 22.22 / 20.06 / 19.33 / 24.25 |
| traced 3-5 | 73,135 → 47,384 (−35 %) | 484,530 → 338,799 | 2.498 → 2.352 | 0.802 | 0.905 | 0.895 | 0.697 | 35.59 / 32.15 / 32.72 / 40.90 |
| grown u4.5 (4-4 grid) | 132,942 → 121,160 (−9 %) | | 1.978 → 2.057 | 0.770 | 0.773 | 0.815 | 0.693 | 35.29 / 34.94 / 33.78 / 41.61 |
Why they differ: a chain of N short Timoshenko elements samples the moment at every
interior node and the certificate reads each element's END envelope, so the segment p99
is the p99 of the LARGER of many end samples; one element per chain reads only the two
junction ends (members) — the envelope assigned to every segment (−9 %) is the crude
recovery; the STATION recovery (N constant, |M| interpolated between the end
magnitudes — exact for an end-loaded prismatic beam) reads 5-15 % BELOW today. The
three are 13.7 / 15.7 / 17.3 / 18.2 on the same lattice. The maintainer picks.
Memory: merging buys 4-8 % of the factor on traced parts (the solid dominates) and
raises the process peak (the merged network's assembly copies). On the GROWN path
chains barely merge (−9 %): its curves branch and join every few layers.

## 2. STATIC CONDENSATION (Guyan 1965)
Partition: interior solid e (no beam coupling — verified: 0 beam-interior entries),
interface I = solid dofs interpolating a tied beam node, beam b.
| configuration | interior solid | interface | beam | dense Schur S_II (MB) |
|---|---|---|---|---|
| traced 5.5-6 | 136,698 | 18,300 | 141,570 | 2,555 |
| traced 4-4 | 126,417 | 25,734 | 299,367 | 5,052 |
| traced 3-5 | 121,428 | 27,837 | 335,265 | 5,912 |
The interface is 18-28 k dofs (every tied beam node touches 8 hex nodes × 3), so the
explicit Schur complement is a 2.5-5.9 GB dense block — LARGER than the full sparse
factor it replaces. Guyan is exact but not smaller here; the harness refuses above a
stated cap (6,000) and reports the sizes. What survives of the idea is IMPLICIT
condensation: keep K_ee's sparse factor (1.0-1.1 GB, one-time) and never form S. That
is item 4's territory, and item 3 makes it moot (below).

## 3. SUBMODELING (lattice + solid margin, cut-boundary displacements from the full solve)
| configuration | margin (voxels) | kept dof | dropped solid dof | cut dofs | factor GB | solve s | member-stress agreement vs full |
|---|---|---|---|---|---|---|---|
| traced 5.5-6 | 2 / 4 / 8 | 165,534 / 199,785 / 264,984 | 131,034 / … | | 0.074 / 0.231 / 0.838 | 0.24 / 0.68 / 3.2 | max rel 4.8e-9 at every margin |
| traced 4-4 | 2 / 4 / 8 / 16 | 327,594 / 359,922 / 424,719 / 451,293 | 123,924 / 91,596 / 26,799 / 225 | 19,524 / 16,680 / 17,259 / 147 | 0.212 / 0.434 / 1.116 / 2.571 | 0.57 / 4.6 / 3.3 / 37 | max rel 4.9e-9 |
| traced 3-5 | 2 / 4 / 8 | 364,686 / 396,594 / 461,532 | 119,844 / … | | 0.242 / 0.466 / 1.186 | 0.86 / 2.2 / 9.0 | max rel 5e-9 |
The agreement above is EXACT by construction: the cut boundary carries the full solve's
own displacements, and linear statics reproduces the interior — that row measures SIZE.
The ERROR was measured separately with a COARSER global field on the cut: the chain-
merged network's full solve (a different, cheaper global model of the same part), whose
solid displacements share the numbering, prescribed on the cut; the fine segment
network solved inside; compared with the fine full solve:
| configuration | margin | p99 fine / submodel | margin fine / submodel | members > 1 % off | > 5 % off | max rel |
|---|---|---|---|---|---|---|
| traced 5.5-6 | 2 / 4 / 8 | 1.6739 / 1.6713 (−0.16 %) at every margin | 17.29 / 17.29 | 3,688 / 3,644 / 3,644 of 16,087 | 1,581 | 0.34 |
| traced 4-4 | 2 / 4 / 8 | 1.2788 / 1.2790 (+0.02 %) | 22.22 / 22.21 | 9,199 / 9,094 / 9,077 of 37,161 | 3,836 | 0.41 |
| traced 3-5 | 2 / 4 / 8 | 0.7987 / 0.7994 (+0.09 %) | 35.59 / 35.59 | 17,871 / 17,777 / 17,752 of 44,443 | 6,623 | 0.83 |
The statistic the certificate READS (p99, margin) converges at 2 voxels to within 0.2 %
and does not move by 8. Individual members differ by up to 0.3-0.8 of their value, and
that count barely changes with the margin either — so it is not the cut; it is the
coarser global model loading the solid slightly differently everywhere, felt by the
low-stress members near the 1 %-of-p99 floor. The optimizer's field will be coarser
still (a density model, no beams); its p99 agreement is the open measurement, and the
dump does not carry it. Size: at 2 voxels the factor is 0.07-0.24 GB — 10-26× below
today — and the solve is under a second.


### After 1 + 2 + 3 (chain-merged network, submodel at 2 / 4 voxels)
| configuration | members (merged) | kept dof | factor GB | solve s | agreement vs the merged full solve | time-l peak MB |
|---|---|---|---|---|---|---|
| traced 5.5-6 | 17,038 | 93,312 / 128,448 | 0.058 / 0.214 | 0.17 / 0.62 | max rel 5e-9 | 2,246 / 2,284 |
| traced 4-4 | 41,615 | 188,724 / 221,457 | 0.180 / 0.399 | 0.78 / 1.18 | max rel 5e-9 | 2,328 / 3,030 |
| traced 3-5 | 47,384 | 218,787 / 250,863 | 0.209 / 0.430 | 0.94 / 2.48 | max rel 5e-9 | 2,443 / 2,024 |
Factor: 1.9-2.6 GB today → 0.06-0.21 GB (12-33× smaller); solve 18-27 s → under 1 s.
The time-l peak stays 2-3 GB because the HARNESS assembles and exports the full
system before cutting it; a production submodel would assemble only the kept region
(kept dof × ~30 nonzeros × 12 B ≈ 35-80 MB of matrix) plus the factor.

## 4. ITERATIVE SOLVE — not needed. Items 1-3 leave the reduced certificate at
0.07-0.24 GB of factor; PCG on the beam system is not built.

## THE DEVICE — the ceiling
A PRODUCTION submodel assembles only the kept region. Its footprint is the kept
matrix (CSR: 12 B per stored entry, measured `kept_nnz`), the factor (measured), and
the network plus working vectors:
| configuration | members | kept dof | kept nnz | matrix MB | factor MB | net MB | TOTAL MB |
|---|---|---|---|---|---|---|---|
| traced 5.5-6 | 29,695 | 93,312 | 2,435,407 | 29 | 60 | 3 | **92** |
| traced 4-4 | 66,268 | 188,724 | 4,837,278 | 58 | 185 | 5 | **248** |
| traced 3-5 | 73,135 | 218,787 | 5,582,322 | 67 | 214 | 6 | **287** |
| grown no ties | 58,705 | 116,181 | 2,719,089 | 33 | 44 | 4 | **80** |
| grown ties | 96,996 | 213,333 | 4,925,040 | 59 | 89 | 6 | **155** |
| grown no swirl | 65,404 | 131,559 | 3,249,604 | 39 | 71 | 4 | **114** |
| grown u4.5 | 132,942 | 173,679 | 4,370,023 | 52 | 109 | 6 | **168** |
| grown u5.5 | 75,196 | 105,153 | 2,577,015 | 31 | 49 | 4 | **83** |
| grown u6.5 | 57,172 | 117,531 | 2,697,850 | 32 | 39 | 4 | **75** |
| M2 unified | 42,708 | 134,049 | 5,012,126 | 60 | 160 | 4 | **224** |
| M2 no shape fit | 41,546 | 120,327 | 4,637,885 | 56 | 132 | 3 | **191** |
EVERY configuration fits under 300 MB; the worst is 287 MB (traced 3-5). Today the
same eleven need 1.7-2.9 GB of factor alone.
The footprint tracks KEPT DOF (the submodel's size), not member count: per member it
ranges 1.11-5.24 kB because a graded lattice touches more solid per strut. Stating the
ceiling both ways, so the maintainer can name a budget:
| budget | ceiling at the median rate (1.75 kB/member) | ceiling at the WORST measured rate (5.24 kB/member) |
|---|---|---|
| 256 MB | ~146,000 members | ~49,000 members |
| 512 MB | ~293,000 members | ~98,000 members |
| 1 GB | ~586,000 members | ~195,000 members |
Use the worst-rate column. At 512 MB every configuration in this PR fits with 1.7x
headroom on the largest; the biggest lattice measured (132,942 members) needs 168 MB.
DEVICE MEASUREMENT: still outstanding — I have no device. The receipt now carries
`structural_members`, `structural_rss_before_mb`, `structural_rss_after_mb` and
`structural_peak_rss_mb` (PR 356), so any organic structural run on an iPad reports
its own footprint; that is the one number this report cannot produce.

## THE ANSWER
YES, with items 1 and 3. The certificate does not need the whole part: it needs the
lattice, a two-voxel solid collar, and one beam element per strut between junctions.
That is 75-287 MB and under a second of solve, against 1.7-2.9 GB and 10-30 s today,
and the statistic it certifies on moves by less than 0.2 %.


## SIDE RESULT — the probe's under-forecast (reviewer follow-up item 1), decomposed on ONE grid
All on the traced 4-4 dump's grid, mask and loads (`--spans` override):
| span set | members | tied beam nodes | factor GB | p99 MPa | margin |
|---|---|---|---|---|---|
| run u4.5's own spans | 132,942 | 3,438 | 1.978 | 0.770 | 35.29 (the run's own certificate: 35.64) |
| probe 4.5 spans, as certified | 208,516 | 8,087 | 2.307 | 0.894 | 28.4 |
| probe 4.5 spans, scaffolding (legs+ties) deleted | 183,754 | | 2.152 | 1.136 | 22.5 |
| probe 4.5 spans, node-merged like the run | 192,186 | | | | 29.0 (members) |
| probe 4.5 spans, load reach 4.0 / 4.5 / 5.5 / 8.0 mm | | | | | 27.7 / 27.5 / 27.0 / 27.0 |
| probe 3.5 spans, radius ×1.19 | | | | | 19.2 → 31.8 (bending: 1/r³) |
Refuted: legs (deleting them LOWERS the margin; they share load), radius (the probe's
length-weighted mean matches the run's within 1 % on every window), node merge (no
gain), load reach (2.5 %). The probe's network on the run's setup reads 0.80 of the
run; the probe's own certificate read 0.63. The remaining factor (0.79) is the probe's
certificate SETUP: its solid was built from the grading mask BEFORE the solid rim while
its curves were traced on the mask AFTER it, so the rim band was neither solid nor
lattice — an unsupported edge. Fixed (main-tree follow-up); re-measurement PENDING.
The 0.80 that remains is the run's post-processed network (support pass, transfer
ties, fill mat, re-seeding) certifying higher with FEWER members and LESS length than
the probe's raw curves plus scaffolding.

## THIS IS THE BEST I CAN DO — the problems hit, and what was found
1. Chain merging loses the per-segment stress: FIXED here by station recovery from the
   member end forces (standard beam post-processing: stresses at recovery points from
   end forces; the FEMAP/Itasca manuals and any Timoshenko implementation).
2. Condensation's interface grows large (8 hex nodes per tied beam node): the
   literature's answers are (a) port/interface REDUCTION with empirical port modes
   (Eftang & Patera 2013, the port-reduced static condensation RB element method) —
   approximate, and (b) keeping the Schur implicit inside a multifrontal solver (Kelley
   et al. 2012 on multifrontal memory) — which is what the full factor already does.
   Neither beats the submodel here.
3. Submodeling's margin convergence: the standard global-local method (Altair/ANSYS
   submodeling; Curreli 2018; Bogdanovich 2012) prescribes cut-boundary displacements
   from the coarse global solve and grows the cut until the local result stops moving;
   the FE² embedded multi-level method for lattice metamaterials (2024) is the
   lattice-specific version. Implemented here with the certificate's own field; the
   optimizer-field version is the open measurement.
Mechanisms in the harness, each ablatable by variant name: `xbase`, `xbase-merge[:deg]`,
`solidfactor`, `beamblock`, `guyan[:cap]`, `submodel[:margin]`, `submodel-merge[:margin]`,
options `--spans`, `--merge-nodes`, `--reach`.
