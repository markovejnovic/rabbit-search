#ifndef RBS_WORKER_HPP
#define RBS_WORKER_HPP

#include "alloc/arena.hpp"
#include "concurrentqueue.h"
#include "jobs/maybe_job.hpp"
#include "jobs/traverse_directory_job.hpp"
#include "result.hpp"

namespace rbs {

template <class Scheduler>
class Worker {
 private:
  static constexpr std::uint16_t kWorkCountLeakyBucketInitialValue = 1024;
  static constexpr std::uint16_t kWorkCountLeakyBucketGain = 256;
  static constexpr Logger kLogger{"Worker"};

 public:
  explicit constexpr Worker(Scheduler* scheduler, moodycamel::ProducerToken producerToken,
                            moodycamel::ConsumerToken consumerToken,
                            moodycamel::ProducerToken resultProducerToken,
                            alloc::MPArena<FsNode>* directoryArena,
                            std::atomic<bool>* isWorking) noexcept
      : scheduler_(scheduler),
        producerToken_(std::move(producerToken)),
        consumerToken_(std::move(consumerToken)),
        resultProducerToken_(std::move(resultProducerToken)),
        isWorking_(isWorking),
        fsNodeArena_(directoryArena) {}

  constexpr Worker(const Worker&) = delete;
  constexpr Worker(Worker&&) = default;
  constexpr auto operator=(const Worker&) -> Worker& = delete;
  constexpr auto operator=(Worker&&) -> Worker& = default;

  [[nodiscard]] constexpr auto Allocator() const noexcept { return scheduler_->allocator_; }

  [[nodiscard]] constexpr auto Allocator() noexcept { return scheduler_->allocator_; }

  [[nodiscard]] constexpr auto GetScheduler() const noexcept -> Scheduler* { return scheduler_; }

  [[nodiscard]] constexpr auto GetScheduler() noexcept -> Scheduler* { return scheduler_; }

  [[nodiscard]] constexpr auto GetJob() noexcept -> MaybeJob;

  [[nodiscard]] constexpr auto FsNodeArena() const noexcept -> const alloc::MPArena<FsNode>* {
    return fsNodeArena_;
  }

  [[nodiscard]] constexpr auto FsNodeArena() noexcept -> alloc::MPArena<FsNode>* {
    return fsNodeArena_;
  }

  [[nodiscard]] constexpr auto ProducerToken() noexcept -> moodycamel::ProducerToken& {
    return producerToken_;
  }

  [[nodiscard]] constexpr auto ConsumerToken() noexcept -> moodycamel::ConsumerToken& {
    return consumerToken_;
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

  constexpr void Run();

 private:
  alloc::MPArena<FsNode>* fsNodeArena_;

  Scheduler* scheduler_;
  moodycamel::ProducerToken producerToken_;
  moodycamel::ConsumerToken consumerToken_;
  moodycamel::ProducerToken resultProducerToken_;

  std::atomic<bool>* isWorking_;
};

}  // namespace rbs

#endif  // RBS_WORKER_HPP
