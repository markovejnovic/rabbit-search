#ifndef RBS_JOBS_MAYBE_JOB_HPP
#define RBS_JOBS_MAYBE_JOB_HPP

#include <dirent.h>
#include <cstdint>
#include <utility>
#include "search_file_job.hpp"
#include "traverse_directory_job.hpp"

namespace rbs {

namespace detail {

class NopJob final : public IJob<NopJob> {
public:
  constexpr NopJob() noexcept = default;
};

enum class JobType : std::uint8_t {
  kNone = 0,
  kSearchFile = 1,
  kTraverseDirectory = 2,
};

} // namespace detail

struct MaybeJob {
  [[nodiscard]] constexpr auto HasValue() const noexcept -> bool {
    return type_ != detail::JobType::kNone;
  }

  template <class Worker>
  constexpr void Service(Worker& worker) noexcept {
    switch (type_) {
      case detail::JobType::kNone:
        break;
      case detail::JobType::kSearchFile:
        payload_.searchFileJob_.Service(worker);
        break;
      case detail::JobType::kTraverseDirectory:
        payload_.traverseDirectoryJob_.Service(worker);
        break;
      default:
        std::unreachable();
    }
  }

  static constexpr auto None() noexcept -> MaybeJob {
    return MaybeJob{detail::NopJob()};
  }

  // NOLINTBEGIN(google-explicit-constructor)
  constexpr MaybeJob(TraverseDirectoryJob job) noexcept
      : type_(detail::JobType::kTraverseDirectory), payload_({.traverseDirectoryJob_ = job}) {}

  constexpr MaybeJob(SearchFileJob job) noexcept
      : type_(detail::JobType::kSearchFile), payload_({.searchFileJob_ = job}) {}
  // NOLINTEND(google-explicit-constructor)

private:
  explicit constexpr MaybeJob(detail::NopJob job) noexcept
      : type_(detail::JobType::kNone), payload_({.nopJob_ = job}) {}

  detail::JobType type_ = detail::JobType{};
  union {
    TraverseDirectoryJob traverseDirectoryJob_;
    SearchFileJob searchFileJob_;
    detail::NopJob nopJob_;
  } payload_;
};

} // namespace rbs

#endif // RBS_JOBS_MAYBE_JOB_HPP
