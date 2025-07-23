#ifndef RBS_RESULT_HPP
#define RBS_RESULT_HPP

#include <algorithm>
#include <cassert>
#include <span>
#include <string_view>
#include "fs_node.hpp"

namespace rbs {

class Result {
 public:
  explicit Result(const FsNode* fsNode) : fsNode_(fsNode) {}

  [[nodiscard]] constexpr auto Name() -> std::string_view {
    return {fsNode_->Entry.d_name, fsNode_->Entry.d_namlen};
  }

  [[nodiscard]] constexpr auto ComputePathStr(std::span<char> buf, char tailChar)
      -> std::string_view {
    // We need the size assertion here since we will unconditionally write to the buffer in some
    // cases.
    assert(buf.size() > 2);
    assert(fsNode_ != nullptr);

    const FsNode* current = fsNode_;

    char* string_ptr = &buf[buf.size() - 1];
#ifndef NDEBUG
    // This is useful for debugging as it lets our debugger correctly format the string.
    *string_ptr = '\0';
    const std::size_t buffer_length = buf.size() - 1;
#else
    const std::size_t buffer_length = buf.size();
#endif

    std::size_t length = 0;

    string_ptr -= 1;
    *string_ptr = tailChar;
    length += 1;

    while (current != nullptr) {
      const std::string_view current_name{current->Entry.d_name, current->Entry.d_namlen};

      // The +1 is for the separator addition.
      if (length + current_name.size() + 1 > buffer_length) [[unlikely]] {
        // TODO(marko): This could be handled better with std::expected.
        throw std::runtime_error("Buffer too small for path");
      }

      string_ptr -= current_name.size();
      length += current_name.size();
      std::ranges::copy(current_name, string_ptr);

      *(--string_ptr) = '/';
      ++length;

      current = current->Parent;
    }

    assert(buf.data() <= string_ptr && string_ptr + length <= buf.data() + buf.size());
    return {string_ptr, length};
  }

 private:
  const FsNode* fsNode_;
};

}  // namespace rbs

#endif  // RBS_RESULT_HPP
