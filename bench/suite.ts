import { MoonbitMessagePool } from "./message_pool.ts";
import { summarize } from "./stats.ts";

export interface ScenarioReport {
  elements: number;
  compute_rounds: number;
  median_us: number;
  p95_us: number;
  gib_per_s: number;
  mops: number;
  checksum: number;
}

export interface BenchmarkReport {
  backend: string;
  workers: number;
  dispatch: ScenarioReport;
  memory: ScenarioReport;
  compute: ScenarioReport;
}

export interface SuiteOptions {
  workerCount: number;
  quick?: boolean;
}

interface ScenarioConfig {
  elements: number;
  computeRounds: number;
  warmups: number;
  batches: number;
}

function initializeData(values: Int32Array, elements: number): void {
  for (let index = 0; index < elements; index += 1) {
    values[index] = (Math.imul(index, 2_654_435_761) + 12_345) | 0;
  }
}

function checksumData(values: Int32Array, elements: number): number {
  let checksum = 0;
  for (let index = 0; index < elements; index += 1) checksum ^= values[index];
  return checksum >>> 0;
}

async function measureScenario(
  dispatch: (elementCount: number, computeRounds: number) => void | Promise<void>,
  values: Int32Array,
  config: ScenarioConfig,
): Promise<ScenarioReport> {
  initializeData(values, config.elements);
  for (let warmup = 0; warmup < config.warmups; warmup += 1) {
    await dispatch(config.elements, config.computeRounds);
  }
  const samples: number[] = [];
  for (let batch = 0; batch < config.batches; batch += 1) {
    const startedAt = performance.now();
    await dispatch(config.elements, config.computeRounds);
    samples.push(performance.now() - startedAt);
  }
  const timing = summarize(samples);
  const seconds = timing.median / 1_000;
  return {
    elements: config.elements,
    compute_rounds: config.computeRounds,
    median_us: timing.median * 1_000,
    p95_us: timing.p95 * 1_000,
    gib_per_s: config.elements === 0
      ? 0
      : (config.elements * Int32Array.BYTES_PER_ELEMENT * 2) / seconds / 2 ** 30,
    mops: config.computeRounds === 0
      ? 0
      : (config.elements * config.computeRounds) / seconds / 1_000_000,
    checksum: checksumData(values, config.elements),
  };
}

async function runPoolSuite(
  dispatch: (elementCount: number, computeRounds: number) => void | Promise<void>,
  values: Int32Array,
  backend: string,
  workerCount: number,
  quick: boolean,
): Promise<BenchmarkReport> {
  const memoryElements = quick ? 1 << 18 : 1 << 22;
  const dispatchReport = await measureScenario(dispatch, values, {
    elements: 0,
    computeRounds: 0,
    warmups: 20,
    batches: quick ? 100 : 5_000,
  });
  const memory = await measureScenario(dispatch, values, {
    elements: memoryElements,
    computeRounds: 1,
    warmups: 5,
    batches: quick ? 3 : 25,
  });
  const compute = await measureScenario(dispatch, values, {
    elements: quick ? 1 << 14 : 1 << 18,
    computeRounds: quick ? 16 : 64,
    warmups: 3,
    batches: quick ? 3 : 20,
  });
  return {
    backend,
    workers: workerCount,
    dispatch: dispatchReport,
    memory,
    compute,
  };
}

export async function runMoonbitSuite(options: SuiteOptions): Promise<BenchmarkReport> {
  const { workerCount, quick = false } = options;
  const memoryElements = quick ? 1 << 18 : 1 << 22;
  const shared = new SharedArrayBuffer(memoryElements * Int32Array.BYTES_PER_ELEMENT);
  const values = new Int32Array(shared);
  const pool = await MoonbitMessagePool.create(
    new URL("../dist/bench_worker.js", import.meta.url),
    workerCount,
    shared,
  );
  try {
    return await runPoolSuite(
      (elements, rounds) => pool.transform(elements, rounds),
      values,
      "moonbit-message",
      workerCount,
      quick,
    );
  } finally {
    pool.close();
  }
}

export async function runMayoSuite(options: SuiteOptions): Promise<BenchmarkReport> {
  return await runMayoProcess(options, false);
}

export async function runMayoWasmSuite(options: SuiteOptions): Promise<BenchmarkReport> {
  return await runMayoProcess(options, true);
}

async function runMayoProcess(
  options: SuiteOptions,
  wasm: boolean,
): Promise<BenchmarkReport> {
  const { workerCount, quick = false } = options;
  const args = [
    "run",
    "--allow-read",
    "./dist/mayo_bench.js",
    "--workers",
    String(workerCount),
  ];
  if (quick) args.push("--quick");
  if (wasm) args.push("--wasm");
  const output = await new Deno.Command(Deno.execPath(), {
    args,
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!output.success) {
    throw new Error(new TextDecoder().decode(output.stderr));
  }
  return JSON.parse(new TextDecoder().decode(output.stdout));
}
