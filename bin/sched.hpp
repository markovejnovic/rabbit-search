#ifndef RBS_SCHED_HPP
#define RBS_SCHED_HPP

#include <pthread.h>
#include <sys/_pthread/_pthread_t.h>
#include <cstdint>
#include <new>
#include <ranges>
#include <thread>
#include <utility>
#include <vector>
#include "alloc/arena.hpp"
#include "concurrentqueue.h"
#include "fs_node.hpp"
#include "jobs/search_file_job.hpp"
#include "jobs/traverse_directory_job.hpp"
#include "result.hpp"
#include "worker.hpp"

namespace rbs {

template <class WorkerType>
constexpr auto workerThreadEntry(void* arg) -> void*;

template <class Allocator = std::allocator<std::byte>>
class Scheduler {
 private:
  static constexpr Logger kLogger{"Scheduler"};

  using WorkerType = Worker<Scheduler<Allocator>>;
  friend WorkerType;

 public:
  constexpr Scheduler(Allocator allocator, std::uint16_t threadCount,
                      std::string_view searchString) noexcept
      : allocator_(std::move(allocator)), threadCount_(threadCount), searchString_(searchString) {
    workers_.reserve(threadCount_);
  }

  explicit constexpr Scheduler(std::uint16_t threadCount, std::string_view searchString) noexcept
      : Scheduler(Allocator{}, threadCount, searchString) {}

  constexpr Scheduler(const Scheduler&) = delete;
  constexpr Scheduler(Scheduler&&) = delete;
  constexpr auto operator=(const Scheduler&) -> Scheduler& = delete;
  constexpr auto operator=(Scheduler&&) -> Scheduler& = delete;

  constexpr ~Scheduler() {
    WaitForAll();

    for (auto* worker : workerObjects_) {
      delete worker;
    }
  }

  constexpr void WaitForAll() noexcept {
    for (auto& worker : workers_) {
      const int err = pthread_join(worker, nullptr);
      if (err != 0) [[unlikely]] {
        std::cerr << "Failed to join worker thread: " << std::strerror(err) << '\n';
        std::terminate();
      }
    }
  }

  constexpr void StopAll() {
    exit_signal_.store(true, std::memory_order_relaxed);
    WaitForAll();
  }

  constexpr void Run() {
    workerObjects_.reserve(threadCount_);
    workers_.reserve(threadCount_);

    for (std::uint16_t i = 0; i < threadCount_; ++i) {
      auto* worker = new WorkerType(this, moodycamel::ProducerToken(traverseDirectoryQueue_),
                                    moodycamel::ConsumerToken(traverseDirectoryQueue_),
                                    moodycamel::ProducerToken(searchFileQueue_),
                                    moodycamel::ConsumerToken(searchFileQueue_),
                                    moodycamel::ProducerToken(resultQueue_), &fsNodeArena_);

      workerObjects_.emplace(workerObjects_.begin() + i, worker);
      workers_.emplace(workers_.begin() + i, pthread_t{});
      const int error_num = pthread_create(&workers_[i], nullptr, &workerThreadEntry<WorkerType>,
                                           static_cast<void*>(workerObjects_[i]));

      if (error_num != 0) [[unlikely]] {
        std::cerr << "Failed to create worker thread: " << std::strerror(errno) << '\n';
        std::terminate();
      }
    }
  }

  [[nodiscard]] constexpr auto IsBusy() const -> bool {
    auto working = std::views::transform(
        workerObjects_, [](const WorkerType* worker) { return worker->IsWorking(); });

    return std::ranges::any_of(working, [](bool is_working) { return is_working; });
  }

  constexpr void Submit(TraverseDirectoryJob&& job, moodycamel::ProducerToken& token) {
    dirsOpen_.fetch_add(1, std::memory_order_relaxed);
    const bool enqueue_result = traverseDirectoryQueue_.enqueue(token, job);
    assert(enqueue_result && "Failed to enqueue job. This is a bug.");
  }

  constexpr void SlowSubmit(TraverseDirectoryJob&& job) {
    dirsOpen_.fetch_add(1, std::memory_order_relaxed);
    const bool enqueue_result = traverseDirectoryQueue_.enqueue(job);
    assert(enqueue_result && "Failed to enqueue job. This is a bug.");
  }

  constexpr void Submit(SearchFileJob&& job, moodycamel::ProducerToken& token) {
    const bool enqueue_result = searchFileQueue_.enqueue(token, job);
    assert(enqueue_result && "Failed to enqueue job. This is a bug.");
  }

  [[nodiscard]] constexpr auto DirectoriesCurrentlyOpen() -> std::uint16_t {
    return dirsOpen_.load(std::memory_order_relaxed);
  }

  [[nodiscard]] constexpr auto ResultToken() noexcept -> moodycamel::ConsumerToken {
    return moodycamel::ConsumerToken(resultQueue_);
  }

  /// @todo(marko): Don't use std::optional
  [[nodiscard]] constexpr auto GetResult(moodycamel::ConsumerToken& token) noexcept
      -> std::optional<Result> {
    Result result{nullptr};
    if (!resultQueue_.try_dequeue(token, result)) {
      return std::nullopt;
    }

    return {result};
  }

 private:
  alloc::MPArena<FsNode> fsNodeArena_;

  Allocator allocator_;

  std::uint16_t threadCount_;
  // TODO(marko): Share allocator with this vector.
  std::vector<pthread_t> workers_;

  std::vector<WorkerType*> workerObjects_;

  moodycamel::ConcurrentQueue<TraverseDirectoryJob> traverseDirectoryQueue_;
  moodycamel::ConcurrentQueue<SearchFileJob> searchFileQueue_;

  moodycamel::ConcurrentQueue<Result> resultQueue_;

  std::string_view searchString_;

  std::atomic<bool> exit_signal_ alignas(std::hardware_destructive_interference_size){false};

  std::atomic<std::uint16_t> dirsOpen_ alignas(std::hardware_destructive_interference_size){0};

  std::atomic<std::uint16_t> fdsOpen_ alignas(std::hardware_destructive_interference_size){0};
};

template <class Scheduler>
constexpr auto Worker<Scheduler>::TryFileReadingJob() noexcept -> bool {
  SearchFileJob job = GetSearchFileJob();
  if (!job.Exists()) {
    return false;
  }

  job.Service(*this);
  return true;
}

template <class Scheduler>
constexpr auto Worker<Scheduler>::TryDirectoryTraversalJob() noexcept -> bool {
  TraverseDirectoryJob job = GetTraverseDirectoryJob();
  if (!job.Exists()) {
    return false;
  }

  job.Service(*this);
  return true;
}

template <class Scheduler>
constexpr auto Worker<Scheduler>::TryDoJob() noexcept -> bool {
  const std::uint16_t files_open = FilesOpen();
  if (files_open > kFilesOpenTarget) {
    // We have too many file descriptors open, let's service searching through files, rather than
    // open more files.
    if (!TryFileReadingJob()) {
      // There doesn't appear to be a job we can do right now.
      if (files_open < kMaxFilesOpen) {
        // However, we're not at the maximum number of files open, so we can still try to open a
        // couple.
        //
        // It's worse to be sitting idle.
        return TryDirectoryTraversalJob();
      }

      // We simply have too many files open, and the best we can do is pray some of them will
      // magically close.
      kLogger.Error(
          "We have too many files open, and we can't do anything about it right now. "
          "This is a bug in the scheduler.");
      return false;
    }

    // We managed to read the file just fine.
    return true;
  }

  // In the other case, we should go ahead and open some files.
  if (!TryDirectoryTraversalJob()) {
    // There were no jobs to traverse directories, let's avoid sitting idle.
    return TryFileReadingJob();
  }

  return false;
}

template <class Scheduler>
constexpr void Worker<Scheduler>::Run() {
  static constexpr std::uint32_t kSpinnerBackoff = 1;
  std::uint32_t spin_count = 0;

  while (true) {
    if (scheduler_->exit_signal_.load(std::memory_order_relaxed)) {
      // The user requested exit. Abort everything and get out. Don't even flush.
      break;
    }

    const std::uint16_t directories_currently_open = scheduler_->DirectoriesCurrentlyOpen();

    if (directories_currently_open == 0) {
      // If no directories are currently open, we need to flush the queue of jobs and exit.
      while (TryFileReadingJob()) {}
      break;
    }

    if (TryDoJob()) {
      spin_count = 0;
    } else {
      spin_count += kSpinnerBackoff;
      // Spin a tiny bit to back-off from the queues.
      for (std::size_t i = 0; i < spin_count; ++i) {
        __asm__ volatile("yield");
      }
    }
  }
}

template <class Scheduler>
constexpr auto Worker<Scheduler>::GetTraverseDirectoryJob() noexcept -> TraverseDirectoryJob {
  TraverseDirectoryJob job{nullptr, nullptr};
  scheduler_->traverseDirectoryQueue_.try_dequeue(directoryConsumerToken_, job);
  return job;
}

template <class Scheduler>
constexpr auto Worker<Scheduler>::GetSearchFileJob() noexcept -> SearchFileJob {
  SearchFileJob job{nullptr, 0};
  scheduler_->searchFileQueue_.try_dequeue(fileSearchConsumerToken_, job);
  return job;
}

template <>
constexpr auto workerThreadEntry<Worker<Scheduler<std::allocator<std::byte>>>>(void* arg) -> void* {
  auto* worker = static_cast<Worker<Scheduler<std::allocator<std::byte>>>*>(arg);
  worker->Run();
  return nullptr;
}

}  // namespace rbs

#endif  // RBS_SCHED_HPP
