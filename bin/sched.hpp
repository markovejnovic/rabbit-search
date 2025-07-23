#ifndef RBS_SCHED_HPP
#define RBS_SCHED_HPP

#include <array>
#include <cstdint>
#include <format>
#include <iostream>
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

  constexpr ~Scheduler() { WaitForAll(); }

  constexpr void WaitForAll() noexcept {
    for (auto& worker : workers_) {
      worker.join();
    }
  }

  constexpr void StopAll() {
    exit_signal_.store(true, std::memory_order_relaxed);
    WaitForAll();
  }

  constexpr void Run() {
    kLogger.Info(std::format("Starting scheduler with {} threads.", threadCount_));
    for (std::uint16_t i = 0; i < threadCount_; ++i) {
      isWorking_[i].store(true, std::memory_order_relaxed);
    }

    workers_.reserve(threadCount_);
    for (std::uint16_t i = 0; i < threadCount_; ++i) {
      workers_.emplace(workers_.begin() + i,
                       std::thread([](WorkerType&& worker) { worker.Run(); },
                                   WorkerType(this, moodycamel::ProducerToken(jobQueue_),
                                              moodycamel::ConsumerToken(jobQueue_),
                                              moodycamel::ProducerToken(resultQueue_),
                                              &fsNodeArena_, &isWorking_[i])));
    }
  }

  [[nodiscard]] constexpr auto IsBusy() const -> bool {
    return std::ranges::any_of(isWorking_, [](const std::atomic<bool>& working) {
      return working.load(std::memory_order_relaxed);
    });

    return false;
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
  std::vector<std::thread> workers_;

  // TODO(marko): Get rid of this array and pack it with the workers.
  // NOLINTNEXTLINE(readability-magic-numbers)
  std::array<std::atomic<bool>, 64> isWorking_;

  // Note that MaybeJob::None will never be emplaced in this queue.
  moodycamel::ConcurrentQueue<MaybeJob> jobQueue_;

  moodycamel::ConcurrentQueue<Result> resultQueue_;

  std::string_view searchString_;

  std::atomic<bool> exit_signal_{false};
};

template <class Scheduler>
constexpr void Worker<Scheduler>::Run() {
  std::uint16_t work_count = kWorkCountLeakyBucketInitialValue;

  while (true) {
    if (scheduler_->exit_signal_.load(std::memory_order_relaxed)) {
      break;
    }

    if (work_count == 0) {
      kLogger.Info(std::format("Worker {} is idle, quitting...", std::this_thread::get_id()));
      break;
    }

    auto maybe_job = GetJob();
    kLogger.Debug(
        std::format("Worker {} got job: {}", std::this_thread::get_id(), maybe_job.HasValue()));
    if (!maybe_job.HasValue()) {
      work_count--;
      continue;
    }

    maybe_job.Service(*this);
    work_count += kWorkCountLeakyBucketGain;
  }

  isWorking_->store(false, std::memory_order_relaxed);
}

template <class Scheduler>
constexpr auto Worker<Scheduler>::GetJob() noexcept -> MaybeJob {
  MaybeJob job = MaybeJob::None();
  scheduler_->jobQueue_.try_dequeue(consumerToken_, job);
  return job;
}

}  // namespace rbs

#endif  // RBS_SCHED_HPP
