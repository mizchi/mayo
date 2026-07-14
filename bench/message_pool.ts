interface OnlineMessage {
  type: "online";
}

interface InitializedMessage {
  type: "initialized";
  id: number;
}

interface TransformedMessage {
  type: "transformed";
  id: number;
  batchId: number;
  executionMs: number;
}

type PoolMessage = OnlineMessage | InitializedMessage | TransformedMessage;

function workerError(event: ErrorEvent): Error {
  return event.error instanceof Error ? event.error : new Error(event.message);
}

function waitForMessage<T extends PoolMessage>(
  worker: Worker,
  predicate: (message: PoolMessage) => message is T,
  timeoutMs = 10_000,
): Promise<T> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error(`worker message timed out after ${timeoutMs} ms`));
    }, timeoutMs);
    const onMessage = (event: MessageEvent<PoolMessage>) => {
      if (!predicate(event.data)) return;
      cleanup();
      resolve(event.data);
    };
    const onError = (event: ErrorEvent) => {
      cleanup();
      reject(workerError(event));
    };
    const cleanup = () => {
      clearTimeout(timeout);
      worker.removeEventListener("message", onMessage);
      worker.removeEventListener("error", onError);
    };
    worker.addEventListener("message", onMessage);
    worker.addEventListener("error", onError);
  });
}

async function createWorker(workerUrl: URL): Promise<Worker> {
  const worker = new Worker(workerUrl, { type: "module" });
  try {
    await waitForMessage(worker, (message): message is OnlineMessage => message.type === "online");
    return worker;
  } catch (error) {
    worker.terminate();
    throw error;
  }
}

export function mixReference(value: number, rounds: number): number {
  let mixed = value | 0;
  for (let round = 0; round < rounds; round += 1) {
    mixed = (Math.imul(mixed, 1_664_525) + 1_013_904_223) | 0;
  }
  return mixed >>> 0;
}

/** Benchmark-only postMessage pool retained as a comparison backend. */
export class MoonbitMessagePool {
  #workers: Worker[];
  #batchId = 0;
  #busy = false;

  private constructor(workers: Worker[]) {
    this.#workers = workers;
  }

  static async create(
    workerUrl: URL,
    workerCount: number,
    shared: SharedArrayBuffer,
  ): Promise<MoonbitMessagePool> {
    if (!Number.isInteger(workerCount) || workerCount < 1) {
      throw new RangeError("workerCount must be a positive integer");
    }
    const workers = await Promise.all(
      Array.from({ length: workerCount }, () => createWorker(workerUrl)),
    );
    try {
      await Promise.all(
        workers.map((worker, id) => {
          const initialized = waitForMessage(
            worker,
            (message): message is InitializedMessage =>
              message.type === "initialized" && message.id === id,
          );
          worker.postMessage({ type: "init", id, shared });
          return initialized;
        }),
      );
      return new MoonbitMessagePool(workers);
    } catch (error) {
      for (const worker of workers) worker.terminate();
      throw error;
    }
  }

  get workerCount(): number {
    return this.#workers.length;
  }

  async transform(elementCount: number, computeRounds: number): Promise<void> {
    if (this.#busy) throw new Error("worker pool already has an active batch");
    if (!Number.isInteger(elementCount) || elementCount < 0) {
      throw new RangeError("elementCount must be a non-negative integer");
    }
    if (!Number.isInteger(computeRounds) || computeRounds < 0) {
      throw new RangeError("computeRounds must be a non-negative integer");
    }
    this.#busy = true;
    const batchId = ++this.#batchId;
    try {
      await Promise.all(
        this.#workers.map((worker, id) => {
          const transformed = waitForMessage(
            worker,
            (message): message is TransformedMessage =>
              message.type === "transformed" && message.batchId === batchId && message.id === id,
            30_000,
          );
          const start = Math.floor((elementCount * id) / this.#workers.length);
          const end = Math.floor((elementCount * (id + 1)) / this.#workers.length);
          worker.postMessage({
            type: "transform",
            id,
            batchId,
            start,
            end,
            computeRounds,
          });
          return transformed;
        }),
      );
    } finally {
      this.#busy = false;
    }
  }

  close(): void {
    for (const worker of this.#workers) worker.terminate();
  }
}
