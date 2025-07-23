#ifndef RBS_WORKER_HPP
#define RBS_WORKER_HPP

#include <atomic>
#include <limits>
#include "alloc/arena.hpp"
#include "concurrentqueue.h"
#include "jobs/traverse_directory_job.hpp"
#include "result.hpp"

namespace rbs {

template <class Scheduler>
class Worker {
 private:
  static constexpr std::uint16_t kWorkCountLeakyBucketInitialValue = 1024;
  static constexpr std::uint16_t kWorkCountLeakyBucketGain = 256;

  /// @brief This is the target number of file descriptors that we want to have open at any given
  /// time.
  static constexpr std::uint16_t kFilesOpenTarget = std::numeric_limits<std::uint16_t>::max() / 8;
  static constexpr std::uint16_t kMaxFilesOpen = std::numeric_limits<std::uint16_t>::max() / 2;

  static constexpr Logger kLogger{"Worker"};

 public:
  explicit constexpr Worker(Scheduler* scheduler,
                            moodycamel::ProducerToken&& directoryProducerToken,
                            moodycamel::ConsumerToken&& directoryConsumerToken,
                            moodycamel::ProducerToken&& fileSearchProducerToken,
                            moodycamel::ConsumerToken&& fileSearchConsumerToken,
                            moodycamel::ProducerToken&& resultProducerToken,
                            alloc::MPArena<FsNode>* directoryArena) noexcept
      : scheduler_(scheduler),
        directoryProducerToken_(std::move(directoryProducerToken)),
        directoryConsumerToken_(std::move(directoryConsumerToken)),
        fileSearchProducerToken_(std::move(fileSearchProducerToken)),
        fileSearchConsumerToken_(std::move(fileSearchConsumerToken)),
        resultProducerToken_(std::move(resultProducerToken)),
        fsNodeArena_(directoryArena) {}

  constexpr Worker(const Worker&) = delete;
  constexpr Worker(Worker&&) = default;
  constexpr auto operator=(const Worker&) -> Worker& = delete;
  constexpr auto operator=(Worker&&) -> Worker& = default;

  [[nodiscard]] constexpr auto Allocator() const noexcept { return scheduler_->allocator_; }

  [[nodiscard]] constexpr auto Allocator() noexcept { return scheduler_->allocator_; }

  [[nodiscard]] constexpr auto GetTraverseDirectoryJob() noexcept -> TraverseDirectoryJob;

  [[nodiscard]] constexpr auto GetSearchFileJob() noexcept -> SearchFileJob;

  [[nodiscard]] constexpr auto FsNodeArena() const noexcept -> const alloc::MPArena<FsNode>* {
    return fsNodeArena_;
  }

  [[nodiscard]] constexpr auto FsNodeArena() noexcept -> alloc::MPArena<FsNode>* {
    return fsNodeArena_;
  }

  [[nodiscard]] constexpr auto SearchString() const noexcept -> std::string_view {
    return scheduler_->searchString_;
  }

  [[nodiscard]] constexpr auto SearchString() noexcept -> std::string_view {
    return scheduler_->searchString_;
  }

  constexpr void PushResult(Result result) noexcept {
    scheduler_->resultQueue_.enqueue(resultProducerToken_, std::move(result));
  }

  [[nodiscard]] constexpr auto IsWorking() const noexcept -> bool {
    return scheduler_->DirectoriesCurrentlyOpen() > 0;
  }

  constexpr void FinishTraversingDirectory() noexcept {
    scheduler_->dirsOpen_.fetch_sub(1, std::memory_order_relaxed);
  }

  constexpr void OpenFile() noexcept {
    scheduler_->fdsOpen_.fetch_add(1, std::memory_order_relaxed);
  }

  [[nodiscard]] constexpr auto FilesOpen() const noexcept -> std::uint16_t {
    return scheduler_->fdsOpen_.load(std::memory_order_relaxed);
  }

  [[nodiscard]] constexpr auto FilesOpen() noexcept -> std::uint16_t {
    return scheduler_->fdsOpen_.load(std::memory_order_relaxed);
  }

  constexpr void FinishVisitingFile() noexcept {
    scheduler_->fdsOpen_.fetch_sub(1, std::memory_order_relaxed);
  }

  constexpr void Submit(TraverseDirectoryJob&& job) noexcept {
    scheduler_->Submit(std::move(job), directoryProducerToken_);
  }

  constexpr void Submit(SearchFileJob&& job) noexcept {
    scheduler_->Submit(std::move(job), fileSearchProducerToken_);
  }

  constexpr void Run();

  constexpr auto TryDoJob() noexcept -> bool;
  constexpr auto TryFileReadingJob() noexcept -> bool;
  constexpr auto TryDirectoryTraversalJob() noexcept -> bool;

 private:
  alloc::MPArena<FsNode>* fsNodeArena_;

  Scheduler* scheduler_;
  moodycamel::ProducerToken directoryProducerToken_;
  moodycamel::ConsumerToken directoryConsumerToken_;
  moodycamel::ProducerToken fileSearchProducerToken_;
  moodycamel::ConsumerToken fileSearchConsumerToken_;
  moodycamel::ProducerToken resultProducerToken_;
};

}  // namespace rbs

#endif  // RBS_WORKER_HPP
