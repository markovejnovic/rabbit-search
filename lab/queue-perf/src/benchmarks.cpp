#include "SPSCQueue.hpp"
#include <algorithm>
#include <benchmark/benchmark.h>
#include <atomic>
#include <cstdio>
#include <iterator>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>
#include <cstddef>
#include <mutex>

class SPMCQueue0 {
public:
    explicit SPMCQueue0(size_t capacity)
        : capacity_(capacity), buffer_(capacity) {}

    // Producer function to enqueue an item
    bool enqueue(const char* item) {
        std::lock_guard<std::mutex> lock { mutex_ };
        buffer_.push_back(item);
        return true;
    }

    // Consumer function to dequeue an item
    bool dequeue(const char*& item) {
        std::lock_guard<std::mutex> lock { mutex_ };
        if (buffer_.size() == 0) {
            return false;
        }

        item = buffer_[buffer_.size() - 1];
        buffer_.pop_back();
        return true;
    }

private:
    const size_t capacity_;
    std::vector<const char*> buffer_;
    std::mutex mutex_;
};

template <size_t NumQueues>
class SPMCQueue1 {
public:
    struct ConsumerHandle {
        size_t Id;
    };

    explicit SPMCQueue1(size_t capacity) {
        for (size_t i = 0; i < NumQueues; i++) {
            new (&GetQueues()[i]) rigtorp::SPSCQueue<const char*>(capacity);
        }
    }

    ConsumerHandle GetHandle() {
        return ConsumerHandle {
            HandleFactoryIdx.fetch_add(1, std::memory_order_relaxed)
        };
    }

    // Producer function to enqueue an item
    bool enqueue(const char* item) {
        auto& spsc = GetQueues()[(writeQueue_.fetch_add(1, std::memory_order_relaxed)) % NumQueues];
        return spsc.try_push(item);
    }

    // Consumer function to dequeue an item
    bool dequeue(ConsumerHandle handle, const char*& item) {
        const char** val = GetQueues()[handle.Id].front();
        if (val == nullptr) {
            return false;
        }

        GetQueues()[handle.Id].pop();
        item = *val;
        return true;
    }


private:
    using Store = std::aligned_storage<
        sizeof(rigtorp::SPSCQueue<const char*>) * NumQueues,
        alignof(rigtorp::SPSCQueue<const char*>)
    >::type;

    Store queues_[NumQueues];

    constexpr rigtorp::SPSCQueue<const char*>* GetQueues() {
        return reinterpret_cast<rigtorp::SPSCQueue<const char*>*>(&queues_[0]);
    }

    std::atomic<size_t> HandleFactoryIdx = 0;
    std::atomic<size_t> writeQueue_ = 0;
};

constexpr static const size_t QUEUE_CAPACITY = 1'000'000;
constexpr static const size_t NUM_THREADS = 16;
static std::atomic<bool> exit_flag = false;

static void BM_SPMCQueue0(benchmark::State& state) {
    exit_flag.store(false, std::memory_order_seq_cst);

    SPMCQueue0 queue(QUEUE_CAPACITY);

    std::vector<std::thread> threads;

    for (size_t i = 0; i < NUM_THREADS; i++) {
        threads.push_back(std::thread([&queue]() {
            while (!exit_flag.load(std::memory_order_relaxed)) {
                const char* item;
                bool result = queue.dequeue(item);
                benchmark::DoNotOptimize(result);
            }
        }));
    }

    bool result;
    for (auto _ : state) {
        for (size_t i = 0; i < QUEUE_CAPACITY; i++) {
            do { result = queue.enqueue(NULL); } while (!result);
            benchmark::DoNotOptimize(result);
        }
    }

    exit_flag.store(true, std::memory_order_seq_cst);
    for (auto& thread : threads) {
        thread.join();
    }
}
// Register the function as a benchmark
BENCHMARK(BM_SPMCQueue0);

static void BM_SPMCQueue1(benchmark::State& state) {
    exit_flag.store(false, std::memory_order_seq_cst);

    SPMCQueue1<NUM_THREADS> queue(QUEUE_CAPACITY);

    std::vector<std::thread> threads;

    for (size_t i = 0; i < NUM_THREADS; i++) {
        threads.push_back(std::thread([&queue]() {
            auto handle = queue.GetHandle();

            while (!exit_flag.load(std::memory_order_relaxed)) {
                const char* item;
                bool result = queue.dequeue(handle, item);
                benchmark::DoNotOptimize(result);
            }
        }));
    }

    bool result = true;
    for (auto _ : state) {
        for (size_t i = 0; i < QUEUE_CAPACITY; i++) {
            do { result = queue.enqueue(NULL); } while (!result);
            benchmark::DoNotOptimize(result);
        }
    }

    exit_flag.store(true, std::memory_order_seq_cst);
    for (auto& thread : threads) {
        thread.join();
    }
}
// Register the function as a benchmark
BENCHMARK(BM_SPMCQueue1);

// Run the benchmark
BENCHMARK_MAIN();
