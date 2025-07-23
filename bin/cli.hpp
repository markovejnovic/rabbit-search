#ifndef CLI_HPP
#define CLI_HPP

#include <charconv>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <span>
#include <thread>

namespace rbs {

class CliArgs {
 public:
  constexpr explicit CliArgs(std::span<char*> args) noexcept {
    if (args.size() < 3) {
      printHelp();
      std::exit(2);
    }

    searchPath_ = std::filesystem::path(args[1]);
    searchString_ = std::string_view(args[2]);

    for (auto arg_it = args.begin() + 3; arg_it != args.end(); ++arg_it) {
      std::string_view arg = (*arg_it);

      if (arg == "--help" || arg == "-h") {
        help_ = true;
        printHelp();
        std::exit(2);
      }

      if (arg == "--verbose" || arg == "-v") {
        verbose_ = true;
        continue;
      }

      if (arg == "--jobs" || arg == "-j") {
        if (++arg_it == args.end()) {
          std::cerr << "Error: Missing value for --jobs option.\n";
          std::exit(2);
        }

        char* jobs_str = *arg_it;

        auto [ptr, ec] = std::from_chars(jobs_str, jobs_str + std::strlen(jobs_str), jobs_);

        if (ec != std::errc{}) {
          std::cerr << "Error: Invalid value for --jobs option: " << jobs_str << "\n";
          std::exit(2);
        }

        continue;
      }

      std::cerr << "Error: Unknown option '" << arg << "'. Use --help for usage information.\n";
      std::exit(2);
    }
  }

  [[nodiscard]] constexpr auto SearchPath() const noexcept -> const std::filesystem::path& {
    return searchPath_;
  }

  [[nodiscard]] constexpr auto SearchString() const noexcept -> std::string_view {
    return searchString_;
  }

  [[nodiscard]] constexpr auto Verbose() const noexcept -> bool { return verbose_; }

  [[nodiscard]] constexpr auto Jobs() const noexcept -> std::uint16_t { return jobs_; }

 private:
  static constexpr auto defaultJobs() -> std::uint16_t {
    return std::thread::hardware_concurrency() * 2;
  }

  static constexpr void printHelp() {
    std::cout << "Usage: rbs <PATH> <SEARCH_STRING> [OPTIONS]\n"
              << "Options:\n"
              << "  -h, --help          Show this help message and exit\n"
              << "  -v, --verbose       Enable verbose output\n"
              << "  -j, --jobs <N>      Number of parallel jobs to run (default: " << defaultJobs()
              << ")\n";
  }

  std::filesystem::path searchPath_;
  std::string_view searchString_;
  bool verbose_ = false;
  bool help_ = false;
  std::uint16_t jobs_ = defaultJobs();
};

}  // namespace rbs

#endif  // CLI_HPP
