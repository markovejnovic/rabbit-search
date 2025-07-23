#include <cstdio>
#include <format>
#include <iostream>
#include <span>
#include "cli.hpp"
#include "concurrentqueue.h"
#include "jobs/maybe_job.hpp"
#include "jobs/traverse_directory_job.hpp"
#include "sched.hpp"

namespace rbs {

namespace {

[[maybe_unused]] constexpr auto printResult(std::optional<Result>&& result,
                                            std::span<char> path_buf) -> bool {
  if (!result.has_value()) {
    return false;
  }

  const std::string_view path = result->ComputePathStr(path_buf, '\n');
  std::fwrite(path.data(), sizeof(char), path.size(), stdout);
  return true;
}

auto Main(std::span<char*> args) -> int {
  static constexpr std::size_t kMaxPath = 4096ULL * 4ULL;
  std::array<char, kMaxPath> path_buf;

  CliArgs cli_args{args};

  Scheduler scheduler{cli_args.Jobs(), cli_args.SearchString()};
  scheduler.Submit(TraverseDirectoryJob::FromPath(cli_args.SearchPath()));
  scheduler.Run();

  moodycamel::ConsumerToken consumer_token = scheduler.ResultToken();

  while (true) {
    if (!scheduler.IsBusy()) {
      break;
    }

    printResult(scheduler.GetResult(consumer_token), path_buf);
  }

  // Don't forget to flush any remaining results.
  while (printResult(scheduler.GetResult(consumer_token), path_buf)) {}

  return 0;
}

}  // namespace

}  // namespace rbs

auto main(int argc, char* argv[]) noexcept -> int {
  try {
    return rbs::Main(std::span<char*>{argv, static_cast<std::size_t>(argc)});
  } catch (const std::exception& ex) {
    std::cerr << std::format("An unhandled error has occurred: {}\n", ex.what());
  } catch (...) {
    std::cerr << "An unknown error has occurred.\n";
    return 1;
  }
}
