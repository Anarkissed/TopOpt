#pragma once

#include <stdexcept>
#include <string>

namespace topopt {
namespace flexible {

// THE FLEXIBLE STAGE'S SQUISH MATHS (task 2026-09-28-flexible-squish-maths, step C1
// of docs/design/flexibles/07-roadmap.md). Every file under topopt/flexible/ is part
// of it. The reference is docs/design/flexibles/02-squish-model.md.
//
// Two kinds of "no":
//
//   * FlexibleError (thrown) — the INPUT is malformed: a data file that breaks its
//     schema, a pen curve whose x is not increasing, a stamp whose cells do not add
//     up to its force. The caller made a mistake; nothing was computed.
//
//   * Refusal (returned) — the input is fine but the DATA does not cover it: a
//     strain past what was measured, a density outside the table, a temperature
//     that was never tested (R7, R8, R10). This is an answer the user must SEE, so
//     it travels in the result with a stable code and a sentence, never as an
//     exception a caller might swallow.
class FlexibleError : public std::runtime_error {
 public:
  explicit FlexibleError(const std::string& msg) : std::runtime_error(msg) {}
};

// A refusal: `code` is stable and machine-readable (the app keys copy on it),
// `reason` is one plain sentence with the numbers in it. An empty code means "not
// refused".
struct Refusal {
  std::string code;
  std::string reason;
  bool refused() const { return !code.empty(); }
};

}  // namespace flexible
}  // namespace topopt
