#ifndef RBS_JOBS_CONCEPT_HPP
#define RBS_JOBS_CONCEPT_HPP

namespace rbs {

template <class Child>
class IJob {
public:
  template <class Worker>
  void Service(Worker& worker) noexcept {
    static_cast<Child*>(this)->ServiceImpl(worker);
  }

private:
  IJob() = default;
  friend Child;
};

} // namespace rbs

#endif // RBS_JOBS_CONCEPT_HPP
