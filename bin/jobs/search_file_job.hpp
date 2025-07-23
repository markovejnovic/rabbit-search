#ifndef RBS_SEARCH_FILE_JOB_HPP
#define RBS_SEARCH_FILE_JOB_HPP

#include "ijob.hpp"
#include "fs_node.hpp"
#include "log.hpp"
#include "result.hpp"
#include "util.hpp"
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include "stringzilla/stringzilla.hpp"

namespace rbs {

class SearchFileJob final : public IJob<SearchFileJob> {
private:
  static constexpr Logger kLogger{"SearchFileJob"};
public:
  explicit constexpr SearchFileJob(
    FsNode* fsNode,
    int fileDescriptor
  ) noexcept : fsNode_(fsNode), fd_(fileDescriptor) {}

  template <class Worker>
  constexpr void ServiceImpl(Worker& worker) noexcept {
    rbs::Defer cleanup { [this] { close(fd_); }};

    struct stat file_stat;
    if (fstat(fd_, &file_stat) == -1) {
      kLogger.Error(std::format("Failed to get file status: {}", std::strerror(errno)));
      return;
    }

    if (file_stat.st_size == 0) {
      return;
    }

    // TODO(marko): Is there value in adding MAP_NOCACHE?
    void* data = mmap(nullptr, file_stat.st_size, PROT_READ, MAP_PRIVATE, fd_, 0);
    if (data == MAP_FAILED) {
      kLogger.Error(std::format("Failed to map file into memory: {}", std::strerror(errno)));
      return;
    }

    rbs::Defer unmap { [data, file_stat] { munmap(data, file_stat.st_size); }};
    namespace sz = ashvardanian::stringzilla;

    const sz::string_view haystack(static_cast<const char*>(data), file_stat.st_size);
    const sz::string_view needle = Needle(worker);

    const bool found = haystack.find(needle) != sz::string_view::npos;

    if (found) {
      worker.PushResult(Result{fsNode_});
    }
  }

  template <class Worker>
  [[nodiscard]] constexpr auto Needle(const Worker& worker) -> std::string_view {
    // TODO(marko): yucky hack
    return worker.SearchString();
  }

private:
  FsNode* fsNode_;
  int fd_;
};

} // namespace rbs

#endif // RBS_SEARCH_FILE_JOB_HPP
