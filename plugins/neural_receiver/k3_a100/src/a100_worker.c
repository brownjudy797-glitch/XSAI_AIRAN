/* Keep this translation unit scalar: switch HMP type before any vector code. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static pthread_t worker;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t request_cv = PTHREAD_COND_INITIALIZER;
static pthread_cond_t done_cv = PTHREAD_COND_INITIALIZER;
static void (*request_fn)(void *);
static void *request_arg;
static int ready;
static int pending;
static int done;
static int stopping;

static void *worker_main(void *unused) {
  (void)unused;
  int valid = 0;
  int fd = open("/proc/set_ai_thread", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    valid = write(fd, "0\n", 2) == 2;
    close(fd);
  }
  if (valid) {
    cpu_set_t selected;
    CPU_ZERO(&selected);
    CPU_SET(8, &selected);
    valid = sched_setaffinity(0, sizeof(selected), &selected) == 0;
  }
  if (valid) {
    cpu_set_t allowed;
    valid = sched_getaffinity(0, sizeof(allowed), &allowed) == 0 &&
            CPU_ISSET(8, &allowed) && !CPU_ISSET(0, &allowed);
  }
  pthread_mutex_lock(&mutex);
  ready = valid ? 1 : -1;
  pthread_cond_broadcast(&done_cv);
  while (!stopping && valid) {
    while (!pending && !stopping)
      pthread_cond_wait(&request_cv, &mutex);
    if (stopping) break;
    void (*fn)(void *) = request_fn;
    void *arg = request_arg;
    pending = 0;
    pthread_mutex_unlock(&mutex);
    fn(arg);
    pthread_mutex_lock(&mutex);
    done = 1;
    pthread_cond_broadcast(&done_cv);
  }
  pthread_mutex_unlock(&mutex);
  return NULL;
}

int a100_worker_start(void) {
  pthread_mutex_lock(&mutex);
  ready = pending = done = stopping = 0;
  pthread_mutex_unlock(&mutex);
  if (pthread_create(&worker, NULL, worker_main, NULL)) return -1;
  pthread_mutex_lock(&mutex);
  while (!ready) pthread_cond_wait(&done_cv, &mutex);
  int ok = ready > 0;
  pthread_mutex_unlock(&mutex);
  if (!ok) {
    pthread_join(worker, NULL);
    fprintf(stderr, "K3 A100 worker: HMP switch/CPU8 binding failed\n");
  }
  return ok ? 0 : -1;
}

int a100_worker_call(void (*fn)(void *), void *arg) {
  pthread_mutex_lock(&mutex);
  if (ready != 1 || stopping || pending) {
    pthread_mutex_unlock(&mutex);
    return -1;
  }
  request_fn = fn;
  request_arg = arg;
  done = 0;
  pending = 1;
  pthread_cond_signal(&request_cv);
  while (!done) pthread_cond_wait(&done_cv, &mutex);
  pthread_mutex_unlock(&mutex);
  return 0;
}

void a100_worker_stop(void) {
  pthread_mutex_lock(&mutex);
  if (ready != 1) {
    pthread_mutex_unlock(&mutex);
    return;
  }
  stopping = 1;
  pthread_cond_signal(&request_cv);
  pthread_mutex_unlock(&mutex);
  pthread_join(worker, NULL);
  pthread_mutex_lock(&mutex);
  ready = 0;
  pthread_mutex_unlock(&mutex);
}
