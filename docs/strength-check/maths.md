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

({{width_aware_knockdown}}: when on, the in-plane term instead uses $\max_e \sigma_{vm,e}/k_e$ with $k_e=f_w+(1-f_w)k_{\text{inf}}$, $f_w=4t(W_e-t)/W_e^2$, $t$ the wall ring from {{wall_loops}} and {{wall_line_width_mm}}; ON by default (the owner, 2026-11-18), for the Organic verdict and the cube verdict alike: the solid within the printed wall thickness of a surface counts at full strength, only the inside takes the infill reduction. The interlayer term keeps $k_{\text{inf}}$.)

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

The octet's table is the full octet's (legs and braces, the cell the engine lays), measured 2026-11-17 (`evidence/2026-11-17-octet-full-strut-law`); its span is the octet band, so no octet density is clamped. Its lowest row ($\rho$ = 0.04959) is bulk only: every boundary fixture there failed the aliasing guard, and the cut layer read about 1.6 times higher, so the row is a lower bound. Until it has a boundary value, a credited cell with $\rho_c<0.10$ (the next row, `strut_law_bulk_only_below`) gives no strut pass: `strut.out_of_regime` is true with a plain `regime_note`, and struts_pass is false.

### When no solid carries the load

({{strut_gate_only_without_solid}}.) The strut margin enters `accepted` only when the solid-only $M_{\text{eff}}=+\infty$ and lattice voxels exist: then if the type has a law and the member is in regime, $M_{\text{eff}}\leftarrow M^s$ and accepted $=\text{path\_ok}\wedge M^s\ge S$; otherwise not certified, accepted = false, with a sentence why.

## Too few cells across

$$n_{\text{cpm}}=\min_{e\ \text{latticed}}\frac{W_e}{s_e},\qquad \text{out of regime}\iff n_{\text{cpm}}<N^*_T$$

with $N^*_T$ = {{cells_per_member_min}}.

$W_e$ is the local member width of the composite design (no-credit voxels empty), measured by the voxel distance transform up to {{thickness_cap_voxels}} voxels with convex corners joined to their member (`lattice_member_width_mm`, floor $N^*_T\cdot s_{\max}$). $N^*_T$ is where the measured bending error of the smeared model crosses {{homogenisation_error_band}} %. Out of regime: the strut numbers are labelled indicative (`regime_note`); with no solid carrying load, not certified.

## The verdict

$$\text{struts\_pass}=\text{law}\wedge M^s\ge S\wedge\min_{c\ \text{credited}}\rho_c\ge\rho^{\text{bulk}}_T$$

($\rho^{\text{bulk}}_T$ = 0.10 for the octet, 0 for every other type; see the struts' margin)

(rule switched {{struts_in_verdict}})

$$\text{verdict}=\begin{cases}\text{fail}&\neg\text{accepted}\\ \text{pass}&\text{accepted}\wedge\text{struts\_pass}\\ \text{solid\_only}&\text{otherwise}\end{cases}$$

The file is made in all three cases. A fail carries `fail_reason`: `load_on_open_lattice` (path fails and some loaded node has a no-credit voxel and no printed voxel among its 8 voxels; with `load_on_no_credit_n` and `load_total_n`, N), `no_load_path`, or `solid_margin` ($M_{\text{eff}}<S$). A fail for another reason (sliding bolts, an unheld scenario) carries none. On fail, the old gate diagnosis is attached (words only; its thin-spot warning uses {{min_feature_warning_threshold}} from the rules file). Written: `accepted`, `struts_pass`, `verdict`, margins $M, M_{ip}, M_{il}$, $S$, `not_certified`(+reason), mass, max smeared lattice $\sigma_{vm}$, $t^{\max}$, cells credited / not, `voxel_mm`, $\mathbf n$, the strut block, `run_info`, time.

### fields.bin

Model frame, v1: grid header; one block of float32 von Mises per voxel (MPa: true in solid voxels, smeared in lattice voxels, 0 where empty), no tensor, float32 displacement per node (mm), mass, support count. Written even on fail. `scenario_fields.bin`: the same per scenario.

## Organic: the frame of beams

A job whose every lattice region is a weave (Organic) is checked by `check_frame` (`core/include/topopt/lattice_layout_frame.hpp`) on the bars the file holds (the sag lift's, less what the writer left out), on the strength job's own grid and load case (as above; scenarios are refused).

### The material per voxel

With $k$ = {{frame_material_subdiv}} and the $k^3$ sub-points $\mathbf x_{e,s}$ of voxel $e$ (centres of a $k^3$ sub-grid), $D(\mathbf x)$ the domain's answer and $C_b$ the capsule of bar $b$ (radius $w_b/2$; links and stubs in):

$$\phi^{\text{sol}}_e=\frac{1}{k^3}\#\{s:\ D(\mathbf x_{e,s})\notin\{\text{Lattice},\text{Outside}\}\},\qquad \phi^{\text{lat}}_e=\frac{1}{k^3}\#\{s:\ D(\mathbf x_{e,s})\in\{\text{Lattice},\text{Outside}\}\wedge \mathbf x_{e,s}\in\textstyle\bigcup_b C_b\}$$

on the part's voxels; $\rho_e=\phi^{\text{sol}}_e+\phi^{\text{lat}}_e\le1$. One solve, $E_e=E\max(\rho_e,\rho_{\min})$ with penalty 1 and $\rho_{\min}$ = {{frame_void_floor}}, gives the nodal displacements $\mathbf U$; $\bar{\mathbf u}_e$ is the mean of voxel $e$'s eight corners.

### The frame

Nodes: bar ends within {{frame_node_weld_mm}} mm, joined transitively. A node is solid when an end there is of kind Solid or $D$ at an end is neither Lattice nor Outside. T-join: a node with one bar that lies inside another bar $ab$ ($t=\frac{(\mathbf x-\mathbf a)\cdot(\mathbf b-\mathbf a)}{|\mathbf b-\mathbf a|^2}\in(10^{-6},1-10^{-6})$, distance to the line under {{frame_tjoin_off_line_mm}} mm, looked for within {{frame_tjoin_reach_mm}} mm) splits it. Pieces shorter than {{frame_zero_piece_mm}} mm are left out. A connected part of the frame with no solid node is left out of the solve and the verdict; one with one solid node, or with fewer than {{frame_collinear_max_driven}} whose nodes have a second singular value of their centred positions under {{frame_collinear_tol_mm}} mm, has its solid nodes' rotations held.

### The drive

A solid node at $\mathbf X$, $R=$ {{frame_drive_ball_voxels}} $h$:

$$\mathbf u(\mathbf X)=\frac{1}{|V|}\sum_{e\in V}\bar{\mathbf u}_e,\qquad V=\{e:\ |\mathbf c_e-\mathbf X|\le R,\ \rho_e>\rho_{\text{drive}}\}$$

($\rho_{\text{drive}}$ = {{frame_drive_share}}). When $V$ is empty: $\mathbf U$ trilinear at $\mathbf X$ over the corners of its grid cell that are in the voxel solve (corners of a voxel of the part), the weights renormalised over them; with no such corner, $R$ grows by $h$ at a time up to {{frame_drive_reach_voxels}} $h$ until $V$ is not empty; with $V$ still empty the node is not driven (free in the frame). A grid node outside the solve is never read. Its translations are fixed to it. A node with an end on the bed floor (the domain says BedFloor there) reads at $\mathbf X+$ {{frame_floor_shift_voxels}} $h\,\mathbf n$ instead; with {{frame_floor_free}} it is not a solid node.

**The Organic verdict.** The solid: $M=\min\!\big(\sigma_y/\max\sigma_{vm},\ k_z\sigma_y/\max t\big)$ over the voxels with solid share $\ge$ {{printed_threshold}}, $M_{\text{eff}}$ by Install 3's gate (the infill curve; with {{width_aware_knockdown}} the per-voxel wall rescue on the member width of the solid share); fail `solid_margin` when $M_{\text{eff}}<S$. `passes_at_infill_percent`: the least whole infill $p\le100$ with $M_{\text{eff}}(p)\ge S$, the other print settings unchanged (null: none). Install 3's voxel load-path test is not applied (written as `voxel_load_path`). The load path (OS9 amended, 2026-11-19): a part of the frame with no driven node (adrift) is handed no load and carries nothing. $F_{\text{adrift}}$ = `load_on_adrift_n` $=\sum s\,|\mathbf f_P|$ over the loaded grid nodes $P$ with an adrift frame node within the load reach and no node of a driven part; fail `no_load_path` when $(F_{\text{unheld}}+F_{\text{adrift}})/|\mathbf F|>$ {{load_unheld_share}}. `loaded_nodes_undriven` stays a count; `adrift_parts` lists each adrift part (centre, bars, length, loaded nodes, load).

### The load on the frame

Over the loaded grid nodes $G$ (forces $\mathbf f_g$, the voxel solve's) and the voxels $E_G$ touching any of them (each once):

$$s=\frac{\sum_{e\in E_G}\phi^{\text{lat}}_e}{\sum_{e\in E_G}\rho_e},\qquad \mathbf F=\sum_g\mathbf f_g,\qquad N=\{n\ \text{not solid, in the solve}:\ \min_g|\mathbf X_n-\mathbf x_g|\le\max(w_{\text{light}},h)\}$$

$s\,\mathbf F/|N|$ goes on each $n\in N$. When $N=\varnothing$, $L_{\text{unheld}}=s|\mathbf F|$ (else 0); fail (`load_on_open_lattice`) when $L_{\text{unheld}}>0$ and $s>$ {{load_unheld_share}}.

### Assembly and solve

Each piece: a 2-node Timoshenko beam (`frame2_stiffness`) of a round section, $d=w$: $A=\pi d^2/4$, $I=\pi d^4/64$, $J=2I$, $G=E/2(1+\nu)$, $\kappa=6(1+\nu)/(7+6\nu)$; a link's matrix times {{frame_link_stiffness}}. Local axes: $\mathbf e_x$ along the piece, $\mathbf e_y=\mathbf r\times\mathbf e_x$ normalised ($\mathbf r=\mathbf z$ unless $|e_{x,z}|\ge0.9$, then $\mathbf x$), $\mathbf e_z=\mathbf e_x\times\mathbf e_y$. $K_{ff}\mathbf u_f=\mathbf F_f-K_{fc}\mathbf u_c$ is solved by `sparse_ldlt_solve` (LDLT, AMD order; refused when the predicted factor passes {{frame_solve_memory_gb}} GB; kept when $\|\mathbf b-K\mathbf u\|/\|\mathbf b\|<10^{-6}$).

### The struts' stress

Per piece, end forces $\mathbf f=k\,T\mathbf u_e$ (the link factor not in $k$): $N=f_7$ (tension +), $M=\max\big(\sqrt{f_5^2+f_6^2},\sqrt{f_{11}^2+f_{12}^2}\big)$,

$$\sigma_t=\frac NA+\frac{M d}{2I},\qquad \sigma_c=-\frac NA+\frac{M d}{2I},\qquad \sin\theta=\frac{|(\mathbf b-\mathbf a)\cdot\mathbf n|}{L}$$

$$m_t=\frac{\sigma_y\cos^2\theta+k_z\sigma_y\sin^2\theta}{\sigma_t},\qquad m_c=\frac{\sigma_y}{\sigma_c}$$

($+\infty$ when the stress is not positive). A strut: non-link pieces joined through nodes with exactly two non-link pieces that are not solid. Its stress margin $m_s=\min(m_t,m_c)$ over its pieces with $L\ge$ {{frame_min_piece}} $w$; buckling (pinned) $m_b=\pi^2E\,I(w_{\min})/(L_s^2\,|N_{\min}|)$ when its most compressive piece has $N_{\min}<0$; margin $m=\min(m_s,m_b)$. A strut with $L_s<w_{\max}$ (a stub) has no margin. Judged: in the solve and not a stub.

### The verdict

$$\text{verdict}=\begin{cases}\text{fail} & L_{\text{unheld}}\text{ too large},\ \neg\text{accepted (solid)},\ \text{or solved}\wedge\exists\ \text{judged}\ m<S\\ \text{solid\_only} & \neg\text{solved, or}\ \textstyle\sum_{\text{undriven}}L_s>u\sum L_s\\ \text{pass} & \text{otherwise}\end{cases}$$

($u$ = {{frame_unjudged_share}}.)

`accepted` is the voxel solve's own gate (the solid's margin as above, on the material $\rho$). Written: Install 3's keys, `struts` {judged, under_safety, under_one, smallest_margin, buckling_failures, stubs, unjudged_mm, load_unheld_n}, the {{frame_weakest}} weakest (middle of the worst piece, width, length, margin, which limit), and `strut_margins.bin`: one float32 per bar in the layout's order, the least margin of the struts its pieces belong to, NaN where not judged.

## Organic: strengthen

`topopt-cli organic-strengthen`: check; stop when no judged strut has $m<S$, or after $N$ = {{strengthen_rounds}} rounds (0: 6 in the additive mode; 2 Traced, 3 Grown in the rebuild mode); else one round, lay again, check again. For every judged strut with $m<m_w$ = {{strengthen_watch_margin}}, $P_s$ its piece ends and middles, $r_s=r$ = {{strengthen_reach}} $\times$ the mean spacing in use in the weave (`spacing_used_mm.mean`):

$$b_v=\max_{s:\ \min_{\mathbf p\in P_s}|\mathbf c_v-\mathbf p|\le r_s}\ \min\!\Big(b_{\max},\Big(\frac{m_w}{m_s}\Big)^{q}\Big)\qquad(1\ \text{elsewhere})$$

with $b_{\max}$ = {{strengthen_boost_max}}, $q$ = {{strengthen_boost_power}}; every component of the stress input's voxel $v$ times $b_v$. A floor per such strut: centre each $\mathbf p\in P_s$, radius $r_s$, least width $w_{\max,s}\,m_t/m_s$, $m_t$ = {{strengthen_target_margin}}. After the lay, every non-link bar whose middle lies in a floor's ball gets $w\leftarrow\min\big(\max(w,w_{\text{floor}}),w_{\text{upper}}\big)$ ($w_{\text{upper}}$: the job's own upper strut width; not applied when the width is one number); links then take the thinner of the struts at their two ends (S8) where that rose. The reference stress is stated at the value resolved for the original input, so the boost does not move it.


**Additive mode** ({{strengthen_mode}} $=0$, the default). The lay is done once; round $n$ checks, then adds. For a watched strut ($m<m_w$) failing by buckling, with $N_{\min}<0$ its most compressive axial force and $w_{\min}$ its thinnest width, $I=\pi w_{\min}^4/64$:
$$L_{\text{allow}}=\pi\sqrt{\frac{E\,I}{|N_{\min}|\,m_t}},\qquad n_b=\Big\lceil \frac{L}{L_{\text{allow}}}\Big\rceil-1$$
brace points evenly along it (rule T's brace maker at named points, each brace as wide as the bar it starts on). A strut failing by stress, or by buckling with a point where no brace could be laid, has each of its own bars (as they are after the round's braces) widened
$$w\leftarrow\min\Big(w_{\text{cap}},\ \max\big(w,\ w\,(m_t/m)^{1/p}\big)\Big),\qquad w_{\text{cap}}=c\,w_{\text{upper}}$$
with $m$ its stress margin and $p$ = {{strengthen_power_axial}} when $|N|/A\ge Mr/I$ at the piece that set it, else {{strengthen_power_bending}}; for buckling $m$ its buckling margin and $p$ = {{strengthen_power_buckling}}; $c$ = {{strengthen_width_cap}}, $w_{\text{upper}}$ the job's upper strut width (its one width without a range). Links at a widened bar's ends take S8 again (only wider). Every bar of round 0 must remain whole or as pieces on its own line (ends within $10^{-5}$ mm), never thinner. The round's operations are saved in order (`additions.bin`) with the 64-bit FNV-1a hash of the bars after it; a lay with them that does not reach each hash is refused (`strengthened_mismatch`). With {{strengthen_mode}} $=1$ the rounds are as above.

**The bars judged (OS16).** Let $P(\mathcal B)$ be the file's print check of bars $\mathcal B$ (make-check-make, tubes route; its bars $\mathcal B'$, the sag pass's, and the kept set $K(\mathcal B')$: present after the layer check's places and the hold rules). Additive: $\mathcal B_0=P(\text{lay})$; round $n$ checks $(\mathcal B_{n},K_n)$, adds ($\mathcal A_n$), then $\mathcal B_{n+1}=P(\mathcal A_n(\mathcal B_n))$, with the pieces of bars of $\mathcal B_n$ that $P$ leaves out (of those in $K_n$), moves, and the bars it adds counted per round (`print_left_out`, `print_left_out_widened`, `print_moved`, `print_added`); the round's hash is $h(\mathcal B_{n+1})$. The file job and the preview's Exact replay the same sequence. Rebuild: each round checks $P(\text{lay})$.

**Relief vines (OS18, amended 2026-11-19).** Let $w_L$ be the upper strut width (the limit: the job's `organic_width_heavy_mm`, else the light width) and $w_{\text{cap}}$ the cap. With {{strengthen_paths}} $=1$, in every additive round from round 0, each judged strut with $m<S$ (not braced along its length this round), with $f$ its widening factor (A) and $w_{\max}$ its widest bar: (1) if $w_{\max}\max(1,f)\le w_L$, it is widened by A and that is all; (2) otherwise it is widened by A to at most $w_L$ and, at most {{strengthen_paths_max}} a round with the least $m$ first, gets one relief step the same round: when its stress is mostly bending, its length exceeds {{strengthen_path_brace_min_mm}} mm and no mid-span brace was tried there before, one brace point at half its length (laid with the round's braces); else, or when that brace was not laid, one vine of width $\min(w_L,\max(w_{\max},w_{\text{host}}))$, while the strut (known by the middle of its worst piece to 0.25 mm) has fewer than {{strengthen_paths_per_strut}} vines over the job; those over the round's count wait at $w_L$; (3) when no relief step is possible (the vine has no room; or its vines are all laid, its brace tried, and it is still under $S$ when checked after them), it is widened by A past $w_L$ up to $w_{\text{cap}}$ (after the round's vines), and counted with its place. A strut with $S\le m<$ {{strengthen_watch_margin}} is widened by A to at most $w_L$. {{strengthen_path_min_gain}} is no longer read. With {{strengthen_paths}} $=0$: no relief step; every watched strut is widened by A up to $w_{\text{cap}}$ (the loop before OS18). At the strut's middle $\mathbf c$ (its bar's point nearest the middle of its worst piece), with $\mathbf e_1,\mathbf e_2,\mathbf e_3$ the principal stress directions of the voxel there and $\mathbf e_a$ the one nearest its axis: seeds $\mathbf c\pm s\,\mathbf e_k$, $k
e a$, $s=	frac12(w_h+w)+g$ ($w$ the vine's width = the strut's, at most $w_{	ext{cap}}$; $g$ OG1's gap, or one line width with the gap off), by the free room at the seed (the least surface distance to any bar) largest first; a seed needs to be lattice of the strut's region and room $\ge g$. From the seed, both ways, $\mathbf p_{i+1}=\mathbf p_i+h\,\mathbf d_i$ with $h=0.35\,d_{	ext{sep}}$ (the tracer's step ratio; $d_{	ext{sep}}$ the strut's strand spacing) and $\mathbf d_i$ the principal direction nearest $\mathbf d_{i-1}$ ($\mathbf d_0=\pm$ the axis), held so that $\mathbf d_i\cdot\mathbf d_0>0$. A half ends on the first bar of another strand it comes within $g$ of (surface to surface) while crossing it (more than {{strengthen_path_parallel_deg}}° off it): its last point is that bar's closest point; or in the solid (its edge). It is dropped when it leaves the region's lattice, turns back, runs within $g$ beside a bar within {{strengthen_path_parallel_deg}}° for more than $d_{	ext{sep}}$, or runs further than {{strengthen_path_max_spacings}} $	imes d_{	ext{sep}}$. Both halves must land; else the next seed; none: `no_room`. A vine is an addition of kind 3 (region, $w$, $d_{	ext{sep}}$, end kinds, points), laid after the round's braces and widening: one new strand, its segments bars, cut at crossings with the new bars only; the round's hash covers it.

## Organic: the solid's weak areas

Per judged voxel $v$ (solid share $\ge$ {{printed_threshold}}), with its own $\sigma_{vm,v}$, layer tension $t_v=\max(0,\mathbf n^\top\boldsymbol\sigma_v\mathbf n)$ and member width $W_v$: the effective margin $M_{\text{eff},v}$ = `gate_margin_effective`$(\sigma_y,k_z,\sigma_{vm,v},\sigma_{vm,v}/k(W_v),t_v)$ at the job's knockdown (scalar: $\min(\sigma_y/\sigma_{vm,v},k_z\sigma_y/t_v)\,f^{1.5}$; width-aware: $\min\big(\sigma_y k(W_v)/\sigma_{vm,v},\ k_z\sigma_y f^{1.5}/t_v\big)$). Then $M_{\text{eff}}=\min_v M_{\text{eff},v}$ exactly. The spots are the connected sets ({{load_path_connectivity}}-connectivity) of voxels with $M_{\text{eff},v}<S$, ordered by their least $M_{\text{eff},v}$; at most {{solid_spots_max}} are written (`solid_margin.spots`, with `spots_total`). Per spot: `worst_at` (the centre of its least voxel), `centroid` (mean of the voxel centres), `box` (the voxels' extent), `voxels`, `mm3`; `raw_margin` $=\min_v\min(\sigma_y/\sigma_{vm,v},k_z\sigma_y/t_v)$; `effective_margin`; `governs` (`in_plane` when the in-plane term is the smaller at the worst voxel, else `interlayer`); `passes_at_infill_percent` = the least whole $p\le100$ with $\min_{v\in\text{spot}}M_{\text{eff},v}(p)\ge S$ (null: none; with one spot it is the whole solid's); `passes_with_walls_credited`: the same at the job's infill with the width-aware wall rescue on (wall thickness from the print settings; a measure of the grid, no new solve). Distances from the worst voxel's centre to the nearest voxel centre that is held (a corner node supported), loaded (a corner node loaded) and of open lattice (lattice share outside the solid $>0$; `lattice_region` the weave region found there): `to_held_mm`, `to_load_mm`, `to_lattice_mm` (null: none). `kind`: `beside_a_fixing`, `beside_the_load`, `beside_the_lattice` when that distance is $\le$ {{solid_spot_near_voxels}} $\times h$, in that order, else `inside_the_solid`; `advice` one sentence per kind. `text`: the plain sentences built from $p_{\text{job}}$, `passes_at_infill_percent` and the spot counts; "Counting the printed walls as solid, it certifies." only when the job does not credit the walls and crediting them makes $\min_v M_{\text{eff},v}\ge S$. Nothing of this is written when the solid passes. `solid_margin.field`: fields.bin's block 2 (`requested_volume_fraction` $-1$): $M_{\text{eff},v}$ as float32 in the von Mises slot, NaN where not judged, no tensor, no displacement.

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
