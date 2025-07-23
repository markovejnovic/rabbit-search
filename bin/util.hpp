#ifndef RBS_UTIL_HPP
#define RBS_UTIL_HPP

#include <utility>

namespace rbs {

template <class F>
class Defer {
 public:
  explicit constexpr Defer(F&& fxn) noexcept : func_(std::forward<F>(fxn)) {}
  ~Defer() { func_(); }

 private:
  F func_;
};

}  // namespace rbs

#endif  // RBS_UTIL_HPP
