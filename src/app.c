#include "cli.h"
#include "job_q.h"
#include "log.h"
#include "pathops.h"
#include "pp.h"
#include "string_search.h"
#include "sys.h"
#include <dirent.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { DIRS_PER_DIR_START = 128 };

// TODO(mvejnovic): Temporary hack.
// NOLINTNEXTLINE
static char fs_err_msg_buf_g[PATH_MAX + 256];

typedef struct {
  enum {
    FS_ERR_OK,
    FS_ERR_IO_ERR,

    // TODO(markovejnovic): We shouldn't fault on systems that don't have
    //                      d_type support, but should rather call iostat.
    //                      See uses of this enum value.
    FS_ERR_UNSUPPORTED_FILESYSTEM,
  } err_code;
  const char *msg;
} fs_err;

/**
 * @brief Looks at a file and pushes it into the job queue if applicable.
 *
 * @param [in] file_path The path to the file. This function takes ownership
 *                       of the string. A corresponding free will be called.
 */
static fs_err enqueue_file(jobq job_queue, const char *file_path) {
  FILE *file = fopen(file_path, "r");

  if (unlikely(file == NULL)) {
    (void)snprintf(fs_err_msg_buf_g, sizeof(fs_err_msg_buf_g),
                   "Failed to open: %s.\n", file_path);
    return (fs_err){.err_code = FS_ERR_IO_ERR, .msg = fs_err_msg_buf_g};
  }

  // Query the file size and immediately rewind to start of file.
  // TODO(mvejnovic): It's possible that this is a tad slow.
  // I wonder if seeking to the end to query the file size so we can malloc
  // is a good idea, or whether it's better to have a greedy algorithm
  // that takes a massive malloc buffer.
  if (unlikely(fseek(file, 0L, SEEK_END) != 0)) {
    sys_panic(2, "Could not seek to the end of the file \"%s\".", file_path);
  }
  const size_t file_sz = ftell(file);
  if (unlikely(fseek(file, 0L, SEEK_SET) != 0)) {
    sys_panic(2, "Could not seek to the start of the file \"%s\".", file_path);
  }

  // TODO(mvejnovic): This algorithm obviously is limited by the file size.
  // A massive (more than available RAM) file will easily tear your system
  // to shreds.
  // I wonder if that can be remedied by treating said file, for the sake of
  // the job queue, as multiple files with the same name.
  char *data = malloc(file_sz);
  // No need to check if this passed. If it didn't let the program crash.

  // TODO(mvejnovic): Do we care if this fails to load anything?
  //                  Can't we treat that job as empty and let our search
  //                  workers figure it out?
  if (unlikely(fread(data, 1, file_sz, file) != file_sz)) {
    (void)snprintf(fs_err_msg_buf_g, sizeof(fs_err_msg_buf_g),
                   "Failed to read: %s.\n", file_path);
    if (unlikely(fclose(file) != 0)) {
      sys_panic(2, "Could not close \"%s\".", file_path);
    }
    return (fs_err){
        .err_code = FS_ERR_IO_ERR,
        .msg = fs_err_msg_buf_g,
    };
  }

  if (unlikely(fclose(file) != 0)) {
    sys_panic(2, "Could not close \"%s\".", file_path);
  }

  // We have now submitted the file and it is outside of our hands. A
  // searchrat thread will free it as required.
  jobq_submit(job_queue, process_file_job_new(data, file_sz, file_path));

  return (fs_err){.err_code = FS_ERR_OK, .msg = NULL};
}

static fs_err enqueue_directory(jobq job_queue, const char *dir_path) {
  size_t dirs_seen = 0;
  char *directories_in_dir =
      malloc((unsigned long)DIRS_PER_DIR_START * NAME_MAX);

  DIR *dir_p = opendir(dir_path);
  if (unlikely(!dir_p)) {
    (void)snprintf(fs_err_msg_buf_g, sizeof(fs_err_msg_buf_g),
                   "Failed to open: %s.\n", dir_path);
    return (fs_err){.err_code = FS_ERR_IO_ERR, .msg = fs_err_msg_buf_g};
  }

  struct dirent *dirent_p;
  while (likely((dirent_p = readdir(dir_p)) != NULL)) {
    switch (dirent_p->d_type) {
    case DT_REG: {
      // Regular file should be sent to the job queue.
      const char *f_path = path_mkcat(dir_path, dirent_p->d_name);
      LOG_DEBUG_FMT("enqueue_directory: %s is a directory.", f_path);
      const fs_err err = enqueue_file(job_queue, f_path);
      if (unlikely(err.err_code != FS_ERR_OK)) {
        closedir(dir_p);
        return err;
      }
      break;
    }
    case DT_DIR:
      // Directories should be pushed to the directories to traverse
      // in the next run.
      if (strcmp(dirent_p->d_name, ".") == 0 ||
          strcmp(dirent_p->d_name, "..") == 0) {
        break;
      }
      strncpy(&directories_in_dir[dirs_seen * NAME_MAX], dirent_p->d_name,
              NAME_MAX);
      dirs_seen++;
      break;
    case DT_UNKNOWN:
      (void)snprintf(fs_err_msg_buf_g, sizeof(fs_err_msg_buf_g),
                     "This filesystem requires a seek to get inode info. "
                     "Currently this filesystem is unsupported.");
      closedir(dir_p);
      return (fs_err){
          .err_code = FS_ERR_UNSUPPORTED_FILESYSTEM,
          .msg = fs_err_msg_buf_g,
      };

    case DT_LNK:
      // TODO(mvejnovic): Handle symbolic links.
      break;

    default:
      // TODO(mvejnovic): All other things are ignorable, I think.
      break;
    }
  }

  // Don't forget, we now need to call this function for each directory we
  // discovered.
  for (size_t i = 0; i < dirs_seen; i++) {
    const char *child_dir_name = &directories_in_dir[i * NAME_MAX];
    // TODO(mvejnovic): I can't help but wonder if we can avoid a
    // malloc/free here?
    char *nested_path = path_mkcat(dir_path, child_dir_name);
    enqueue_directory(job_queue, nested_path);
    free(nested_path);
  }

  return (fs_err){.err_code = FS_ERR_OK, .msg = NULL};
}

struct shared_state {
  jobq job_queue;
  const char *needle;
  _Atomic bool done_traversing;
};

void *read_process(void *arg) {
  LOG_DEBUG("read_process: Entering...");

  struct shared_state *shared_state = (struct shared_state *)arg;
  const jobq queue = shared_state->job_queue;
  const char *needle = shared_state->needle;

  LOG_DEBUG_FMT("read_process: Searching for \"%s\" in %p", needle, queue);

  while (true) {
    LOG_DEBUG("read_process: Retrieving from queue...");
    const process_file_job_t job = jobq_retrieve(queue);
    if (job == NULL) {
      if (atomic_load_explicit(&shared_state->done_traversing,
                               memory_order_acquire)) {
        break;
      }
      continue;
    }

    if (ssearch(job->file_data, job->file_sz, needle)) {
      printf("Found: %s\n", job->file_path);
    }
    process_file_job_delete(job);
  }

  return NULL;
}

int main(int argc, const char **argv) {
  const cli_t cli_args = cli_parse(argc, argv);

  if (cli_args.help) {
    cli_help(cli_args);
    return 0;
  }

  if (cli_args.search_directory == NULL) {
    (void)fprintf(stderr, "Invalid Arguments: No needle provided.\n");
    return 1;
  }

  // Create a job queue. We're gonna have a thread load data into the queue
  // and we're gonna have all other threads read from the queue.
  jobq master_job_queue = jobq_new();

  // Spawn threads which will read from the job queue and execute the job
  const size_t available_jobs =
      cli_args.jobs != -1 ? cli_args.jobs : sys_get_avail_cores();

  struct shared_state *shared_state = malloc(sizeof(struct shared_state));
  shared_state->job_queue = master_job_queue;
  shared_state->needle = cli_args.search_directory;
  shared_state->done_traversing = false;

  pthread_t threads[available_jobs];
  LOG_DEBUG_FMT("Starting %lu threads...", available_jobs);
  for (size_t i = 0; i < available_jobs; i++) {
    // TODO(mvejnovic): Maybe there's optimizations to be done with how we
    //                  schedule the new thread.
    if (pthread_create(&threads[i], NULL, read_process, shared_state) != 0) {
      perror("pthread_create(...) failed to start.");
    }
    LOG_DEBUG_FMT("Started thread %lu", i);
  }

  // Start queueing up jobs from the master thread.
  LOG_DEBUG_FMT("Queueing the directory \"%s\"", ".");
  const fs_err err = enqueue_directory(master_job_queue, ".");

  atomic_store_explicit(&shared_state->done_traversing, true,
                        memory_order_release);

  for (size_t i = 0; i < available_jobs; i++) {
    pthread_join(threads[i], NULL);
  }

  jobq_delete(master_job_queue);
  free(shared_state);

  if (err.err_code != FS_ERR_OK) {
    printf("Error: %s", err.msg);
    return 1;
  }

  return 0;
}
