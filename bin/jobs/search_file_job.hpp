#ifndef RBS_SEARCH_FILE_JOB_HPP
#define RBS_SEARCH_FILE_JOB_HPP

#include "fs_node.hpp"
#include "log.hpp"
#include "result.hpp"
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include "stringzilla/stringzilla.hpp"

namespace rbs {

class SearchFileJob final {
private:
  static constexpr Logger kLogger{"SearchFileJob"};

  template <class Worker>
  class FdCloser {
  public:
    explicit FdCloser(int fileDesc, Worker& worker) noexcept : fd_(fileDesc), worker_(&worker) {}

    ~FdCloser() noexcept {
      close(fd_);
      worker_->FinishVisitingFile();
    }

  private:
    int fd_;
    Worker* worker_;
  };

public:
  explicit constexpr SearchFileJob(
    FsNode* fsNode,
    int fileDescriptor
  ) noexcept : fsNode_(fsNode), fd_(fileDescriptor) {}

  template <class Worker>
  constexpr void Service(Worker& worker) noexcept {
    FdCloser closer{fd_, worker};

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

    namespace sz = ashvardanian::stringzilla;

    const sz::string_view haystack(static_cast<const char*>(data), file_stat.st_size);
    const sz::string_view needle = Needle(worker);

    const bool found = haystack.find(needle) != sz::string_view::npos;

    if (found) {
      worker.PushResult(Result{fsNode_});
    }

    munmap(data, file_stat.st_size);
  }

  template <class Worker>
  [[nodiscard]] constexpr auto Needle(const Worker& worker) -> std::string_view {
    // TODO(marko): yucky hack
    return worker.SearchString();
  }

  [[nodiscard]] constexpr auto Exists() const noexcept -> bool {
    return fsNode_ != nullptr;
  }

private:
  FsNode* fsNode_;
  int fd_;
};

} // namespace rbs

#endif // RBS_SEARCH_FILE_JOB_HPP
