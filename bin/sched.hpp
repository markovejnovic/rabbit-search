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
#include "jobs/maybe_job.hpp"
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
      auto job_prod = moodycamel::ProducerToken(jobQueue_);
      auto job_cons = moodycamel::ConsumerToken(jobQueue_);
      auto result_prod = moodycamel::ProducerToken(resultQueue_);

      workerObjects_.emplace(workerObjects_.begin() + i,
                             new WorkerType(this, std::move(job_prod), std::move(job_cons),
                                            std::move(result_prod), &fsNodeArena_));
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

  constexpr void Submit(TraverseDirectoryJob&& job) {
    dirsOpen_.fetch_add(1, std::memory_order_relaxed);
    const bool enqueue_result = jobQueue_.enqueue(MaybeJob(job));
    assert(enqueue_result && "Failed to enqueue job. This is a bug.");
  }

  [[nodiscard]] constexpr auto DirectoriesCurrentlyOpen() -> std::uint16_t {
    return dirsOpen_.load(std::memory_order_relaxed);
  }

  constexpr void Submit(MaybeJob&& job) {
    assert(job.HasValue());
    const bool enqueue_result = jobQueue_.enqueue(job);
    assert(enqueue_result && "Failed to enqueue job. This is a bug.");
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

  // Note that MaybeJob::None will never be emplaced in this queue.
  moodycamel::ConcurrentQueue<MaybeJob> jobQueue_;

  moodycamel::ConcurrentQueue<Result> resultQueue_;

  std::string_view searchString_;

  std::atomic<bool> exit_signal_ alignas(std::hardware_destructive_interference_size) {false};

  std::atomic<std::uint16_t> dirsOpen_ alignas(std::hardware_destructive_interference_size) { 0 };
};

template <class Scheduler>
constexpr void Worker<Scheduler>::Run() {
  while (true) {
    if (scheduler_->exit_signal_.load(std::memory_order_relaxed)) {
      break;
    }

    const std::uint16_t directories_currently_open = scheduler_->DirectoriesCurrentlyOpen();
    if (directories_currently_open == 0) {
      // If no directories are currently open, we need to flush the queue of jobs and exit.
      MaybeJob job = MaybeJob::None();
      while ((job = GetJob()).HasValue()) {
        job.Service(*this);
      }

      // After flushing out the queue, we can exit this thread.
      break;
    }

    MaybeJob job = GetJob();
    if (job.HasValue()) {
      job.Service(*this);
    }
  }
}

template <class Scheduler>
constexpr auto Worker<Scheduler>::GetJob() noexcept -> MaybeJob {
  MaybeJob job = MaybeJob::None();
  scheduler_->jobQueue_.try_dequeue(consumerToken_, job);
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
