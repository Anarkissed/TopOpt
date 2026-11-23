// on_every_core — internal to the lattice layout (his 11-23 iPad notes: "the Finishing stayed on for the majority of the
// time"): `fn(probe, k)` for every k below `n`, on every core, each thread with its own probe of the domain (a probe keeps
// its own caches; the domain is only read). Each k must write only its own slot, so the order they run in changes nothing.
// An exception in any thread (a stopped lay) stops the rest and is thrown again on the caller's thread.
#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <exception>
#include <mutex>
#include <thread>
#include <vector>

#include "topopt/lattice_layout.hpp"

namespace topopt::lattice_layout {

template <class Fn>
void on_every_core(const Domain& domain, std::size_t n, Fn&& fn) {
  const unsigned hw = std::max(1u, std::thread::hardware_concurrency());
  const unsigned nt = static_cast<unsigned>(std::min<std::size_t>(hw, std::max<std::size_t>(1, n / 32)));
  std::atomic<std::size_t> next{0};
  std::exception_ptr failed;
  std::mutex failed_mu;
  auto work = [&] {
    try {
      const Domain::Probe pr = domain.probe();
      for (std::size_t k = next.fetch_add(1); k < n; k = next.fetch_add(1)) fn(pr, k);
    } catch (...) {
      std::lock_guard<std::mutex> g(failed_mu);
      if (!failed) failed = std::current_exception();
      next.store(n);
    }
  };
  if (nt <= 1) {
    work();
  } else {
    std::vector<std::thread> pool;
    for (unsigned t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& th : pool) th.join();
  }
  if (failed) std::rethrow_exception(failed);
}

}  // namespace topopt::lattice_layout
