#ifndef RBS_JOBS_TRAVERSE_DIRECTORY_JOB_HPP
#define RBS_JOBS_TRAVERSE_DIRECTORY_JOB_HPP

#include <cerrno>
#include <exception>
#include <filesystem>
#include <format>
#include <system_error>
#include "ijob.hpp"
#include <dirent.h>
#include <cassert>
#include "fs_node.hpp"
#include "jobs/search_file_job.hpp"
#include "log.hpp"
#include <fcntl.h>

namespace rbs {


class TraverseDirectoryJob final : public IJob<TraverseDirectoryJob> {
  static constexpr Logger kLogger{"TraverseDirectoryJob"};

public:
  explicit constexpr TraverseDirectoryJob(FsNode* dir, DIR* dirHandle) noexcept
      : dir_(dir), dirHandle_(dirHandle) {}

  template <class Worker>
  constexpr void ServiceImpl(Worker& worker) noexcept {
    while (true) {
      // Note this implementation assumes that ServiceImpl is noexcept to close the fd at the end.
      // TODO(marko): Improve the following. Note that there is an off-by-one error here. We create
      // memory for the Directory object, but since readdir_r may fail, we never attempt to
      // deallocate it. It would be good if we reused that memory.
      FsNode* dir = worker.FsNodeArena()->UnfencedAlloc();
      if (dir == nullptr) {
        kLogger.Error("Failed to allocate memory for Directory object. This is a bug.");
        std::terminate();
      }
      dir->Parent = dir_;

      dirent* entry = nullptr;
      if (readdir_r(dirHandle_, &dir->Entry, &entry) != 0) {
        kLogger.Error(std::format("Failed to read directory entry: {}",
                                 std::strerror(errno)));
        break;
      }

      if (entry == nullptr) [[unlikely]] {
        if (dir_ != nullptr) {
          kLogger.Debug(std::format("No more entries in directory: {}",
                                   std::string_view(dir_->Entry.d_name, dir_->Entry.d_namlen)));
        } else {
          kLogger.Debug("No more entries in the root directory.");
        }

        break;
      }

      const std::string_view entry_name{dir->Entry.d_name, dir->Entry.d_namlen};
      if (entry_name == "." || entry_name == "..") {
        // Skip the current and parent directory entries
        continue;
      }

      switch (dir->Entry.d_type) {
        case DT_DIR: {
          // If the entry is a directory, we need to open it, and submit it open to the scheduler.
          const int dir_fd = openat(dirfd(dirHandle_), dir->Entry.d_name, O_RDONLY | O_DIRECTORY);
          if (dir_fd == -1) [[unlikely]] {
            // Failed to open directory, log the error.
            kLogger.Error(std::format("Failed to open directory {}: {}",
                                     entry_name, std::strerror(errno)));
            continue;
          }
          DIR* new_dir_handle = fdopendir(dir_fd);

          kLogger.Debug(std::format("Found directory: {}", entry_name));
          worker.GetScheduler()->Submit(TraverseDirectoryJob(dir, new_dir_handle));
          continue;
        }
        case DT_REG: {
          // We found a regular file that we can search in.
          const int file_fd = openat(dirfd(dirHandle_), dir->Entry.d_name, O_RDONLY);
          if (file_fd == -1) [[unlikely]] {
            // Failed to open file, log the error.
            kLogger.Error(std::format("Failed to open file {}: {}",
                                     entry_name, std::strerror(errno)));
            continue;
          }

          worker.GetScheduler()->Submit(SearchFileJob(dir, file_fd));
          continue;
        }
        default: {
          kLogger.Error(std::format("Unknown entry type encountered in directory traversal: {}",
                                   dir->Entry.d_type));
          continue;
        }
      }
    }

    closedir(dirHandle_);
  }

  [[nodiscard]] static constexpr auto FromPath(
    const std::filesystem::path& path
  ) -> TraverseDirectoryJob {
    DIR* dir_handle = opendir(path.c_str());
    if (dir_handle == nullptr) {
      throw std::system_error(errno, std::generic_category());
    }

    return TraverseDirectoryJob{nullptr, dir_handle};
  }

private:
  FsNode* dir_;
  DIR* dirHandle_;
};

} // namespace rbs

#endif // RBS_JOBS_TRAVERSE_DIRECTORY_JOB_HPP
