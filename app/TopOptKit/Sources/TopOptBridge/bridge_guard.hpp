// bridge_guard.hpp — bridge.cpp's ONE GUARD, lent to the Flexible bridge's pass-throughs (PR #362, angled
// presses AP2: "every pass-through guarded by bridge.cpp's one guard so a core throw becomes a value, never
// a crash").
//
// PRIVATE: this header is not in include/ (the module map names only TopOptBridge.hpp and FlexibleBridge.hpp),
// so Swift never sees it. bridge.cpp keeps the one `guarded` template in its own anonymous namespace; this is
// the single door through which another file's function runs its body under it — not a second guard.
#pragma once

#include <functional>
#include <string>

namespace topoptbridge {

// Runs `body` through bridge.cpp's `guarded` (maintainer, 2026-10-03: no core exception ever crosses the
// bridge). Returns "" when the body returned normally, else the reason (never empty): a std::exception's
// what(), or bridge.cpp's generic words for anything else. The reason also lands in bridge_last_refusal(),
// as for every guarded function, and a normal return clears it.
std::string bridge_guard_run(const char* where, const std::function<void()>& body) noexcept;

}  // namespace topoptbridge
