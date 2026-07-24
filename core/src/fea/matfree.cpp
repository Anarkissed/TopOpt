// Matrix-free global stiffness operator + matrix-free Jacobi-CG for the voxel
// FEA (handoff 077: matrix-free operator). The assembled sparse global K is what
// OOMs on large (design-box) grids; this computes the IDENTICAL linear system
// element-by-element WITHOUT ever assembling K.
//
// KEY: this translation unit is deliberately Eigen-FREE — it includes no Eigen
// header and constructs no sparse matrix. The ONLY dense storage representing K
// is the single 24x24 reference element stiffness Ke (576 doubles), independent
// of grid size (see fea_matfree_operator_storage_doubles). Every apply is a
// gather -> local 24x24 multiply -> scatter over the solid voxels, exploiting
// the regular grid where every element is the same unit cube: K(E) = E * Ke, so
// each element's contribution scales its reference block by the voxel modulus.
//
// The matrix-free CG mirrors fea_solve_cg exactly: same free-DOF numbering, same
// M3.1 void-DOF gate (resolved topologically — a free DOF survives iff it is
// touched by a solid element, which equals the assembled diagonal-zero test for
// strictly-positive moduli, as PenalizedSolver already relies on), same Jacobi
// (diagonal) preconditioner, and the same relative-residual stopping criterion
// and iteration algorithm Eigen's ConjugateGradient<DiagonalPreconditioner> uses
// — so it converges to the same displacement field. The assembled fea_solve_cg
// path is untouched; these are new, opt-in entry points.
//
// The element table (mf_build_elems), the element-by-element apply
// (mf_apply_full), the reduced void-gated system (mf_build_reduced) and the
// matrix-free Jacobi-CG (mf_cg_solve) live in fea_detail (declared in the
// internal fea_matfree.hpp) so the matrix-free MULTIGRID solver (multigrid.cpp)
// can reuse the identical apply, diagonal and void gate as its FINE level — it
// must not reimplement them.

#include "topopt/fea.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <functional>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "fea_matfree.hpp"
#include "recycle.hpp"

#if defined(__ARM_NEON)
#include <arm_neon.h>
#elif defined(__SSE2__)
#include <emmintrin.h>
#endif

namespace topopt {

namespace fea_detail {

namespace {
constexpr int kDof = Hex8Stiffness::kDof;  // 24

// AXPY over the 24 output DOFs: acc[r] += w * col[r] for r in [0,24), with acc and
// col contiguous. This is the SIMD-friendly restructuring of the element apply:
// the reference-block matvec y_r = sum_c Ke[r][c] ul[c] is accumulated COLUMN by
// column (fixed c, all r) instead of row-dot (fixed r, all c), so each step is a
// contiguous vertical AXPY with NO horizontal reduction. Because for each output r
// the terms are still summed in ascending-c order (one column per c), the result
// is BIT-FOR-BIT identical to the original row-dot loop — same terms, same order.
// A plain multiply+add (never a fused FMA) is used in every lane so the vector and
// scalar paths agree to the last bit and the 078 iteration-count parity is
// preserved without relying on the compiler's fp-contraction setting.
inline void axpy24(double* acc, double w, const double* col) {
#if defined(__ARM_NEON)
  // NEON: 2-wide doubles (the width the task calls out for Apple Silicon).
  const float64x2_t wv = vdupq_n_f64(w);
  for (int r = 0; r < kDof; r += 2) {
    float64x2_t a = vld1q_f64(acc + r);
    a = vaddq_f64(a, vmulq_f64(wv, vld1q_f64(col + r)));  // mul+add, no FMA
    vst1q_f64(acc + r, a);
  }
#elif defined(__SSE2__)
  // x86 proxy: SSE2 packed doubles, also 2-wide (matches NEON width) so the
  // on-device NEON behaviour is faithfully represented by the local measurement.
  const __m128d wv = _mm_set1_pd(w);
  for (int r = 0; r < kDof; r += 2) {
    __m128d a = _mm_loadu_pd(acc + r);
    a = _mm_add_pd(a, _mm_mul_pd(wv, _mm_loadu_pd(col + r)));  // mul+add, no FMA
    _mm_storeu_pd(acc + r, a);
  }
#else
  for (int r = 0; r < kDof; ++r) acc[r] += w * col[r];
#endif
}

// Column-major copy of the reference block: KeCM[c*24 + r] = Ke[r][c]. Built once
// per apply so the per-element loop reads whole columns of Ke contiguously (the
// AXPY operand above). 576 doubles, negligible next to the element loop.
inline void build_ke_colmajor(const Hex8Stiffness& Ke, double* KeCM) {
  for (int r = 0; r < kDof; ++r)
    for (int c = 0; c < kDof; ++c)
      KeCM[static_cast<std::size_t>(c) * kDof + r] = Ke.k[static_cast<std::size_t>(r) * kDof + c];
}

// Apply the reference block to ONE element: y[edof] += factor * (Ke * ul). Reads
// its 24 inputs from x by edof (gather), does the column-major AXPY into res, then
// scatters factor*res back into y. Bit-identical to the original per-element loop.
inline void apply_one_element(const MfElem& el, const double* KeCM,
                              const std::vector<double>& x,
                              std::vector<double>& y) {
  alignas(16) double ul[kDof];
  alignas(16) double res[kDof];
  for (int r = 0; r < kDof; ++r) {
    ul[r] = x[static_cast<std::size_t>(el.edof[r])];
    res[r] = 0.0;
  }
  for (int c = 0; c < kDof; ++c)
    axpy24(res, ul[c], &KeCM[static_cast<std::size_t>(c) * kDof]);
  for (int r = 0; r < kDof; ++r)
    y[static_cast<std::size_t>(el.edof[r])] += el.factor * res[r];
}

// --- SINGLE-PRECISION apply kernel (mixed-precision V-cycle, handoff 092) ------
//
// The FP32 twin of axpy24/apply_one_element, used ONLY inside the mixed-precision
// multigrid V-cycle (the preconditioner). The outer CG — residual, dot products,
// x/r/p, the convergence test — stays FP64 and drives the FP64 kernel above; this
// float kernel never touches the correctness-defining residual. Halving the bytes
// moved per element (24 float loads/stores vs 24 double) is the bandwidth win the
// task targets: the apply is memory-bound on x/y, and Ke stays in L1 either way.
//
// DETERMINISM is preserved exactly as in the FP64 kernel: the 8-colour partition
// still guarantees each node is written by exactly one element per colour, so a
// node's (<=8) contributions accumulate in strict colour order independent of
// thread count; within an element the terms sum in ascending-c order. Float add is
// non-associative, but the ORDER is fixed, so the result is bit-identical for 1 vs
// N threads and run-to-run. Plain mul+add (never FMA), matching axpy24, so no lane
// depends on the compiler's fp-contraction setting.
inline void axpy24_f32(float* acc, float w, const float* col) {
#if defined(__ARM_NEON)
  const float32x4_t wv = vdupq_n_f32(w);
  for (int r = 0; r < kDof; r += 4) {
    float32x4_t a = vld1q_f32(acc + r);
    a = vaddq_f32(a, vmulq_f32(wv, vld1q_f32(col + r)));  // mul+add, no FMA
    vst1q_f32(acc + r, a);
  }
#elif defined(__SSE2__)
  const __m128 wv = _mm_set1_ps(w);
  for (int r = 0; r < kDof; r += 4) {
    __m128 a = _mm_loadu_ps(acc + r);
    a = _mm_add_ps(a, _mm_mul_ps(wv, _mm_loadu_ps(col + r)));  // mul+add, no FMA
    _mm_storeu_ps(acc + r, a);
  }
#else
  for (int r = 0; r < kDof; ++r) acc[r] += w * col[r];
#endif
}

// Column-major FLOAT copy of the reference block: KeCM[c*24+r] = float(Ke[r][c]).
// The reference Ke is a geometric constant (576 doubles); rounding it to float once
// per apply is negligible and keeps the hot loop reading contiguous float columns.
inline void build_ke_colmajor_f32(const Hex8Stiffness& Ke, float* KeCM) {
  for (int r = 0; r < kDof; ++r)
    for (int c = 0; c < kDof; ++c)
      KeCM[static_cast<std::size_t>(c) * kDof + r] =
          static_cast<float>(Ke.k[static_cast<std::size_t>(r) * kDof + c]);
}

inline void apply_one_element_f32(const MfElem& el, const float* KeCM,
                                  const std::vector<float>& x,
                                  std::vector<float>& y) {
  alignas(16) float ul[kDof];
  alignas(16) float res[kDof];
  for (int r = 0; r < kDof; ++r) {
    ul[r] = x[static_cast<std::size_t>(el.edof[r])];
    res[r] = 0.0f;
  }
  for (int c = 0; c < kDof; ++c)
    axpy24_f32(res, ul[c], &KeCM[static_cast<std::size_t>(c) * kDof]);
  const float f = static_cast<float>(el.factor);
  for (int r = 0; r < kDof; ++r)
    y[static_cast<std::size_t>(el.edof[r])] += f * res[r];
}

// Requested worker-thread count (0 = auto). Global, set once per run; the apply
// reads it. Determinism does NOT depend on it (colour partition), so it is a pure
// performance knob.
std::atomic<int> g_mf_threads{0};

// Minimum elements per worker chunk: below this a colour runs serially, since a
// chunk must carry enough work to amortise the (microsecond) pool dispatch. 1024
// elements is ~1 ms of apply work — comfortably above the wakeup cost — and keeps
// small grids from over-threading while letting moderate grids engage the pool.
constexpr int kMinElemsPerThread = 1024;

// Persistent fork-join worker pool for the element apply. Workers are spawned ONCE
// (lazily, and grown on demand) and reused across every apply of the whole solve —
// the thousands of matvecs a design-box optimise runs. (An earlier version spawned
// std::threads per apply; the repeated pthread stack mmap/join made 4 threads
// ~2x SLOWER than serial in-solve. A persistent pool woken by a condition variable
// costs microseconds per dispatch.) Determinism is unaffected: which worker runs
// which contiguous chunk of a colour never changes the result (a colour's elements
// share no node). Assumes applies are not issued concurrently from multiple
// threads — true for the single optimise loop that drives the solver.
class ApplyPool {
 public:
  static ApplyPool& instance() {
    static ApplyPool p;
    return p;
  }

  // Run body(lo,hi) over [begin,end) split into `n` contiguous chunks (chunk 0 on
  // the calling thread, the rest on workers); block until all chunks finish.
  void run(int n, int begin, int end,
           const std::function<void(int, int)>& body) {
    const int total = end - begin;
    if (total <= 0) return;
    if (n <= 1) { body(begin, end); return; }
    ensure(n - 1);
    const int chunk = (total + n - 1) / n;
    {
      std::unique_lock<std::mutex> lk(mu_);
      body_ = &body;
      begin_ = begin; end_ = end; chunk_ = chunk;
      active_workers_ = n - 1;
      remaining_ = n - 1;
      ++gen_;
    }
    cv_work_.notify_all();
    body(begin, std::min(end, begin + chunk));  // calling thread does chunk 0
    std::unique_lock<std::mutex> lk(mu_);
    cv_done_.wait(lk, [this] { return remaining_ == 0; });
  }

  ~ApplyPool() {
    {
      std::unique_lock<std::mutex> lk(mu_);
      stop_ = true;
      ++gen_;
    }
    cv_work_.notify_all();
    for (std::thread& t : workers_)
      if (t.joinable()) t.join();
  }

 private:
  void ensure(int want_workers) {
    // Only the calling (main) thread grows the pool, and never during a dispatch,
    // so no lock is needed against the workers here.
    while (static_cast<int>(workers_.size()) < want_workers) {
      const int id = static_cast<int>(workers_.size());
      workers_.emplace_back([this, id] { worker_loop(id); });
    }
  }

  void worker_loop(int id) {
    long seen = 0;
    for (;;) {
      const std::function<void(int, int)>* body;
      int begin, end, chunk;
      {
        std::unique_lock<std::mutex> lk(mu_);
        cv_work_.wait(lk, [this, seen] { return stop_ || gen_ != seen; });
        if (stop_) return;
        seen = gen_;
        if (id >= active_workers_) continue;  // idle this round
        body = body_; begin = begin_; end = end_; chunk = chunk_;
      }
      const int lo = begin + (id + 1) * chunk;  // worker id handles chunk id+1
      const int hi = std::min(end, lo + chunk);
      if (lo < hi) (*body)(lo, hi);
      {
        std::unique_lock<std::mutex> lk(mu_);
        if (--remaining_ == 0) cv_done_.notify_one();
      }
    }
  }

  std::mutex mu_;
  std::condition_variable cv_work_, cv_done_;
  std::vector<std::thread> workers_;
  const std::function<void(int, int)>* body_ = nullptr;
  int begin_ = 0, end_ = 0, chunk_ = 0;
  int active_workers_ = 0;
  int remaining_ = 0;
  long gen_ = 0;
  bool stop_ = false;
};

// Run body over [begin,end) split for `nthreads`, honouring the min-work threshold.
inline void parallel_ranges(int begin, int end, int nthreads,
                            const std::function<void(int, int)>& body) {
  const int n = end - begin;
  if (n <= 0) return;
  int t = nthreads;
  if (t < 1) t = 1;
  if (t > 1) t = std::min(t, (n + kMinElemsPerThread - 1) / kMinElemsPerThread);
  if (t <= 1) { body(begin, end); return; }
  ApplyPool::instance().run(t, begin, end, body);
}
}  // namespace

int mf_set_thread_count(int n) { return g_mf_threads.exchange(n); }

void mf_parallel_ranges(int begin, int end, int min_per_thread,
                        const std::function<void(int, int)>& body) {
  const int n = end - begin;
  if (n <= 0) return;
  int t = mf_thread_count();
  if (t < 1) t = 1;
  const int floor_work = min_per_thread > 0 ? min_per_thread : 1;
  if (t > 1) t = std::min(t, (n + floor_work - 1) / floor_work);
  if (t <= 1) { body(begin, end); return; }
  ApplyPool::instance().run(t, begin, end, body);
}

// Galerkin block cache toggle (handoff 090). Opt-in, DEFAULT OFF, so the
// pre-090 build path is what runs unless a caller asks for the cache.
namespace {
std::atomic<bool> g_mf_galerkin_block_cache{false};
}
bool mf_set_galerkin_block_cache(bool enable) {
  return g_mf_galerkin_block_cache.exchange(enable);
}
bool mf_galerkin_block_cache_enabled() {
  return g_mf_galerkin_block_cache.load();
}

// Mixed-precision V-cycle toggle (handoff 092). Opt-in, DEFAULT OFF: the FP64
// matrix-free multigrid path is what runs — byte-identical, 078 parity intact —
// unless a caller asks for the single-precision V-cycle.
namespace {
std::atomic<bool> g_mf_mixed_precision{false};
}
bool mf_set_mixed_precision(bool enable) {
  return g_mf_mixed_precision.exchange(enable);
}
bool mf_mixed_precision_enabled() {
  return g_mf_mixed_precision.load();
}

int mf_thread_count() {
  int n = g_mf_threads.load();
  if (n <= 0) {
    n = static_cast<int>(std::thread::hardware_concurrency());
    if (n <= 0) n = 1;
  }
  return n;
}

// Build the solid-element table (edof + factor), SORTED BY COLOUR. `elem_youngs`
// selects the graded path (factor = per-voxel modulus, validated > 0) when
// non-null; otherwise the uniform path (factor = 1, the modulus baked into Ke).
// The elements are emitted colour 0..7 (colour = parity of i,j,k), each colour in
// grid-scan order, so the apply can process one colour at a time. `color_offsets`,
// if given, receives the kNumColors+1 range delimiters.
std::vector<MfElem> mf_build_elems(const VoxelGrid& grid,
                                   const std::vector<double>* elem_youngs,
                                   const char* who,
                                   std::vector<int>* color_offsets,
                                   const std::vector<char>* active_mask) {
  if (elem_youngs != nullptr && elem_youngs->size() != grid.voxel_count())
    throw std::invalid_argument(
        std::string(who) + ": per-voxel modulus vector size != voxel_count");
  if (active_mask != nullptr && active_mask->size() != grid.voxel_count())
    throw std::invalid_argument(
        std::string(who) + ": active-domain mask size != voxel_count");

  // Bucket by colour in grid-scan order (validating graded moduli as we go), then
  // concatenate colour 0..7. Two passes would re-scan; one pass into 8 buckets
  // keeps a single grid traversal and preserves scan order within each colour.
  std::vector<MfElem> buckets[kNumColors];
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        // ACTIVE DOMAIN: an out-of-band solid voxel contributes no element. The
        // skip happens BEFORE the modulus validation, so a masked-out voxel's
        // modulus is never read — the mask, not the field, decides what exists.
        if (active_mask != nullptr &&
            (*active_mask)[grid.index(i, j, k)] == 0)
          continue;
        MfElem el;
        if (elem_youngs != nullptr) {
          el.factor = (*elem_youngs)[grid.index(i, j, k)];
          if (!(el.factor > 0.0))
            throw std::invalid_argument(
                std::string(who) +
                ": per-voxel Young's modulus must be > 0 on a solid voxel");
        }
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) el.edof[3 * a + c] = 3 * en[a] + c;
        const int color = (i & 1) | ((j & 1) << 1) | ((k & 1) << 2);
        buckets[color].push_back(el);
      }

  std::vector<MfElem> elems;
  elems.reserve(grid.solid_count());
  if (color_offsets) color_offsets->assign(kNumColors + 1, 0);
  for (int color = 0; color < kNumColors; ++color) {
    if (color_offsets) (*color_offsets)[color] = static_cast<int>(elems.size());
    elems.insert(elems.end(), buckets[color].begin(), buckets[color].end());
  }
  if (color_offsets) (*color_offsets)[kNumColors] = static_cast<int>(elems.size());
  return elems;
}

// y = K x over the full global stiffness, COLOUR by COLOUR in fixed order 0..7.
// Within a colour no two elements share a node, so the colour's elements are
// apply'd in parallel (parallel_ranges) with NO races and NO order dependence —
// each node is written by exactly one element per colour, and the (up to 8)
// contributions to a node accumulate strictly in colour order. The result is thus
// bit-identical for any thread count. `x`/`y` are full ndof vectors; `y` is zeroed
// then accumulated.
void mf_apply_full(const std::vector<MfElem>& elems,
                   const std::vector<int>& color_offsets, const Hex8Stiffness& Ke,
                   const std::vector<double>& x, std::vector<double>& y) {
  std::fill(y.begin(), y.end(), 0.0);
  alignas(16) double KeCM[static_cast<std::size_t>(kDof) * kDof];
  build_ke_colmajor(Ke, KeCM);
  const int nthreads = mf_thread_count();
  // One std::function for the whole apply (all colours use the same body; only the
  // [lo,hi) range differs), so the per-colour dispatch never re-allocates it.
  const std::function<void(int, int)> body = [&](int lo, int hi) {
    for (int i = lo; i < hi; ++i)
      apply_one_element(elems[static_cast<std::size_t>(i)], KeCM, x, y);
  };
  for (int color = 0; color < kNumColors; ++color) {
    const int b = color_offsets[static_cast<std::size_t>(color)];
    const int e = color_offsets[static_cast<std::size_t>(color) + 1];
    parallel_ranges(b, e, nthreads, body);
  }
}

void MatfreeReduced::apply_kgg_raw(const double* xg, double* yg) const {
  std::fill(xfull.begin(), xfull.end(), 0.0);
  for (int k = 0; k < ng; ++k)
    xfull[static_cast<std::size_t>(kept_global[static_cast<std::size_t>(k)])] =
        xg[static_cast<std::size_t>(k)];
  mf_apply_full(elems, color_offsets, Ke, xfull, yfull);
  // yg is fully overwritten (every kept DOF is written), so no pre-zero needed.
  for (int k = 0; k < ng; ++k)
    yg[static_cast<std::size_t>(k)] =
        yfull[static_cast<std::size_t>(kept_global[static_cast<std::size_t>(k)])];
}

// Single-precision twin of mf_apply_full: y = K x over the full stiffness, FP32,
// colour by colour in the SAME fixed order 0..7 with the SAME race-free threading,
// so it is bit-identical for any thread count (see axpy24_f32). Used only by the
// mixed-precision V-cycle.
void mf_apply_full_f32(const std::vector<MfElem>& elems,
                       const std::vector<int>& color_offsets,
                       const Hex8Stiffness& Ke, const std::vector<float>& x,
                       std::vector<float>& y) {
  std::fill(y.begin(), y.end(), 0.0f);
  alignas(16) float KeCM[static_cast<std::size_t>(kDof) * kDof];
  build_ke_colmajor_f32(Ke, KeCM);
  const int nthreads = mf_thread_count();
  const std::function<void(int, int)> body = [&](int lo, int hi) {
    for (int i = lo; i < hi; ++i)
      apply_one_element_f32(elems[static_cast<std::size_t>(i)], KeCM, x, y);
  };
  for (int color = 0; color < kNumColors; ++color) {
    const int b = color_offsets[static_cast<std::size_t>(color)];
    const int e = color_offsets[static_cast<std::size_t>(color) + 1];
    parallel_ranges(b, e, nthreads, body);
  }
}

// Raw FP32 reduced matvec yg[0..ng) = K_gg xg[0..ng), driven off contiguous float
// storage with NO marshalling copies (the mixed-precision V-cycle reuses the
// caller's float buffers across iterations). Full-length float scratch is sized
// lazily on first use, so the FP64 path pays nothing for it.
void MatfreeReduced::apply_kgg_raw_f32(const float* xg, float* yg) const {
  if (xfull_f.size() != static_cast<std::size_t>(ndof)) {
    xfull_f.assign(static_cast<std::size_t>(ndof), 0.0f);
    yfull_f.assign(static_cast<std::size_t>(ndof), 0.0f);
  }
  std::fill(xfull_f.begin(), xfull_f.end(), 0.0f);
  for (int k = 0; k < ng; ++k)
    xfull_f[static_cast<std::size_t>(kept_global[static_cast<std::size_t>(k)])] =
        xg[static_cast<std::size_t>(k)];
  mf_apply_full_f32(elems, color_offsets, Ke, xfull_f, yfull_f);
  for (int k = 0; k < ng; ++k)
    yg[static_cast<std::size_t>(k)] =
        yfull_f[static_cast<std::size_t>(kept_global[static_cast<std::size_t>(k)])];
}

void MatfreeReduced::apply_kgg(const std::vector<double>& xg,
                               std::vector<double>& yg) const {
  yg.resize(static_cast<std::size_t>(ng));
  apply_kgg_raw(xg.data(), yg.data());
}

// Build the matrix-free reduced system. Mirrors assemble_reduced + the M3.1 gate
// (void_dof_survivors) but without ever assembling a sparse matrix. On a void-gate
// rejection it sets `*info` (converged=false, 0 iterations) and throws, matching
// solve_reduced_cg's behaviour.
MatfreeReduced mf_build_reduced(const VoxelGrid& grid, double youngs_modulus,
                                double poisson,
                                const std::vector<DirichletBC>& bcs,
                                const std::vector<NodalLoad>& loads,
                                const std::vector<double>* elem_youngs,
                                const char* who, CgInfo* info,
                                const std::vector<char>* active_mask) {
  const int num_nodes = fea_node_count(grid);
  const int ndof = 3 * num_nodes;

  MatfreeReduced m;
  m.ndof = ndof;
  m.Ke = hex8_stiffness(elem_youngs != nullptr ? 1.0 : youngs_modulus, poisson,
                        grid.spacing);
  m.elems = mf_build_elems(grid, elem_youngs, who, &m.color_offsets, active_mask);
  m.xfull.assign(static_cast<std::size_t>(ndof), 0.0);
  m.yfull.assign(static_cast<std::size_t>(ndof), 0.0);

  // Dirichlet BCs -> fixed mask + prescribed field up (validate indices).
  std::vector<char> fixed(static_cast<std::size_t>(ndof), 0);
  m.up.assign(static_cast<std::size_t>(ndof), 0.0);
  bool nonzero_bc = false;
  for (const DirichletBC& bc : bcs) {
    if (bc.node < 0 || bc.node >= num_nodes || bc.component < 0 ||
        bc.component > 2)
      throw std::invalid_argument(std::string(who) + ": BC index out of range");
    const int dof = 3 * bc.node + bc.component;
    fixed[static_cast<std::size_t>(dof)] = 1;
    m.up[static_cast<std::size_t>(dof)] = bc.value;
    if (bc.value != 0.0) nonzero_bc = true;
  }

  // Load vector (validate indices).
  std::vector<double> f(static_cast<std::size_t>(ndof), 0.0);
  for (const NodalLoad& l : loads) {
    if (l.node < 0 || l.node >= num_nodes || l.component < 0 || l.component > 2)
      throw std::invalid_argument(std::string(who) + ": load index out of range");
    f[static_cast<std::size_t>(3 * l.node + l.component)] += l.value;
  }

  // rhs_full = f - K*up. up is all-zero unless a prescribed non-zero BC exists,
  // in which case K*up is the matrix-free apply of the prescribed field.
  std::vector<double> rhs_full = f;
  if (nonzero_bc) {
    std::vector<double> kup(static_cast<std::size_t>(ndof), 0.0);
    mf_apply_full(m.elems, m.color_offsets, m.Ke, m.up, kup);
    for (int d = 0; d < ndof; ++d)
      rhs_full[static_cast<std::size_t>(d)] -= kup[static_cast<std::size_t>(d)];
  }

  // Free-DOF numbering.
  std::vector<int> free_of_dof(static_cast<std::size_t>(ndof), -1);
  int nf = 0;
  for (int d = 0; d < ndof; ++d)
    if (!fixed[static_cast<std::size_t>(d)]) free_of_dof[static_cast<std::size_t>(d)] = nf++;

  // M3.1 void-DOF gate, resolved topologically: a free DOF survives iff a solid
  // element touches it (equivalent to the assembled non-zero-diagonal test for
  // strictly-positive moduli). Also accumulate the Jacobi diagonal in the same
  // sweep (diag[d] += factor_e * Ke(local,local)).
  std::vector<char> touched(static_cast<std::size_t>(nf), 0);
  std::vector<double> diagfull(static_cast<std::size_t>(ndof), 0.0);
  for (const MfElem& el : m.elems)
    for (int r = 0; r < kDof; ++r) {
      const int fr = free_of_dof[static_cast<std::size_t>(el.edof[r])];
      if (fr >= 0) touched[static_cast<std::size_t>(fr)] = 1;
      diagfull[static_cast<std::size_t>(el.edof[r])] +=
          el.factor * m.Ke(r, r);
    }

  // Under-constrained: every free DOF void (no stiffness anywhere).
  if (nf > 0) {
    bool any = false;
    for (int fr = 0; fr < nf; ++fr)
      if (touched[static_cast<std::size_t>(fr)]) { any = true; break; }
    if (!any) {
      if (info) { info->converged = false; info->iterations = 0; info->residual = 0.0; }
      throw std::runtime_error(
          std::string(who) +
          ": singular system (no stiffness — every free DOF is void)");
    }
  }

  // Void-load check: a load on a stiffness-free (void) free DOF has no
  // equilibrium. rmax over ALL free DOFs of |rhs_full| (matches the assembled
  // gate, which forms rmax over the reduced RHS rf).
  double rmax = 0.0;
  for (int d = 0; d < ndof; ++d) {
    const int fr = free_of_dof[static_cast<std::size_t>(d)];
    if (fr >= 0) rmax = std::max(rmax, std::fabs(rhs_full[static_cast<std::size_t>(d)]));
  }
  const double load_tol = 1e-9 * rmax;
  for (int d = 0; d < ndof; ++d) {
    const int fr = free_of_dof[static_cast<std::size_t>(d)];
    if (fr < 0 || touched[static_cast<std::size_t>(fr)]) continue;
    if (std::fabs(rhs_full[static_cast<std::size_t>(d)]) > load_tol) {
      if (info) { info->converged = false; info->iterations = 0; info->residual = 0.0; }
      throw std::runtime_error(
          std::string(who) +
          ": under-constrained system (load applied to a void DOF with no "
          "stiffness — no equilibrium possible)");
    }
  }

  // Surviving free-DOF numbering + reduced RHS + Jacobi inverse diagonal.
  m.kept_global.clear();
  m.kept_global.reserve(static_cast<std::size_t>(nf));
  for (int d = 0; d < ndof; ++d) {
    const int fr = free_of_dof[static_cast<std::size_t>(d)];
    if (fr < 0 || !touched[static_cast<std::size_t>(fr)]) continue;
    m.kept_global.push_back(d);
  }
  m.ng = static_cast<int>(m.kept_global.size());
  m.rg.assign(static_cast<std::size_t>(m.ng), 0.0);
  m.invdiag.assign(static_cast<std::size_t>(m.ng), 0.0);
  for (int k = 0; k < m.ng; ++k) {
    const int d = m.kept_global[static_cast<std::size_t>(k)];
    m.rg[static_cast<std::size_t>(k)] = rhs_full[static_cast<std::size_t>(d)];
    m.invdiag[static_cast<std::size_t>(k)] =
        1.0 / diagfull[static_cast<std::size_t>(d)];
  }
  return m;
}

// Jacobi-preconditioned CG on the reduced system, replicating Eigen's
// ConjugateGradient<..., DiagonalPreconditioner> algorithm and convergence
// criterion (relative residual sqrt(||r||^2/||rhs||^2) <= tolerance) so the
// matrix-free solve converges to the same field. `x` is seeded (warm start or
// zero) and holds the solution on the kept DOFs.
void mf_cg_solve(const MatfreeReduced& m, double tolerance, int max_iterations,
                 std::vector<double>& x, int& iters_out, double& error_out,
                 bool& converged_out, RecycleReport* rec) {
  const int n = m.ng;
  const double tol = tolerance;
  const int maxIters = (max_iterations > 0) ? max_iterations : 2 * n;

  auto dot = [n](const std::vector<double>& a, const std::vector<double>& b) {
    double s = 0.0;
    for (int i = 0; i < n; ++i)
      s += a[static_cast<std::size_t>(i)] * b[static_cast<std::size_t>(i)];
    return s;
  };

  double rhsNorm2 = dot(m.rg, m.rg);
  if (rhsNorm2 == 0.0) {
    std::fill(x.begin(), x.end(), 0.0);
    iters_out = 0;
    error_out = 0.0;
    converged_out = true;
    return;
  }
  const double considerAsZero = std::numeric_limits<double>::min();
  double threshold = tol * tol * rhsNorm2;
  if (threshold < considerAsZero) threshold = considerAsZero;

  // Krylov recycling (handoff 133): the SPD additive coarse correction wrapping
  // the Jacobi preconditioner. Inert (and allocation-free) when recycling is off.
  RecycleSession recycle(n, m.invdiag.data(),
                         [&m](const double* xin, double* yout) {
                           m.apply_kgg_raw(xin, yout);
                         });
  if (rec != nullptr) {
    rec->dim = recycle.dim();
    rec->setup_matvecs += recycle.setup_matvecs();
  }

  std::vector<double> residual(static_cast<std::size_t>(n));
  std::vector<double> tmp(static_cast<std::size_t>(n));
  m.apply_kgg(x, tmp);  // tmp = K x (x is the guess)
  for (int i = 0; i < n; ++i)
    residual[static_cast<std::size_t>(i)] =
        m.rg[static_cast<std::size_t>(i)] - tmp[static_cast<std::size_t>(i)];

  double residualNorm2 = dot(residual, residual);
  if (residualNorm2 < threshold) {
    iters_out = 0;
    error_out = std::sqrt(residualNorm2 / rhsNorm2);
    converged_out = (error_out <= tol);
    return;
  }

  std::vector<double> p(static_cast<std::size_t>(n));
  std::vector<double> z(static_cast<std::size_t>(n));
  for (int i = 0; i < n; ++i)  // p = M^-1 residual
    p[static_cast<std::size_t>(i)] =
        m.invdiag[static_cast<std::size_t>(i)] * residual[static_cast<std::size_t>(i)];
  recycle.augment(residual.data(), p.data());  // + U E^-1 U^T residual
  double absNew = dot(residual, p);

  int i = 0;
  while (i < maxIters) {
    m.apply_kgg(p, tmp);  // tmp = K p
    // Hand CG's own direction and its ALREADY-computed operator image to the
    // recycler's decimating sample. No extra matvec; no-op off a harvest solve.
    recycle.observe(i, p.data(), tmp.data());
    const double alpha = absNew / dot(p, tmp);
    for (int q = 0; q < n; ++q) {
      x[static_cast<std::size_t>(q)] += alpha * p[static_cast<std::size_t>(q)];
      residual[static_cast<std::size_t>(q)] -= alpha * tmp[static_cast<std::size_t>(q)];
    }
    residualNorm2 = dot(residual, residual);
    if (residualNorm2 < threshold) break;
    for (int q = 0; q < n; ++q)
      z[static_cast<std::size_t>(q)] =
          m.invdiag[static_cast<std::size_t>(q)] * residual[static_cast<std::size_t>(q)];
    recycle.augment(residual.data(), z.data());  // + U E^-1 U^T residual
    const double absOld = absNew;
    absNew = dot(residual, z);
    const double beta = absNew / absOld;
    for (int q = 0; q < n; ++q)
      p[static_cast<std::size_t>(q)] =
          z[static_cast<std::size_t>(q)] + beta * p[static_cast<std::size_t>(q)];
    ++i;
  }
  error_out = std::sqrt(residualNorm2 / rhsNorm2);
  iters_out = i;
  bool finite = true;
  for (int q = 0; q < n; ++q)
    if (!std::isfinite(x[static_cast<std::size_t>(q)])) { finite = false; break; }
  converged_out = (error_out <= tol) && finite;
  // Rebuild the carried basis ONLY from a solve that actually reached tolerance:
  // a stagnated or broken-down solve's directions are not evidence about the
  // operator's slow modes.
  if (converged_out) recycle.commit();
}

}  // namespace fea_detail

namespace {

using fea_detail::MatfreeReduced;
using fea_detail::MfElem;

std::vector<double> matfree_apply_impl(const VoxelGrid& grid,
                                       double youngs_modulus, double poisson,
                                       const std::vector<double>* elem_youngs,
                                       const std::vector<double>& u) {
  const int ndof = 3 * fea_node_count(grid);
  if (static_cast<int>(u.size()) != ndof)
    throw std::invalid_argument(
        "fea_matfree_apply: u size != 3*fea_node_count");
  // Uniform: Ke carries the modulus, factor == 1. Graded: Ke is the unit-modulus
  // element, factor == per-voxel E (hex8 stiffness is exactly linear in E). This
  // matches the assembled path's two element builds byte-for-byte.
  const Hex8Stiffness Ke = hex8_stiffness(
      elem_youngs != nullptr ? 1.0 : youngs_modulus, poisson, grid.spacing);
  std::vector<int> color_offsets;
  const std::vector<MfElem> elems = fea_detail::mf_build_elems(
      grid, elem_youngs, "fea_matfree_apply", &color_offsets);
  std::vector<double> y(static_cast<std::size_t>(ndof), 0.0);
  fea_detail::mf_apply_full(elems, color_offsets, Ke, u, y);
  return y;
}

FeaSolution solve_cg_matfree_impl(const VoxelGrid& grid, double youngs_modulus,
                                  double poisson,
                                  const std::vector<DirichletBC>& bcs,
                                  const std::vector<NodalLoad>& loads,
                                  double tolerance, int max_iterations,
                                  CgInfo* info,
                                  const std::vector<double>* elem_youngs,
                                  const FeaSolution* initial_guess,
                                  const std::vector<char>* active_mask) {
  MatfreeReduced m = fea_detail::mf_build_reduced(
      grid, youngs_modulus, poisson, bcs, loads, elem_youngs,
      "fea_solve_cg_matfree", info, active_mask);

  CgInfo diag;
  diag.converged = true;  // no free DOFs -> trivially converged

  std::vector<double> u = m.up;  // full field seeded with prescribed values
  if (m.ng > 0) {
    std::vector<double> x(static_cast<std::size_t>(m.ng), 0.0);
    if (initial_guess != nullptr &&
        static_cast<int>(initial_guess->u.size()) == m.ndof)
      for (int k = 0; k < m.ng; ++k)
        x[static_cast<std::size_t>(k)] = initial_guess->u[static_cast<std::size_t>(
            m.kept_global[static_cast<std::size_t>(k)])];

    fea_detail::RecycleReport rec;
    fea_detail::mf_cg_solve(m, tolerance, max_iterations, x, diag.iterations,
                            diag.residual, diag.converged, &rec);
    diag.recycle_dim = rec.dim;
    diag.recycle_setup_matvecs = rec.setup_matvecs;
    if (info) *info = diag;
    if (!diag.converged)
      throw std::runtime_error(
          "fea_solve_cg_matfree: CG did not reach the requested tolerance "
          "within max_iterations");
    for (int k = 0; k < m.ng; ++k)
      u[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(k)])] =
          x[static_cast<std::size_t>(k)];
  } else if (info) {
    *info = diag;
  }

  FeaSolution sol;
  sol.u = std::move(u);
  return sol;
}

}  // namespace

std::vector<double> fea_matfree_apply(const VoxelGrid& grid,
                                      double youngs_modulus, double poisson,
                                      const std::vector<double>& u) {
  return matfree_apply_impl(grid, youngs_modulus, poisson, nullptr, u);
}

std::vector<double> fea_matfree_apply(const VoxelGrid& grid,
                                      const std::vector<double>& youngs_per_voxel,
                                      double poisson,
                                      const std::vector<double>& u) {
  return matfree_apply_impl(grid, 1.0, poisson, &youngs_per_voxel, u);
}

std::size_t fea_matfree_operator_storage_doubles() {
  return static_cast<std::size_t>(Hex8Stiffness::kDof) * Hex8Stiffness::kDof;
}

int fea_set_matfree_threads(int n) { return fea_detail::mf_set_thread_count(n); }

bool fea_set_matfree_galerkin_block_cache(bool enable) {
  return fea_detail::mf_set_galerkin_block_cache(enable);
}

bool fea_set_matfree_mixed_precision(bool enable) {
  return fea_detail::mf_set_mixed_precision(enable);
}

// Handoff 133 — Krylov recycling / deflation. Opt-in, default OFF; see fea.hpp
// for the contract, the exactness argument and the determinism argument.
bool fea_set_krylov_recycling(bool enable) {
  return fea_detail::rc_set_enabled(enable);
}
bool fea_krylov_recycling_enabled() { return fea_detail::rc_enabled(); }
bool fea_set_krylov_recycle_wrap_multigrid(bool enable) {
  return fea_detail::rc_set_wrap_multigrid(enable);
}
bool fea_krylov_recycle_wrap_multigrid() {
  return fea_detail::rc_wrap_multigrid();
}
int fea_set_krylov_recycle_dim(int k) { return fea_detail::rc_set_dim(k); }
int fea_krylov_recycle_dim() { return fea_detail::rc_dim(); }
int fea_set_krylov_recycle_cycle(int c) { return fea_detail::rc_set_cycle(c); }
int fea_krylov_recycle_cycle() { return fea_detail::rc_cycle(); }
void fea_reset_krylov_recycle_space() { fea_detail::rc_reset_space(); }
bool fea_krylov_recycle_space_active() { return fea_detail::rc_space_active(); }
int fea_krylov_recycle_space_dim() { return fea_detail::rc_space_dim(); }
std::size_t fea_krylov_recycle_bytes() { return fea_detail::rc_space_bytes(); }

// Handoff 114 — read-only accessors for the run version record. Pure reads.
int fea_matfree_thread_count() { return fea_detail::mf_thread_count(); }
bool fea_matfree_galerkin_block_cache_enabled() {
  return fea_detail::mf_galerkin_block_cache_enabled();
}
bool fea_matfree_mixed_precision_enabled() {
  return fea_detail::mf_mixed_precision_enabled();
}

FeaSolution fea_solve_cg_matfree(const VoxelGrid& grid, double youngs_modulus,
                                 double poisson,
                                 const std::vector<DirichletBC>& bcs,
                                 const std::vector<NodalLoad>& loads,
                                 double tolerance, int max_iterations,
                                 CgInfo* info) {
  return solve_cg_matfree_impl(grid, youngs_modulus, poisson, bcs, loads,
                               tolerance, max_iterations, info, nullptr, nullptr,
                               nullptr);
}

FeaSolution fea_solve_cg_matfree(const VoxelGrid& grid,
                                 const std::vector<double>& youngs_per_voxel,
                                 double poisson,
                                 const std::vector<DirichletBC>& bcs,
                                 const std::vector<NodalLoad>& loads,
                                 double tolerance, int max_iterations,
                                 CgInfo* info, const FeaSolution* initial_guess,
                                 const std::vector<char>* active_mask) {
  return solve_cg_matfree_impl(grid, 1.0, poisson, bcs, loads, tolerance,
                               max_iterations, info, &youngs_per_voxel,
                               initial_guess, active_mask);
}

}  // namespace topopt
