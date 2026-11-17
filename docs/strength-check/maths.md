## What the check does

The strength check of a regular (cell) lattice made by the new lattice engine (rules V1, V4, V4a, V5). It is the old engine's lattice certification (`certify_latticed_variant`, `run_job.cpp`) run on a voxel model of the part in which the lattice's density per voxel is taken from the new layout's cells. It runs inside the worker's `topopt-cli lattice-file` command after the file is written, only when the lattice-file job carries `strength_job` (V4a; absent, nothing is computed or reported, V2). The app sends no strength job for Aesthetic (U9). The result is the `strength` block of `lattice_file.json`, plus `fields.bin` (and `scenario_fields.bin` with scenarios).

Steps, in order:

1. Read the strength job (`"mode": "lattice_part"`), the materials file and the rules file; refuse if the mode or material is wrong.
2. Open the part; refuse if not watertight or if its box differs from the lattice file's part box.
3. Voxelise the part; apply supports and loads exactly as the old Lattice run does.
4. Solid solve: every part voxel solid. Gives the reference solid margin.
5. Map the layout's cells onto the voxels; give each cell a density or no credit.
6. Old check: (a) re-solve the all-solid design (must reproduce step 4), (b) solve the composite (solid + homogenised lattice, no-credit voxels empty), (c) gate.
7. Strut law on the composite's lattice voxels; verdict; write the block and fields.

The strength job may carry `strength_settings`, an object of the CHOSEN numbers below by key (`variables.json`, `editable`: true), each within its range; a key absent is its default, and a job with none is the check exactly as before. An unknown key or a value out of range fails the job with one line (`strength_settings_refused`). Every value the check used, chosen or not, is written back as `strength.settings`.

## The part, loads, supports and material

### Material

Material {{material}}, from the materials file (`--materials`): $E$ = {{youngs_modulus_mpa}} MPa, $\nu$ = {{poisson}}, $\sigma_y$ = {{yield_strength_mpa}} MPa, layer factor $k_z$ = {{z_knockdown}} (in $(0,1]$, forced to 1 for resins), mass density $\rho_m$ = {{material_density_g_cm3}} g/cm³.

### Part identity

With $\mathbf{lo},\mathbf{hi}$ the strength job's mesh box and $\mathbf{lo}',\mathbf{hi}'$ the lattice file's part box, $D$ the latter's diagonal:

$$\max_{a\in\{x,y,z\}}\big(|lo_a-lo'_a|,\ |hi_a-hi'_a|\big)\ \le\ \max\big(\texttt{part\_box\_tol\_mm},\ \texttt{part\_box\_tol\_fraction}\cdot D\big)$$

with {{part_box_tol_mm}} mm and {{part_box_tol_fraction}}; otherwise refused.

### Loads

- **Load-case mode** (job has `loads`): the declared forces on the load faces, mapped by `build_production_loadcase` onto nodal forces of the voxel grid (the same mapping the optimiser uses; the per-node split is in `loadcase.cpp` and was not re-derived here). No self-weight is added.
- **Self-weight mode**: each part voxel carries $\mathbf{f}_e=\rho_m\,g\,h^3\,\hat{\mathbf{g}}\times$ {{gravity_unit}} (N), split equally over its 8 nodes ($g$ = {{gravity_mm_s2}} mm/s²).

### Scenarios

With scenarios, each scenario $s$ the lattice uses ({{lattice_scenarios}}) has its own supports and loads. Supports switched off in $s$ become isotropic springs

$$k_s=\texttt{scenario\_weak\_spring}\cdot E\,h\cdot\max\!\Big(\big(\tfrac{F_s}{F_{\max}}\big)^2,\ \texttt{scenario\_weak\_spring\_min\_scale}\Big),$$

$F_s=\lVert\mathbf f_s\rVert_2$ over its nodal loads; {{scenario_weak_spring}}, {{scenario_weak_spring_min_scale}}. A scenario whose total load is under {{scenario_min_load_share}} of the heaviest is refused when the job is read.

## The safety margin

$S$ = {{safety_margin}} from `loads.safety_margin` (load-case mode; at least {{safety_margin_floor}}, default 1.5) or `margin_stop` (self-weight mode, any $S\ge 0$). It is the threshold every margin below is compared with.

## The small cubes

Cubic voxels of edge

$$h=\frac{\max(L_x,L_y,L_z)}{N},$$

with $N$ = `resolution` = {{resolution}},

reported as `voxel_mm` = {{voxel_mm}}. A voxel belongs to the part when the voxeliser marks it inside the mesh. No design box, no keep-outs: the part's own grid. Every part voxel starts with design density $x_e=1$.

## Which cells count

For each laid cell $c$ of the final layout (type $T$ = {{topology}}, size $s_c$ = {{cell_size_mm}}, own strut width $w_c$ = {{strut_width_mm}}):

### Density

$$\rho_c=\rho_T(s_c,\ r_c),\qquad r_c=\tfrac12 w_c .$$

$\rho_T$ is the measured density law ({{density_from_strut_table}}): with $d_4=2r_c\cdot 4/s_c$ (the diameter at a 4 mm cell), $\rho_c$ is the linear inverse of the table $(\rho_i, d_{4,i})$ between its bracketing rows; off the table it is the cell's integrated solid fraction. Types without a law (bccz, fccz, reentrant) have none.

### Credit

$$\kappa_c=\begin{cases}0 & c\ \text{cut by the part surface}\\ 0 & \text{a bar of }c\text{ was left out of the file}\\ 0 & \text{no law, or }\rho_c\notin[\rho^T_{\min},\rho^T_{\max}]\\ 1 & \text{otherwise}\end{cases}$$

(the three no-credit rules are switched {{no_credit_cut_cells}}, {{no_credit_lost_bar}}, {{no_credit_out_of_band}})

with $\rho^T_{\min}$ = {{rho_min}}, $\rho^T_{\max}$ = {{rho_max}}. A bar $b$ (ends $\mathbf a,\mathbf b$, radius $r_b$) is left out at a place $\mathbf s$ the file writer recorded when

$$\big|\min(a_z,b_z)-r_b-s_z\big|\le\texttt{left\_out\_bar\_z\_tol},\qquad \min_{t\in[0,1]}\lVert\mathbf a+t(\mathbf b-\mathbf a)-\mathbf s\rVert<r_b+\texttt{left\_out\_bar\_reach},$$

({{left_out_bar_z_tol}} mm, {{left_out_bar_reach}} mm). The cell it costs is every cell of the bar's region and size whose cube holds the bar's midpoint (to $10^{-6}$ mm).

### Voxel map

Voxel $e$ of the part is latticed when its centre is held by a cell (`cell_holds`: inside the cell's cube, lattice by the layout's domain, of the cell's region and wall, or absorbed by it), the first such cell in layout order. Then mask $m_e=1$, $\rho_e=\rho_c$ if $\kappa_c=1$. A latticed voxel of a no-credit cell is set to $x_e=0$ and $m_e=0$ for the composite solve (empty). Every other part voxel is solid, $x_e=1$.

## The computer model

### Element and stiffness

Each voxel with material is an 8-node trilinear hexahedron, full $2\times2\times2$ Gauss integration:

$$K_e=\int_{\Omega_e}B^{\mathsf T}D_eB\,d\Omega .$$

- Solid voxel: isotropic $D(E_e,\nu)$ with $E_e=E\,\max(x_e,\rho_{\text{floor}})^p$, $p=3$, $\rho_{\text{floor}}=10^{-3}$. For $x_e=1$, $E_e=E$. An empty (no-credit) voxel keeps $E\,\rho_{\text{floor}}^3$ = {{void_floor}}$\,E$.
- Credited lattice voxel: cubic $D$ with

$$C_{ij}(\rho)=\frac{E}{3500}\Big[(1-t)\,C^{(a)}_{ij}+t\,C^{(a+1)}_{ij}\Big],\quad t=\frac{\rho-\rho_a}{\rho_{a+1}-\rho_a},\quad ij\in\{11,12,44\},$$

from the measured rows {{lattice_stiffness_table}} (homogenised at $E=3500$ MPa; scaling {{library_modulus_scaling}}). Voigt order $[xx,yy,zz,\gamma_{xy},\gamma_{yz},\gamma_{zx}]$. A density outside the resolved rows throws (`LatticeDensityOutOfBand`); the credit rule above keeps that from happening.

### Supports

- Glued ({{anchor_model}} = glued): all three displacements of every node of every support voxel are zero.
- Bearing: one compression-only spring per support-surface node, normal stiffness $k_n=\frac{E_{\text{steel}}}{L}A_n$ ({{bearing_stiffness}} MPa/mm, $A_n$ the node's share of the face area), tangential {{bearing_tangent_fraction}}$\,k_n$. Solve, release springs in tension, re-solve, at most {{contact_rounds}} times.

### Solve

$$K\mathbf u=\mathbf f,\qquad \frac{\lVert\mathbf f-K\mathbf u\rVert}{\lVert\mathbf f\rVert}\le\varepsilon,$$

$\varepsilon$ = {{cg_tolerance}},

preconditioned CG (production routes the composite through the matrix-free multigrid stack; same system, same stopping test), at most {{cg_max_iterations}} iterations (0 = $2n_{\text{dof}}$). A solve that does not converge stops the check: no file.

### Stress

At the element centre ($\xi=\eta=\zeta=0$): $\boldsymbol\sigma_e=D_eB(\mathbf 0)\mathbf u_e$ (true shear), and

$$\sigma_{vm}=\sqrt{\tfrac12\big[(\sigma_{xx}-\sigma_{yy})^2+(\sigma_{yy}-\sigma_{zz})^2+(\sigma_{zz}-\sigma_{xx})^2\big]+3(\tau_{xy}^2+\tau_{yz}^2+\tau_{zx}^2)} .$$

In a lattice voxel this is the smeared (macro) stress $\boldsymbol\Sigma_e$. A voxel is read when $x_e>$ {{printed_threshold}}.

### The re-solve proof

Step 6(a) re-solves the all-solid design and compares margins: $|M'-M|/|M|\le 100\,\varepsilon$ = {{margin_reproduction_band}}. It is written as `resolve_reproduces`, with $M$ (`resolve_margin_solid`) and $M'$ (`resolve_margin_again`); it does not change the verdict.

### Mass

$$m=\frac{\rho_m\,h^3}{1000}\Big(N_{\text{solid}}+\sum_{e\ \text{credited}}\rho_e\Big)\ \text{g}.$$

## Is the load connected

On the composite design ($x_e$ above, no-credit voxels empty): breadth-first walk from every printed support voxel over {{load_path_connectivity}}-connectivity through printed voxels.

$$\text{path\_ok}\iff\text{every load-tagged voxel is reached}$$

(true by definition when the grid has no load voxel or no support voxel, as in self-weight mode). With scenarios, a scenario is unheld when its switched-off springs carry more than {{scenario_unheld_share}} of its load: $\lVert\sum k_s\mathbf u\rVert/\lVert\sum\mathbf f\rVert>$ {{scenario_unheld_share}}. With bearing supports, the part is not accepted when the tangential springs carry more than {{sliding_share_max}} of the total reaction.

## The solid's margin

Over solid printed voxels only (lattice voxels excluded), with build direction $\mathbf n$ = {{build_direction}} (unit; default opposite gravity):

$$\sigma^{\max}_{vm}=\max_e\sigma_{vm,e},\qquad t^{\max}=\max\Big(0,\ \max_e\ \mathbf n^{\mathsf T}\boldsymbol\sigma_e\mathbf n\Big),$$

$$M_{ip}=\frac{\sigma_y}{\sigma^{\max}_{vm}},\qquad M_{il}=\frac{k_z\,\sigma_y}{t^{\max}},\qquad M=\min(M_{ip},M_{il})$$

($+\infty$ when the stress is 0). Infill knockdown, $f$ = {{infill_percent}}/100:

$$k_{\text{inf}}=\begin{cases}1 & f\ge1\\ \max\big(f^{\,a},\ k_{\min}\big) & 0<f<1\\ k_{\min} & f\le0\end{cases}$$

with $a$ = {{infill_exponent}}, $k_{\min}$ = {{infill_floor}}:

$$M_{\text{eff}}=M\cdot k_{\text{inf}} .$$

({{width_aware_knockdown}}: when on, the in-plane term instead uses $\max_e \sigma_{vm,e}/k_e$ with $k_e=f_w+(1-f_w)k_{\text{inf}}$, $f_w=4t(W_e-t)/W_e^2$, $t$ the wall ring from {{wall_loops}} and {{wall_line_width_mm}}; off in production.)

$$\text{accepted}=\text{path\_ok}\ \wedge\ M_{\text{eff}}\ge S\ \wedge\ \neg\text{sliding}\ \wedge\ \text{every scenario accepted and none unheld}.$$

With scenarios the governing one is a non-converged solve first, else the lowest $M_{\text{eff}}$.

## The struts' margin

For every credited lattice voxel, from its smeared stress $\boldsymbol\Sigma$:

$$v=\sigma_{vm}(\boldsymbol\Sigma),\qquad p=\tfrac13\operatorname{tr}\boldsymbol\Sigma,$$

$$b_{vm}=K_d(\rho)\,v+K_v(\rho)\,|p|,\qquad b_{il}=K_{ild}(\rho)\,v+K_{ilv}(\rho)\,|p|+c\,b_{vm},$$

$$c=\frac{2}{\sqrt3}\big(|n_xn_y|+|n_yn_z|+|n_zn_x|\big)$$

(here {{interlayer_cross_factor}}).

$K_\bullet(\rho)$: linear interpolation in the type's measured table {{strut_law_table}}; outside its span {{strut_law_span}} the end row is used and the voxel counted ({{strut_law_clamps_density}}). The term $c\,b_{vm}$ bounds the strut shear seen by an off-axis build direction through $|\sigma_{ab}|\le\sigma_{vm}/\sqrt3$.

$$M^s_{ip}=\frac{\sigma_y}{\max_e b_{vm}},\qquad M^s_{il}=\frac{k_z\,\sigma_y}{\max_e b_{il}},\qquad M^s=\min(M^s_{ip},M^s_{il}).$$

Types with a law: octet, sc, bcc, fcc, diamond, kelvin, rhombic, gyroid, schwarz_d. bccz, fccz, reentrant: none (`strut.uncertified` true).

### When no solid carries the load

({{strut_gate_only_without_solid}}.) The strut margin enters `accepted` only when the solid-only $M_{\text{eff}}=+\infty$ and lattice voxels exist: then if the type has a law and the member is in regime, $M_{\text{eff}}\leftarrow M^s$ and accepted $=\text{path\_ok}\wedge M^s\ge S$; otherwise not certified, accepted = false, with a sentence why.

## Too few cells across

$$n_{\text{cpm}}=\min_{e\ \text{latticed}}\frac{W_e}{s_e},\qquad \text{out of regime}\iff n_{\text{cpm}}<N^*_T$$

with $N^*_T$ = {{cells_per_member_min}}.

$W_e$ is the local member width of the composite design (no-credit voxels empty), measured by the voxel distance transform up to {{thickness_cap_voxels}} voxels with convex corners joined to their member (`lattice_member_width_mm`, floor $N^*_T\cdot s_{\max}$). $N^*_T$ is where the measured bending error of the smeared model crosses {{homogenisation_error_band}} %. Out of regime: the strut numbers are labelled indicative (`regime_note`); with no solid carrying load, not certified.

## The verdict

$$\text{struts\_pass}=\text{law}\wedge M^s\ge S$$

(rule switched {{struts_in_verdict}})

$$\text{verdict}=\begin{cases}\text{fail}&\neg\text{accepted}\\ \text{pass}&\text{accepted}\wedge\text{struts\_pass}\\ \text{solid\_only}&\text{otherwise}\end{cases}$$

The file is made in all three cases. A fail carries `fail_reason`: `load_on_open_lattice` (path fails and some loaded node has a no-credit voxel and no printed voxel among its 8 voxels; with `load_on_no_credit_n` and `load_total_n`, N), `no_load_path`, or `solid_margin` ($M_{\text{eff}}<S$). A fail for another reason (sliding bolts, an unheld scenario) carries none. On fail, the old gate diagnosis is attached (words only; its thin-spot warning uses {{min_feature_warning_threshold}} from the rules file). Written: `accepted`, `struts_pass`, `verdict`, margins $M, M_{ip}, M_{il}$, $S$, `not_certified`(+reason), mass, max smeared lattice $\sigma_{vm}$, $t^{\max}$, cells credited / not, `voxel_mm`, $\mathbf n$, the strut block, `run_info`, time.

### fields.bin

Model frame, v1: grid header; one block of float32 von Mises per voxel (MPa: true in solid voxels, smeared in lattice voxels, 0 where empty), no tensor, float32 displacement per node (mm), mass, support count. Written even on fail. `scenario_fields.bin`: the same per scenario.

## What it does not cover

- Buckling of struts or thin walls (linear statics only), fatigue, creep, temperature, moisture, UV.
- Plasticity or failure progression: one elastic solve, peak stress against one yield value.
- Print defects; the layer factor $k_z$ is one number per material.
- Friction at bolts (bearing springs are near-frictionless).
- The actual strut geometry: the lattice is homogenised; strut peaks come from measured amplification bounds, which the code calls voxel-resolution lower bounds that rise with refinement (`strut_law_resolution_note`).
- Stress concentrations finer than one voxel.

### Open points

(The comments that said the strut law is octet-only and report-only, that out-of-band densities are clamped, that `cell_size_mm` is not used, and that non-octet regime floors are placeholders were corrected to match the code.)


1. The no-credit voxels are called "void"; the solve gives them the SIMP floor $10^{-9}E$ (unless the matrix-free route drops them as islands, which was not traced).
2. The octet strut-law table (PR 259, July) says its rows are on "the SAME rho scale the tensor library uses"; the octet tensor and density laws were re-measured on the full octet on 2026-11-02, the strut table was not changed, and its span (0.04762-0.89598) is narrower than the band (0.04959-0.90027).
3. A cell's density uses its own strut width; the file gives a strut shared by two cells the wider width and runs struts on (S11a). The check can count less lattice than the file holds, never more (consistent with V1).

### References the code cites

Gibson-Ashby $f^{1.5}$ (`analyze.hpp`:521); Onck, Andrews & Gibson 2001, *Int. J. Mech. Sci.* 43(3), doi:10.1016/S0020-7403(00)00042-4 and 00043-6 (cut-cell no-credit rule, `run_job.cpp`:4326-4334); internal evidence: PR 198/237/246 tensor sweeps, PR 259 de-homogenisation probe, `evidence/2026-11-09-lattice-type-strut-laws`, `evidence/2026-11-01-lattice-types-k1`, `2026-07-28-graded-cell-size-phase0` (C2b), `2026-08-08-lattice-variant-margin-tolerance`.
