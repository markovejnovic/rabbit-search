#ifndef JOB_Q_H
#define JOB_Q_H

#include "rs_features.h"
#include <stddef.h>
#include <sys/types.h>

/**
 * Represents a request to search for a string through a file.
 */
struct process_file_job {
  const char *file_data;
  size_t file_sz;
  const char *file_path;
};

typedef struct process_file_job *process_file_job_t;
typedef struct process_file_job *const const_process_file_job_t;
typedef struct jobq *jobq;

/**
 * @brief Creates a new process request.
 *
 * This function takes ownership of all the memory passed into it.
 */
process_file_job_t process_file_job_new(const char *file_data,
                                        size_t file_sz,
                                        const char *file_path);

void process_file_job_delete(const_process_file_job_t job);

/**
 * @brief Create a new job queue.
 */
jobq jobq_new(void);

/**
 * @brief Add a new task to the job.
 *
 * @warning This function is NOT safe to call from multiple threads. One thread
 *          must be, contractually, the pushing thread.
 */
void jobq_submit(jobq queue, const_process_file_job_t job);

/**
 * @brief Retrieves data from the job queue.
 */
process_file_job_t jobq_retrieve(jobq queue);

/**
 * @brief Free the jobq memory.
 */
void jobq_delete(jobq queue);

#if RABBITSEARCH_METRICS_ENABLE
size_t jobq_get_jobs_submitted_total(jobq queue);
#endif

/**
 * @warning This is an approximation. Due to thread ordering, this might not
 *          fire as expected.
 */
ssize_t jobq_get_bytes_in_use(jobq queue);

#endif // JOB_Q_H
