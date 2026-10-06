/* Offline worker pool: switch each thread to A100 before vector work. */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

#if K3NRX_WORKERS != 2 && K3NRX_WORKERS != 4
#error "A100 worker pool supports two or four workers"
#endif

static pthread_t workers[K3NRX_WORKERS];
static const int indices[4] = {0, 1, 2, 3};
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t request_cv = PTHREAD_COND_INITIALIZER;
static pthread_cond_t done_cv = PTHREAD_COND_INITIALIZER;
static void (*request_fn)(void *);
static void *request_args[4];
static unsigned generation;
static int created, ready, done, failed, stopping, pending;
static int active_mask, expected_done;

static void *worker_main(void *opaque) {
  const int index = *(const int *)opaque;
  int valid = 0;
  int fd = open("/proc/set_ai_thread", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    valid = write(fd, "0\n", 2) == 2;
    close(fd);
  }
  if (valid) {
    cpu_set_t selected;
    CPU_ZERO(&selected);
    CPU_SET(8 + index, &selected);
    valid = sched_setaffinity(0, sizeof(selected), &selected) == 0;
  }
  if (valid) {
    cpu_set_t allowed;
    valid = sched_getaffinity(0, sizeof(allowed), &allowed) == 0 &&
            CPU_ISSET(8 + index, &allowed) && !CPU_ISSET(0, &allowed);
  }
  if (valid)
    fprintf(stderr, "K3 A100 pool worker=%d cpu=%d\n", index, sched_getcpu());
  pthread_mutex_lock(&mutex);
  if (!valid) failed = 1;
  ++ready;
  pthread_cond_broadcast(&done_cv);
  unsigned seen = 0;
  while (valid && !stopping) {
    while (generation == seen && !stopping)
      pthread_cond_wait(&request_cv, &mutex);
    if (stopping) break;
    seen = generation;
    if (!(active_mask & (1 << index))) continue;
    void (*fn)(void *) = request_fn;
    void *arg = request_args[index];
    pthread_mutex_unlock(&mutex);
    fn(arg);
    pthread_mutex_lock(&mutex);
    ++done;
    pthread_cond_broadcast(&done_cv);
  }
  pthread_mutex_unlock(&mutex);
  return NULL;
}

int a100_worker_pool_start(void) {
  pthread_mutex_lock(&mutex);
  generation = 0;
  created = ready = done = failed = stopping = pending = 0;
  active_mask = expected_done = 0;
  pthread_mutex_unlock(&mutex);
  for (int i = 0; i < K3NRX_WORKERS; ++i) {
    if (pthread_create(&workers[i], NULL, worker_main, (void *)&indices[i])) {
      pthread_mutex_lock(&mutex);
      failed = 1;
      stopping = 1;
      pthread_cond_broadcast(&request_cv);
      pthread_mutex_unlock(&mutex);
      break;
    }
    ++created;
  }
  pthread_mutex_lock(&mutex);
  while (!failed && ready < K3NRX_WORKERS)
    pthread_cond_wait(&done_cv, &mutex);
  const int ok = !failed && ready == K3NRX_WORKERS;
  if (!ok) {
    stopping = 1;
    pthread_cond_broadcast(&request_cv);
  }
  pthread_mutex_unlock(&mutex);
  if (!ok) {
    for (int i = 0; i < created; ++i) pthread_join(workers[i], NULL);
    created = 0;
  }
  return ok ? 0 : -1;
}

int a100_worker_pool_call(void (*fn)(void *), void *const args[4],
                          unsigned mask) {
  pthread_mutex_lock(&mutex);
  if (ready != K3NRX_WORKERS || failed || stopping || pending ||
      !mask || mask >= (1u << K3NRX_WORKERS)) {
    pthread_mutex_unlock(&mutex);
    return -1;
  }
  request_fn = fn;
  for (int i = 0; i < K3NRX_WORKERS; ++i) request_args[i] = args[i];
  done = 0;
  pending = 1;
  active_mask = mask;
  expected_done = __builtin_popcount(mask);
  ++generation;
  pthread_cond_broadcast(&request_cv);
  while (done < expected_done) pthread_cond_wait(&done_cv, &mutex);
  pending = 0;
  pthread_mutex_unlock(&mutex);
  return 0;
}

void a100_worker_pool_stop(void) {
  pthread_mutex_lock(&mutex);
  stopping = 1;
  pthread_cond_broadcast(&request_cv);
  pthread_mutex_unlock(&mutex);
  for (int i = 0; i < created; ++i) pthread_join(workers[i], NULL);
  created = 0;
}
