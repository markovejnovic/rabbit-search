#include "job_q.h"
#include <stdlib.h>
#include <stdio.h>
#include <stdatomic.h>
#include "log.h"

const process_file_job_t process_file_job_new(
    const char* file_data,
    size_t file_sz,
    const char* file_path
) {
    const process_file_job_t out = malloc(sizeof(struct process_file_job));
}

typedef struct jobq_node jobq_node;

struct jobq_node {
    process_file_job_t data;
    jobq_node * _Atomic next;
};

void process_file_job_delete(const process_file_job_t job) {
    free((char*)job->file_data);
    free((process_file_job_t)job);
}

struct jobq {
    jobq_node * _Atomic head;
};

jobq jobq_new(void) {
    jobq q = malloc(sizeof(struct jobq));
    atomic_store(&q->head, NULL);
    return q;
}

void jobq_delete(jobq q) {
    if (q != NULL) {
        free(q);
    }
}

void jobq_submit(jobq q, const process_file_job_t job) {
    LOG_DEBUG_FMT("jobq_submit: %s", job->file_path);
    jobq_node* new_node = malloc(sizeof(jobq_node));
    new_node->data = job;

    // TODO(mvejnovic): Data ordering.
    jobq_node * _Atomic old_head = atomic_load(&q->head);
    do {
        atomic_store(&new_node->next, old_head);
    } while (!atomic_compare_exchange_weak(&q->head, &old_head, new_node));
}

const process_file_job_t jobq_retrieve(jobq q) {
    jobq_node * _Atomic old_head;
    jobq_node * _Atomic old_next;

    // Swap the head pointer to the new one.
    do {
        old_head = atomic_load(&q->head);

        // TODO(mvejnovic): Audit this implementation. This feels, somehow...
        // "unatomic".
        if (old_head == NULL) {
            return NULL;
        }
        old_next = atomic_load(&old_head->next);
    } while (!atomic_compare_exchange_weak(&q->head, &old_head, old_next));

    // Now, old_head is within the domain of the thread and is safe to use.
    if (old_head == NULL) {
        return NULL;
    }

    const process_file_job_t data_out = old_head->data;
    free(old_head);
    return data_out;
}