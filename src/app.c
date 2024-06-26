#define _GNU_SOURCE
#include "cli.h"
#include "filters.h"
#include "job_q.h"
#include "log.h"
#include "pathops.h"
#include "pp.h"
#include "string_search.h"
#include "sys.h"
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
// It is safe to ignore these errors as they refer to snprintf.
// NOLINTBEGIN(clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling)

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
  int file = open(file_path, O_RDONLY);

  if (unlikely(file < 0)) {
    (void)snprintf(fs_err_msg_buf_g, sizeof(fs_err_msg_buf_g), 
                   "Failed to open: %s.\n", file_path);
    return (fs_err){.err_code = FS_ERR_IO_ERR, .msg = fs_err_msg_buf_g};
  }

  // TODO(mvejnovic): Handle the TOCTOU problem. Steal it from ag

  // Query the file size and immediately rewind to start of file.
  struct stat file_stats; 
  if (unlikely(fstat(file, &file_stats))) {
    close(file);
    (void)snprintf(fs_err_msg_buf_g, sizeof(fs_err_msg_buf_g),
                   "Failed to stat: %s.\n", file_path);
    return (fs_err){
        .err_code = FS_ERR_IO_ERR,
        .msg = fs_err_msg_buf_g,
    };
  };

  // TODO(mvejnovic): This algorithm obviously is limited by the file size.
  // A massive (more than available RAM) file will easily tear your system
  // to shreds.
  // I wonder if that can be remedied by treating said file, for the sake of
  // the job queue, as multiple files with the same name.
  char *data = mmap(0, file_stats.st_size, PROT_READ, MAP_PRIVATE, file, 0);
  // TODO(markovejnovic): Exit on data == NULL
  madvise(data, file_stats.st_size, MADV_SEQUENTIAL);
  // No need to check if this passed. If it didn't let the program crash.

  if (unlikely(close(file) != 0)) {
    sys_panic(2, "Could not close \"%s\".", file_path); 
  }

  // We have now submitted the file and it is outside of our hands. A
  // searchrat thread will free it as required.
  jobq_submit(job_queue, process_file_job_new(data, file_stats.st_size, file_path));

  return (fs_err){.err_code = FS_ERR_OK, .msg = NULL};
}

static fs_err enqueue_directory(jobq job_queue, const char *dir_path) {
  DIR *dir_p = opendir(dir_path);

  if (unlikely(!dir_p)) {
    (void)snprintf(fs_err_msg_buf_g, sizeof(fs_err_msg_buf_g),
                     "Failed to open: %s.\n", dir_path);
    return (fs_err){.err_code = FS_ERR_IO_ERR, .msg = fs_err_msg_buf_g};
  }

  struct dirent *dirent_p = NULL;
  // TODO(markovejnovic): This only supports up to DIRS_PER_DIR_START
  // directories in a folder.
  char *directories_in_dir = malloc(
    (unsigned long)DIRS_PER_DIR_START * NAME_MAX);
  size_t dirs_seen = 0;

  // NOLINTBEGIN(concurrency-mt-unsafe)
  while (likely((dirent_p = readdir(dir_p)) != NULL)) {
  // NOLINTEND(concurrency-mt-unsafe)
    switch (dirent_p->d_type) {

    case DT_REG: {
      // Regular file should be sent to the job queue.
      const char *f_path = path_mkcat(dir_path, dirent_p->d_name);
      LOG_DEBUG_FMT("enqueue_directory: %s is a file.", f_path);
      const fs_err err = enqueue_file(job_queue, f_path);
      if (unlikely(err.err_code != FS_ERR_OK)) {
        closedir(dir_p);
        return err;
      }
      break;
    }

    case DT_DIR: {
#ifdef RABBITSEARCH_LOGS
      char *f_path = path_mkcat(dir_path, dirent_p->d_name);
      LOG_DEBUG_FMT("enqueue_directory: %s is a directory.", f_path);
      free(f_path);
#endif // RABBITSEARCH_LOGS
      // Directories should be pushed to the directories to traverse
      // in the next run.
      if (!filter_directory(dirent_p->d_name)) {
        break;
      }
      strncpy(&directories_in_dir[dirs_seen * NAME_MAX], dirent_p->d_name,
              NAME_MAX);
      dirs_seen++;
      break;
    }

    case DT_UNKNOWN: {
#ifdef RABBITSEARCH_LOGS
      char *f_path = path_mkcat(dir_path, dirent_p->d_name);
      LOG_DEBUG_FMT("enqueue_directory: %s is an unknown inode.", f_path);
      free(f_path);
#endif // RABBITSEARCH_LOGS
      (void)snprintf(fs_err_msg_buf_g, sizeof(fs_err_msg_buf_g),
                     "This filesystem requires a seek to get inode info. "
                     "Currently this filesystem is unsupported.");
      closedir(dir_p);
      return (fs_err){
          .err_code = FS_ERR_UNSUPPORTED_FILESYSTEM,
          .msg = fs_err_msg_buf_g,
      };
    }

    case DT_LNK: {
#ifdef RABBITSEARCH_LOGS
      char *f_path = path_mkcat(dir_path, dirent_p->d_name);
      LOG_DEBUG_FMT("enqueue_directory: %s is a symlink.", f_path);
      free(f_path);
#endif // RABBITSEARCH_LOGS
    }

    default:
      // TODO(mvejnovic): Handle symbolic links.
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

  free(directories_in_dir);

  closedir(dir_p);
  return (fs_err){.err_code = FS_ERR_OK, .msg = NULL};
}

struct shared_state {
  jobq job_queue;
  const char *needle;
  size_t needle_sz;
  _Atomic bool done_traversing;
};

void *read_process(void *arg) {
  LOG_DEBUG("read_process: Entering...");

  struct shared_state *shared_state = (struct shared_state *)arg;
  const jobq queue = shared_state->job_queue;
  const char *needle = shared_state->needle;
  const size_t needle_sz = shared_state->needle_sz;

  LOG_DEBUG_FMT("read_process: Searching for \"%s\" in q: %p", needle, queue);

  while (true) {
    const process_file_job_t job = jobq_retrieve(queue);
    if (job == NULL) {
      if (atomic_load_explicit(&shared_state->done_traversing,
                               memory_order_acquire)) {
        break;
      }
      continue;
    }

    LOG_DEBUG("read_process: Received work...");
    // TODO(markovejnovic): We should not be ignoring large files.
    if (job->file_sz < 100 * 1024
        && ssearch(job->file_data, job->file_sz, needle, needle_sz)) {
      printf("Found: %s\n", job->file_path);
    }
    process_file_job_delete(job);
  }

  return NULL;
}

int main(int argc, const char **argv) {
  const cli_t cli_args = cli_parse(argc, argv);

#ifdef HAVE_PLEDGE
  if (pledge("stdio rpath proc exec", NULL) == -1) {
      die("pledge: %s", strerror(errno));
  }
#endif

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
  shared_state->needle_sz = strlen(cli_args.search_directory);
  shared_state->done_traversing = false;

  pthread_t threads[available_jobs];
  LOG_DEBUG_FMT("Starting %lu threads...", available_jobs);
  for (size_t i = 0; i < available_jobs; i++) {
    // TODO(mvejnovic): Maybe there's optimizations to be done with how we
    //                  schedule the new thread.
    if (pthread_create(&threads[i], NULL, read_process, shared_state) != 0) {
      perror("pthread_create(...) failed to start.");
    }

    cpu_set_t cpu_set;
    CPU_ZERO(&cpu_set);
    CPU_SET(i % sys_get_avail_cores(), &cpu_set);

    if (pthread_setaffinity_np(threads[i], sizeof(cpu_set), &cpu_set)) {
      perror("pthread_setaffinity_np(...) failed to pin CPUs.");
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

// NOLINTEND(clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling)
