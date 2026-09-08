# You were right. It was solved in 2009, and we have been doing iteration one of it.

## The short version

The method is **non-invasive iterative global/local coupling** (Gendre, Allix, Gosselet
& Comte, *Non-intrusive and exact global/local techniques for structural problems with
local plasticity*, Computational Mechanics 44(2):233-245, 2009). It converges to the
**exact** solution of the fully coupled problem while only ever solving

- a **cheap global model** that does not contain the real lattice, and
- a **cheap local model** that does.

It is a Dirichlet-Neumann alternating scheme: a Dirichlet problem on the local model, a
Neumann problem on the global one, exchanging interface displacements one way and
interface reactions the other. Gosselet, Blanchard, Allix & Guguin later showed it is a
non-overlapping optimized Schwarz domain decomposition method
(DOI 10.1186/s40323-018-0097-4, open access), which is where the acceleration theory
comes from: Aitken, quasi-Newton, and Robin/optimized interface conditions. It is
implemented in Abaqus's co-simulation engine (arXiv:2404.15299).

**And this is the crucial part: what we have been calling "the submodel" is literally
iteration one of this algorithm** — a one-way displacement transfer with no feedback.
Every accuracy problem of the last two days is the error of stopping after one step.

## Why this dissolves the problem instead of solving it

The convergence criterion is the **incompatibility of interface reactions**: the local
model pushes back on the boundary differently than the global model's surrogate does,
and the algorithm feeds that mismatch back as a correction load until it vanishes. At
convergence the global field is consistent with the *real* struts.

Therefore:

- **The homogenized stiffness no longer has to be accurate.** It only has to be a decent
  preconditioner. It affects the number of iterations, not the answer.
- Every question of the last two days — is ρ/3 right, should it be directional, does the
  2.2-cells-across problem invalidate homogenization — collapses into "how fast does it
  converge", which is a performance question, not a correctness one.
- Our measured starting errors (0.6 % and 11 % isotropic, 19 % and 36 % directional) are
  now just first-iteration residuals. The isotropic surrogate being the better one simply
  means it is the better preconditioner.
- **The global operator never changes between iterations**, so it is factored once and
  every subsequent iteration is a back-substitution.

## The device architecture this enables

| stage | model | solver | memory |
|---|---|---|---|
| global | solid only, lattice regions as soft continuum | **matrix-free iterative** | small |
| local | lattice + two-voxel collar, real struts | direct | 0.04-0.21 GB measured |
| coupling | exchange interface displacements and reactions | — | negligible |

The global stage is the important line. The reason the certificate uses a direct solver
at all is that mixing beams with solid produced a system the iterative solver crawled on
(an hour versus ten seconds, measured earlier). **A solid-only global model does not have
that pathology, and the app already runs a 1.47M-DOF matrix-free solid solve on this
hardware for the optimizer.** So the expensive half of the coupling is a problem the
device is already known to handle.

Peak memory becomes the larger of the two stages, roughly 0.2-0.3 GB, against 3.25-5.54 GB
today.

## What the size-effect literature says, and why our failures were expected

This is worth recording because it means the last two experiments were not mistakes, they
were the known behaviour:

- **Size effects in thin strips of cellular material are strongly anisotropic**
  (arXiv:2009.10404, open): with few cells across, tension and bending are **softer** than
  the bulk homogenized value while shear is **stiffer**, and the paper attributes the
  softening to stress-gradient effects. That is precisely our two failures: the isotropic
  surrogate was too stiff (lattice under-stressed), and the directional one — which
  manufactures shear stiffness out of curved struts — was worse.
- **Classical homogenization is not stable below roughly 7x7 cells.** RVE convergence
  studies put the largest deviations between 1x1 and 6x6 and find smooth behaviour only
  above 7x7. Our walls are ~2.2 cells thick.
- **The standard enrichment for this regime is micropolar (Cosserat) or strain-gradient
  homogenization**, which adds a length scale so the continuum can represent size effects.
  Rigorous convergence rates for beam lattices to micropolar continua now exist
  (arXiv:2508.03512, open).

So nobody has made classical homogenization work at two cells, and nobody claims to. What
the field solved is the need for it to be accurate at all.

## Two honourable mentions found on the way

- **Substructuring with superelement reuse.** Condensing a substructure's interior is
  *exact* in linear statics, and the condensation is reused across design changes. Our
  solid is identical across every lattice candidate the probe tries, so it would be
  condensed once per part and reused for all candidates. This is the right answer for the
  **probe's** cost, separately from the device question. It does not help the device
  directly: our interface is 18-38k DOF, so the explicit condensed operator is a dense
  2.5-5.9 GB block, which I measured earlier.
- **The solid-lattice interface is its own research topic** in additive manufacturing,
  including a global-local J-integral method for cracking at exactly that interface
  (ScienceDirect PII S2214860420309623). Relevant later if the interface becomes a
  failure site rather than a modelling boundary.

## What I propose to do next

Implement the iteration in the research harness and measure it on the two M2
configurations, which are the only ones that can discriminate. Everything needed is
already built: the soft global solve, the local submodel with prescribed cut
displacements, and the exact coupled reference to check against. What is missing is the
feedback step, roughly: extract the local model's interface reaction, subtract the global
surrogate's, apply the difference as a correction load, re-solve the global with its kept
factor, repeat.

The measurement I want is a convergence table: first-iteration error (which we already
know, 11 % and 36 %) against iterations two, three, four. If it drops to the noise floor
in a handful of iterations, the whole memory problem is closed on measured numbers, and
the stiffness estimate stops mattering.

## Papers I could not read

| what | why it matters | status |
|---|---|---|
| Gendre, Allix, Gosselet, Comte, *Non-intrusive and exact global/local techniques for structural problems with local plasticity*, Comput. Mech. 44(2):233-245 (2009), DOI **10.1007/s00466-009-0372-9** | the original method paper; I want its exact algorithm statement and convergence proof | paywalled |
| Gosselet, Blanchard, Allix, Guguin, *Non-invasive global-local coupling as a Schwarz domain decomposition method*, DOI **10.1186/s40323-018-0097-4** | OPEN ACCESS, but Springer blocked my fetcher (303 to a login). Any browser will open it. This is the one with the acceleration and convergence-rate theory | not paywalled, blocked |
| *Continualization method of lattice materials and analysis of size effects revisited based on Cosserat models*, Int. J. Solids Struct., PII **S0020768322003584** | the Cosserat correction for few-cell size effects | paywalled |
| *Homogenization of fully nonlinear rod lattice structures: on the size of the RVE*, DOI **10.1007/s00466-021-02123-0** | would give the quantified "how many cells" answer for rod lattices specifically | paywalled |
| *Global-Local non intrusive analysis with Robin parameters*, DOI **10.1007/s00466-021-02124-z** | the Robin/optimized interface conditions that accelerate convergence most | paywalled |

Read and used, all open: arXiv:2009.10404 (size effects in strips), arXiv:2508.03512
(homogenization rates to micropolar), arXiv:2404.15299 (Abaqus implementation), plus the
five PDFs you supplied.
