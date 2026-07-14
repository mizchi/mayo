export type { Summary } from "./stats.ts";
export { summarize } from "./stats.ts";

export const SHARED_INDEX = {
  lock: 0,
  counter: 1,
  start: 2,
  length: 3,
} as const;

export interface ContendedCounterOptions {
  workerUrl: URL;
  workerCount: number;
  iterationsPerWorker: number;
  timeoutMs?: number;
}

export interface ContendedCounterResult {
  workerCount: number;
  iterationsPerWorker: number;
  expectedCounter: number;
  finalCounter: number;
  workerOnlineMs: number[];
  workerExecutionMs: number[];
  readyWallMs: number;
  executionWallMs: number;
  lifecycleWallMs: number;
}

type WorkerMessage =
  | { type: "online" }
  | { type: "initialized"; id: number }
  | { type: "ready"; id: number }
  | { type: "result"; id: number; executionMs: number; observedCounter: number };

function workerError(error: ErrorEvent): Error {
  return error.error instanceof Error ? error.error : new Error(error.message);
}

export async function measureWorkerStartup(
  workerUrl: URL,
  samples: number,
  timeoutMs = 10_000,
): Promise<number[]> {
  if (!Number.isInteger(samples) || samples < 1) {
    throw new RangeError("samples must be a positive integer");
  }

  const timings: number[] = [];
  for (let index = 0; index < samples; index += 1) {
    const startedAt = performance.now();
    const worker = new Worker(workerUrl, { type: "module" });
    try {
      const elapsed = await new Promise<number>((resolve, reject) => {
        const timeout = setTimeout(
          () => reject(new Error(`worker startup timed out after ${timeoutMs} ms`)),
          timeoutMs,
        );
        worker.onmessage = (event: MessageEvent<WorkerMessage>) => {
          if (event.data.type !== "online") return;
          clearTimeout(timeout);
          resolve(performance.now() - startedAt);
        };
        worker.onerror = (event) => {
          clearTimeout(timeout);
          reject(workerError(event));
        };
      });
      timings.push(elapsed);
    } finally {
      worker.terminate();
    }
  }
  return timings;
}

export async function runContendedCounter(
  options: ContendedCounterOptions,
): Promise<ContendedCounterResult> {
  const {
    workerUrl,
    workerCount,
    iterationsPerWorker,
    timeoutMs = 30_000,
  } = options;
  if (!Number.isInteger(workerCount) || workerCount < 1) {
    throw new RangeError("workerCount must be a positive integer");
  }
  if (!Number.isInteger(iterationsPerWorker) || iterationsPerWorker < 1) {
    throw new RangeError("iterationsPerWorker must be a positive integer");
  }

  const shared = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * SHARED_INDEX.length);
  const state = new Int32Array(shared);
  const workers: Worker[] = [];
  const workerOnlineMs = Array<number>(workerCount);
  const workerExecutionMs = Array<number>(workerCount);
  const workerCreatedAt = Array<number>(workerCount);
  const lifecycleStartedAt = performance.now();
  let readyCount = 0;
  let resultCount = 0;
  let readyWallMs = 0;
  let executionStartedAt = 0;

  try {
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const fail = (error: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        reject(error);
      };
      const timeout = setTimeout(
        () => fail(new Error(`contended run timed out after ${timeoutMs} ms`)),
        timeoutMs,
      );

      for (let id = 0; id < workerCount; id += 1) {
        workerCreatedAt[id] = performance.now();
        const worker = new Worker(workerUrl, { type: "module" });
        workers.push(worker);
        worker.onerror = (event) => fail(workerError(event));
        worker.onmessage = (event: MessageEvent<WorkerMessage>) => {
          const message = event.data;
          if (message.type === "online") {
            workerOnlineMs[id] = performance.now() - workerCreatedAt[id];
            worker.postMessage({ type: "init", id, shared });
            return;
          }
          if (message.type === "initialized") {
            worker.postMessage({ type: "counter", id, iterations: iterationsPerWorker });
            return;
          }
          if (message.type === "ready") {
            readyCount += 1;
            if (readyCount === workerCount) {
              readyWallMs = performance.now() - lifecycleStartedAt;
              executionStartedAt = performance.now();
              Atomics.store(state, SHARED_INDEX.start, 1);
              Atomics.notify(state, SHARED_INDEX.start);
            }
            return;
          }
          workerExecutionMs[message.id] = message.executionMs;
          resultCount += 1;
          if (resultCount === workerCount && !settled) {
            settled = true;
            clearTimeout(timeout);
            resolve();
          }
        };
      }
    });

    const finishedAt = performance.now();
    return {
      workerCount,
      iterationsPerWorker,
      expectedCounter: workerCount * iterationsPerWorker,
      finalCounter: Atomics.load(state, SHARED_INDEX.counter),
      workerOnlineMs,
      workerExecutionMs,
      readyWallMs,
      executionWallMs: finishedAt - executionStartedAt,
      lifecycleWallMs: finishedAt - lifecycleStartedAt,
    };
  } finally {
    for (const worker of workers) worker.terminate();
  }
}
