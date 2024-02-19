#ifndef JOB_Q_H
#define JOB_Q_H

#include <stddef.h>

/**
 * Represents a request to search for a string through a file.
 */
struct process_file_job {
    const char* file_data;
    size_t file_sz;
    const char* file_path;
};

typedef struct process_file_job* process_file_job_t;
typedef struct jobq* jobq;

const process_file_job_t process_file_job_new(
    const char* file_data,
    size_t file_sz,
    const char* file_path
);

void process_file_job_delete(const process_file_job_t);

/**
 * @brief Create a new job queue.
 */
jobq jobq_new(void);

/**
 * @brief Add a new task to the job.
 */
void jobq_submit(jobq, const process_file_job_t);

/**
 * @brief Retrieves data from the job queue.
 */
const process_file_job_t jobq_retrieve(jobq);

/**
 * @brief Free the jobq memory.
 */
void jobq_delete(jobq);

#endif // JOB_Q_H