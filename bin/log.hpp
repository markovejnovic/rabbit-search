#ifndef RBS_LOG_HPP
#define RBS_LOG_HPP

#include <iostream>
namespace rbs {

class Logger final {
 public:
  explicit constexpr Logger(const char* name) : name_(name) {}

  [[nodiscard]] constexpr auto Name() const noexcept -> const char* { return name_; }

  template <class StringT>
  constexpr void Error(const StringT& message) const noexcept {
    std::cerr << "[" << name_ << "] Error: " << message << '\n';
  }

  template <class StringT>
  constexpr void Info(const StringT& message) const noexcept {}

  template <class StringT>
  constexpr void Debug(const StringT& message) const noexcept {}

 private:
  const char* name_;
};

}  // namespace rbs

#endif  // RBS_LOG_HPP
