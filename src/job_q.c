#include "job_q.h"
#include "log.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

process_file_job_t process_file_job_new(const char *file_data,
                                              size_t file_sz,
                                              const char *file_path) {
  const process_file_job_t out = malloc(sizeof(struct process_file_job));
  out->file_data = file_data;
  out->file_sz = file_sz;
  out->file_path = file_path;

  return out;
}

typedef struct jobq_node jobq_node;

struct jobq_node {
  process_file_job_t data;
  jobq_node *_Atomic next;
};

void process_file_job_delete(const_process_file_job_t job) {
  free((char *)job->file_data);
  free((process_file_job_t)job);
}

struct jobq {
  jobq_node *_Atomic head;
#if RABBITSEARCH_METRICS_ENABLE
  // v- This does not need to be atomic since it is only ever supposed to be
  // incremented from one thread. In order to prevent future bugs, I will,
  // however, mark it _Atomic
  _Atomic size_t num_submitted;
#endif

  _Atomic ssize_t reserved_bytes;
};

jobq jobq_new(void) {
  jobq queue = malloc(sizeof(struct jobq));
  queue->head = NULL;
#if RABBITSEARCH_METRICS_ENABLE
  queue->num_submitted = 0;
#endif
  atomic_store(&queue->reserved_bytes, 0);
  return queue;
}

void jobq_delete(jobq queue) {
  if (queue != NULL) {
    free(queue);
  }
}

void jobq_submit(jobq queue, const_process_file_job_t job) {
  LOG_DEBUG_FMT("jobq_submit: %s", job->file_path);
  // TODO(mvejnovic): This being seq_cst is very slow.
  atomic_fetch_add_explicit(
    &queue->reserved_bytes,
    // TODO(mvejnovic) v- This cast is a bug waiting to happen.
    (ssize_t)job->file_sz,
    memory_order_seq_cst
  );
  jobq_node *new_node = malloc(sizeof(jobq_node));
  new_node->data = job;

  // TODO(mvejnovic): Data ordering.
  jobq_node *old_head = atomic_load(&queue->head);
  do {
    atomic_store(&new_node->next, old_head);
  } while (!atomic_compare_exchange_weak(&queue->head, &old_head, new_node));
#if RABBITSEARCH_METRICS_ENABLE
  atomic_fetch_add_explicit(&queue->num_submitted, 1, memory_order_relaxed);
#endif
}

process_file_job_t jobq_retrieve(jobq queue) {
  jobq_node *old_head = NULL;
  jobq_node *old_next = NULL;

  // Swap the head pointer to the new one.
  do {
    old_head = atomic_load(&queue->head);

    // TODO(mvejnovic): Audit this implementation. This feels, somehow...
    // "unatomic".
    if (old_head == NULL) {
      return NULL;
    }
    old_next = atomic_load(&old_head->next);
  } while (!atomic_compare_exchange_weak(&queue->head, &old_head, old_next));

  // Now, old_head is within the domain of the thread and is safe to use.
  if (old_head == NULL) {
    return NULL;
  }

  const process_file_job_t data_out = old_head->data;
  free(old_head);
  // TODO(mvejnovic): This being seq_cst is very slow.
  atomic_fetch_add_explicit(
    &queue->reserved_bytes,
    // TODO(mvejnovic) v- This cast is a bug waiting to happen.
    -(ssize_t)data_out->file_sz,
    memory_order_seq_cst
  );
  return data_out;
}

#if RABBITSEARCH_METRICS_ENABLE
size_t jobq_get_jobs_submitted_total(jobq queue) {
  return queue->num_submitted;
}
#endif

ssize_t jobq_get_bytes_in_use(jobq queue) {
  // TODO(mvejnovic): This being seq_cst is very slow.
  return atomic_load_explicit(&queue->reserved_bytes, memory_order_seq_cst);
}
