#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef enum {
  BACKEND_PTHREAD,
  BACKEND_MMAP,
} Backend;

typedef struct {
  pthread_mutex_t mutex;
  pthread_cond_t start_cond;
  pthread_cond_t done_cond;
  uint64_t epoch;
  size_t remaining;
  size_t elements;
  uint32_t compute_rounds;
  bool stop;
  size_t worker_count;
  uint32_t data[];
} SharedState;

typedef struct {
  SharedState *state;
  size_t id;
} WorkerArg;

typedef struct {
  Backend backend;
  SharedState *state;
  size_t mapping_size;
  size_t worker_count;
  pthread_t *threads;
  pid_t *pids;
  WorkerArg *args;
} Pool;

typedef struct {
  double min_us;
  double median_us;
  double p95_us;
  double max_us;
} Summary;

typedef struct {
  Summary timing;
  uint32_t checksum;
} ScenarioResult;

static void fail_code(const char *operation, int code) {
  fprintf(stderr, "%s failed: %s\n", operation, strerror(code));
  exit(1);
}

static void fail_errno(const char *operation) {
  fprintf(stderr, "%s failed: %s\n", operation, strerror(errno));
  exit(1);
}

static uint32_t mix_value(uint32_t value, uint32_t rounds) {
  for (uint32_t round = 0; round < rounds; round++) {
    value = value * UINT32_C(1664525) + UINT32_C(1013904223);
  }
  return value;
}

static void transform_range(
    uint32_t *data,
    size_t start,
    size_t end,
    uint32_t compute_rounds) {
  for (size_t index = start; index < end; index++) {
    data[index] = mix_value(data[index], compute_rounds);
  }
}

static void worker_loop(WorkerArg *arg) {
  SharedState *state = arg->state;
  uint64_t seen_epoch = 0;
  for (;;) {
    int code = pthread_mutex_lock(&state->mutex);
    if (code != 0) fail_code("pthread_mutex_lock", code);
    while (!state->stop && state->epoch == seen_epoch) {
      code = pthread_cond_wait(&state->start_cond, &state->mutex);
      if (code != 0) fail_code("pthread_cond_wait", code);
    }
    if (state->stop) {
      pthread_mutex_unlock(&state->mutex);
      return;
    }
    seen_epoch = state->epoch;
    const size_t elements = state->elements;
    const uint32_t compute_rounds = state->compute_rounds;
    const size_t start = elements * arg->id / state->worker_count;
    const size_t end = elements * (arg->id + 1) / state->worker_count;
    code = pthread_mutex_unlock(&state->mutex);
    if (code != 0) fail_code("pthread_mutex_unlock", code);

    transform_range(state->data, start, end, compute_rounds);

    code = pthread_mutex_lock(&state->mutex);
    if (code != 0) fail_code("pthread_mutex_lock", code);
    state->remaining--;
    if (state->remaining == 0) {
      code = pthread_cond_signal(&state->done_cond);
      if (code != 0) fail_code("pthread_cond_signal", code);
    }
    code = pthread_mutex_unlock(&state->mutex);
    if (code != 0) fail_code("pthread_mutex_unlock", code);
  }
}

static void *thread_entry(void *raw_arg) {
  worker_loop(raw_arg);
  return NULL;
}

static Pool pool_create(Backend backend, size_t worker_count, size_t max_elements) {
  Pool pool = {
      .backend = backend,
      .worker_count = worker_count,
  };
  pool.mapping_size = sizeof(SharedState) + max_elements * sizeof(uint32_t);
  int flags = MAP_ANONYMOUS | (backend == BACKEND_MMAP ? MAP_SHARED : MAP_PRIVATE);
  pool.state = mmap(NULL, pool.mapping_size, PROT_READ | PROT_WRITE, flags, -1, 0);
  if (pool.state == MAP_FAILED) fail_errno("mmap");

  pthread_mutexattr_t mutex_attr;
  pthread_condattr_t cond_attr;
  int code = pthread_mutexattr_init(&mutex_attr);
  if (code != 0) fail_code("pthread_mutexattr_init", code);
  code = pthread_condattr_init(&cond_attr);
  if (code != 0) fail_code("pthread_condattr_init", code);
  if (backend == BACKEND_MMAP) {
    code = pthread_mutexattr_setpshared(&mutex_attr, PTHREAD_PROCESS_SHARED);
    if (code != 0) fail_code("pthread_mutexattr_setpshared", code);
    code = pthread_condattr_setpshared(&cond_attr, PTHREAD_PROCESS_SHARED);
    if (code != 0) fail_code("pthread_condattr_setpshared", code);
  }
  code = pthread_mutex_init(&pool.state->mutex, &mutex_attr);
  if (code != 0) fail_code("pthread_mutex_init", code);
  code = pthread_cond_init(&pool.state->start_cond, &cond_attr);
  if (code != 0) fail_code("pthread_cond_init", code);
  code = pthread_cond_init(&pool.state->done_cond, &cond_attr);
  if (code != 0) fail_code("pthread_cond_init", code);
  pthread_mutexattr_destroy(&mutex_attr);
  pthread_condattr_destroy(&cond_attr);
  pool.state->worker_count = worker_count;

  pool.args = calloc(worker_count, sizeof(WorkerArg));
  if (pool.args == NULL) fail_errno("calloc worker args");
  for (size_t id = 0; id < worker_count; id++) {
    pool.args[id] = (WorkerArg){.state = pool.state, .id = id};
  }

  if (backend == BACKEND_PTHREAD) {
    pool.threads = calloc(worker_count, sizeof(pthread_t));
    if (pool.threads == NULL) fail_errno("calloc threads");
    for (size_t id = 0; id < worker_count; id++) {
      code = pthread_create(&pool.threads[id], NULL, thread_entry, &pool.args[id]);
      if (code != 0) fail_code("pthread_create", code);
    }
  } else {
    pool.pids = calloc(worker_count, sizeof(pid_t));
    if (pool.pids == NULL) fail_errno("calloc pids");
    for (size_t id = 0; id < worker_count; id++) {
      const pid_t pid = fork();
      if (pid < 0) fail_errno("fork");
      if (pid == 0) {
        worker_loop(&pool.args[id]);
        _exit(0);
      }
      pool.pids[id] = pid;
    }
  }
  return pool;
}

static void pool_run(Pool *pool, size_t elements, uint32_t compute_rounds) {
  SharedState *state = pool->state;
  int code = pthread_mutex_lock(&state->mutex);
  if (code != 0) fail_code("pthread_mutex_lock", code);
  state->elements = elements;
  state->compute_rounds = compute_rounds;
  state->remaining = pool->worker_count;
  state->epoch++;
  code = pthread_cond_broadcast(&state->start_cond);
  if (code != 0) fail_code("pthread_cond_broadcast", code);
  while (state->remaining != 0) {
    code = pthread_cond_wait(&state->done_cond, &state->mutex);
    if (code != 0) fail_code("pthread_cond_wait", code);
  }
  code = pthread_mutex_unlock(&state->mutex);
  if (code != 0) fail_code("pthread_mutex_unlock", code);
}

static void pool_destroy(Pool *pool) {
  int code = pthread_mutex_lock(&pool->state->mutex);
  if (code != 0) fail_code("pthread_mutex_lock", code);
  pool->state->stop = true;
  pool->state->epoch++;
  code = pthread_cond_broadcast(&pool->state->start_cond);
  if (code != 0) fail_code("pthread_cond_broadcast", code);
  code = pthread_mutex_unlock(&pool->state->mutex);
  if (code != 0) fail_code("pthread_mutex_unlock", code);

  if (pool->backend == BACKEND_PTHREAD) {
    for (size_t id = 0; id < pool->worker_count; id++) {
      code = pthread_join(pool->threads[id], NULL);
      if (code != 0) fail_code("pthread_join", code);
    }
  } else {
    for (size_t id = 0; id < pool->worker_count; id++) {
      int status = 0;
      if (waitpid(pool->pids[id], &status, 0) < 0) fail_errno("waitpid");
      if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "worker process exited abnormally\n");
        exit(1);
      }
    }
  }
  pthread_cond_destroy(&pool->state->done_cond);
  pthread_cond_destroy(&pool->state->start_cond);
  pthread_mutex_destroy(&pool->state->mutex);
  munmap(pool->state, pool->mapping_size);
  free(pool->threads);
  free(pool->pids);
  free(pool->args);
}

static double now_us(void) {
  struct timespec time;
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) fail_errno("clock_gettime");
  return (double)time.tv_sec * 1000000.0 + (double)time.tv_nsec / 1000.0;
}

static int compare_double(const void *left, const void *right) {
  const double a = *(const double *)left;
  const double b = *(const double *)right;
  return (a > b) - (a < b);
}

static double percentile(const double *sorted, size_t count, double ratio) {
  if (count == 1) return sorted[0];
  const double position = (double)(count - 1) * ratio;
  const size_t lower = (size_t)position;
  const size_t upper = lower + (position > (double)lower ? 1 : 0);
  const double weight = position - (double)lower;
  return sorted[lower] * (1.0 - weight) + sorted[upper] * weight;
}

static Summary summarize(double *samples, size_t count) {
  qsort(samples, count, sizeof(double), compare_double);
  return (Summary){
      .min_us = samples[0],
      .median_us = percentile(samples, count, 0.5),
      .p95_us = percentile(samples, count, 0.95),
      .max_us = samples[count - 1],
  };
}

static void initialize_data(uint32_t *data, size_t elements) {
  for (size_t index = 0; index < elements; index++) {
    data[index] = (uint32_t)index * UINT32_C(2654435761) + UINT32_C(12345);
  }
}

static uint32_t checksum_data(const uint32_t *data, size_t elements) {
  uint32_t checksum = 0;
  for (size_t index = 0; index < elements; index++) checksum ^= data[index];
  return checksum;
}

static ScenarioResult measure_scenario(
    Pool *pool,
    size_t elements,
    uint32_t compute_rounds,
    size_t warmups,
    size_t batches) {
  initialize_data(pool->state->data, elements);
  for (size_t warmup = 0; warmup < warmups; warmup++) {
    pool_run(pool, elements, compute_rounds);
  }
  double *samples = calloc(batches, sizeof(double));
  if (samples == NULL) fail_errno("calloc samples");
  for (size_t batch = 0; batch < batches; batch++) {
    const double started = now_us();
    pool_run(pool, elements, compute_rounds);
    samples[batch] = now_us() - started;
  }
  ScenarioResult result = {
      .timing = summarize(samples, batches),
      .checksum = checksum_data(pool->state->data, elements),
  };
  free(samples);
  return result;
}

static void self_test(Backend backend) {
  Pool pool = pool_create(backend, 3, 17);
  initialize_data(pool.state->data, 17);
  uint32_t expected[17];
  memcpy(expected, pool.state->data, sizeof(expected));
  pool_run(&pool, 17, 4);
  transform_range(expected, 0, 17, 4);
  if (memcmp(expected, pool.state->data, sizeof(expected)) != 0) {
    fprintf(stderr, "transform contract mismatch\n");
    exit(1);
  }
  pool_run(&pool, 0, 0);
  pool_destroy(&pool);
  puts("self-test ok");
}

static const char *backend_name(Backend backend) {
  return backend == BACKEND_PTHREAD ? "c-pthread" : "c-mmap-process";
}

static void print_scenario(
    const char *name,
    ScenarioResult result,
    size_t elements,
    uint32_t compute_rounds) {
  const double seconds = result.timing.median_us / 1000000.0;
  const double gib_per_s = elements == 0 ? 0.0 : ((double)elements * 8.0) / seconds / 1073741824.0;
  const double mops = compute_rounds == 0 ? 0.0 : ((double)elements * compute_rounds) / seconds / 1000000.0;
  printf(
      "\"%s\":{\"elements\":%zu,\"compute_rounds\":%" PRIu32
      ",\"median_us\":%.3f,\"p95_us\":%.3f,\"gib_per_s\":%.3f,\"mops\":%.3f,\"checksum\":%" PRIu32 "}",
      name,
      elements,
      compute_rounds,
      result.timing.median_us,
      result.timing.p95_us,
      gib_per_s,
      mops,
      result.checksum);
}

int main(int argc, char **argv) {
  Backend backend = BACKEND_PTHREAD;
  size_t worker_count = 4;
  bool run_self_test = false;
  bool quick = false;
  for (int index = 1; index < argc; index++) {
    if (strcmp(argv[index], "--backend") == 0 && index + 1 < argc) {
      const char *value = argv[++index];
      if (strcmp(value, "pthread") == 0) backend = BACKEND_PTHREAD;
      else if (strcmp(value, "mmap") == 0) backend = BACKEND_MMAP;
      else {
        fprintf(stderr, "unknown backend: %s\n", value);
        return 2;
      }
    } else if (strcmp(argv[index], "--workers") == 0 && index + 1 < argc) {
      worker_count = strtoul(argv[++index], NULL, 10);
      if (worker_count == 0) {
        fprintf(stderr, "workers must be positive\n");
        return 2;
      }
    } else if (strcmp(argv[index], "--self-test") == 0) {
      run_self_test = true;
    } else if (strcmp(argv[index], "--quick") == 0) {
      quick = true;
    } else {
      fprintf(stderr, "unknown argument: %s\n", argv[index]);
      return 2;
    }
  }
  if (run_self_test) {
    self_test(backend);
    return 0;
  }

  const size_t memory_elements = quick ? (UINT32_C(1) << 18) : (UINT32_C(1) << 22);
  const size_t memory_batches = quick ? 3 : 25;
  const size_t compute_elements = quick ? (UINT32_C(1) << 14) : (UINT32_C(1) << 18);
  const uint32_t compute_rounds = quick ? 16 : 64;
  const size_t compute_batches = quick ? 3 : 20;
  const size_t dispatch_batches = quick ? 100 : 5000;
  Pool pool = pool_create(backend, worker_count, memory_elements);
  const ScenarioResult dispatch = measure_scenario(&pool, 0, 0, 20, dispatch_batches);
  const ScenarioResult memory = measure_scenario(&pool, memory_elements, 1, 5, memory_batches);
  const ScenarioResult compute = measure_scenario(
      &pool,
      compute_elements,
      compute_rounds,
      3,
      compute_batches);
  pool_destroy(&pool);

  printf("{\"backend\":\"%s\",\"workers\":%zu,", backend_name(backend), worker_count);
  print_scenario("dispatch", dispatch, 0, 0);
  putchar(',');
  print_scenario("memory", memory, memory_elements, 1);
  putchar(',');
  print_scenario("compute", compute, compute_elements, compute_rounds);
  puts("}");
  return 0;
}
