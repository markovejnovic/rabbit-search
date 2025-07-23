#ifndef RBS_FS_NODE_HPP
#define RBS_FS_NODE_HPP

#include <dirent.h>

namespace rbs {

struct FsNode {
  dirent Entry;
  FsNode* Parent;
};

}  // namespace rbs

#endif  // RBS_FS_NODE_HPP
