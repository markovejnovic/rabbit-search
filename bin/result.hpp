#ifndef RBS_RESULT_HPP
#define RBS_RESULT_HPP

#include <string_view>
#include "fs_node.hpp"

namespace rbs {

class Result {
 public:
  explicit Result(const FsNode* fsNode) : fsNode_(fsNode) {}

  [[nodiscard]] constexpr auto Name() -> std::string_view {
    return {fsNode_->Entry.d_name, fsNode_->Entry.d_namlen};
  }

 private:
  const FsNode* fsNode_;
};

}  // namespace rbs

#endif  // RBS_RESULT_HPP
