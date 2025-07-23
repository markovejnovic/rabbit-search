#ifndef RBS_ALLOC_ARENA_HPP
#define RBS_ALLOC_ARENA_HPP

#include <atomic>
#include <new>
#include <type_traits>

namespace rbs::alloc {

template <class T>
class MPArena {
private:
  struct Node {
    T Data;
    Node* Previous;
  };

public:
  using value_type = T;
  using size_type = std::size_t;
  using difference_type = std::ptrdiff_t;

  MPArena() noexcept = default;

  MPArena(const MPArena&) = delete;
  MPArena(MPArena&&) = delete;
  auto operator=(const MPArena&) -> MPArena& = delete;
  auto operator=(MPArena&&) -> MPArena& = delete;

  template <class... Args>
  [[nodiscard]] constexpr auto New(Args&&... args) noexcept -> T* {
    static_assert(std::is_nothrow_constructible_v<T, Args&&...>,
                  "T must be nothrow constructible from Args...");

    Node* new_node = static_cast<Node*>(::operator new(sizeof(Node), std::nothrow));
    if (!new_node) {
      return nullptr;
    }

    new (new_node) Node{T(std::forward<Args>(args)...), nullptr};

    while (true) {
      new_node->Previous = tail_.load(std::memory_order_relaxed);
      if (tail_.compare_exchange_strong(new_node->Previous, new_node, std::memory_order_release,
                                        std::memory_order_relaxed)) {
        return &new_node->Data;
      }
    }
  }

  /// @note You must use std::atomic_thread_fence after invoking your constructor to ensure that
  ///       the memory is observed by other threads.
  [[nodiscard]] constexpr auto UnfencedAlloc() -> T* {
    static_assert(std::is_trivial_v<Node>,
                  "Node must be trivial to use UnfencedAlloc");

    Node* new_node = static_cast<Node*>(::operator new(sizeof(Node), std::nothrow));
    if (!new_node) {
      return nullptr;
    }

    while (true) {
      new_node->Previous = tail_.load(std::memory_order_relaxed);
      if (tail_.compare_exchange_strong(new_node->Previous, new_node, std::memory_order_relaxed,
                                        std::memory_order_relaxed)) {
        return &new_node->Data;
      }
    }

    return &new_node->Data;
  }

  ~MPArena() {
    Node* current = tail_.load(std::memory_order_acquire);
    while (current) {
      Node* to_delete = current;
      current = current->Previous;
      delete to_delete;
    }
  }

private:
  std::atomic<Node*> tail_ = nullptr;
};

} // namespace rbs::alloc

#endif // RBS_ALLOC_ARENA_HPP
