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

auto Main(std::span<char*> args) -> int {
  CliArgs cli_args{args};

  Scheduler scheduler{cli_args.Jobs(), cli_args.SearchString()};
  scheduler.Submit(TraverseDirectoryJob::FromPath(cli_args.SearchPath()));
  scheduler.Run();

  moodycamel::ConsumerToken consumer_token = scheduler.ResultToken();

  while (true) {
    if (!scheduler.IsBusy()) {
      break;
    }

    auto result = scheduler.GetResult(consumer_token);
    if (result.has_value()) {
      std::cout << "Found a result: " << result->Name() << '\n';
    }
  }

  // Don't forget to flush any remaining results.
  while (true) {
    auto result = scheduler.GetResult(consumer_token);
    if (!result.has_value()) {
      break;
    }
    std::cout << "Found a result: " << result->Name() << '\n';
  }

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
