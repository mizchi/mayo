import { summarize } from "./stats.ts";

export interface MatrixScenario {
  elements: number;
  computeRounds: number;
  warmups: number;
  batches: number;
}

interface ScenarioReport {
  elements: number;
  compute_rounds: number;
  median_us: number;
  p95_us: number;
  checksum: number;
}

interface BackendPoint extends ScenarioReport {
  backend: string;
  workers: number;
}

interface CommandReport {
  backend: string;
  workers: number;
  scenario: ScenarioReport;
}

interface Config {
  workers: number;
  quick: boolean;
  json: boolean;
}

export interface SpeedupPoint {
  operations: number;
  serialUs: number;
  parallelUs: number;
}

export interface BreakEven {
  operations: number;
  speedup: number;
}

function batchesFor(operations: number, quick: boolean): number {
  if (quick) {
    if (operations <= 16_384) return 30;
    if (operations <= 65_536) return 10;
    return 3;
  }
  if (operations <= 16_384) return 100;
  if (operations <= 1_048_576) return 30;
  if (operations <= 16_777_216) return 10;
  return 3;
}

export function scenarioGrid(quick: boolean): MatrixScenario[] {
  const elements = quick ? [1_024, 65_536] : [256, 4_096, 65_536, 1_048_576];
  const rounds = quick ? [1, 16] : [1, 16, 64];
  const scenarios: MatrixScenario[] = [
    { elements: 0, computeRounds: 0, warmups: 10, batches: 100 },
  ];
  for (const elementCount of elements) {
    for (const computeRounds of rounds) {
      scenarios.push({
        elements: elementCount,
        computeRounds,
        warmups: 3,
        batches: batchesFor(elementCount * computeRounds, quick),
      });
    }
  }
  return scenarios;
}

export function classifyBreakEven(points: readonly SpeedupPoint[]): BreakEven | undefined {
  const winner = [...points]
    .sort((left, right) => left.operations - right.operations)
    .find((point) => point.parallelUs < point.serialUs);
  return winner === undefined
    ? undefined
    : { operations: winner.operations, speedup: winner.serialUs / winner.parallelUs };
}

function parseArgs(args: readonly string[]): Config {
  let workers = Math.min(4, navigator.hardwareConcurrency || 1);
  let quick = false;
  let json = false;
  for (let index = 0; index < args.length; index += 1) {
    switch (args[index]) {
      case "--workers":
        workers = Number(args[++index]);
        break;
      case "--quick":
        quick = true;
        break;
      case "--json":
        json = true;
        break;
      default:
        throw new Error(`unknown argument: ${args[index]}`);
    }
  }
  if (!Number.isSafeInteger(workers) || workers < 1) {
    throw new Error("workers must be a positive integer");
  }
  return { workers, quick, json };
}

function initialize(values: Int32Array, elements: number): void {
  for (let index = 0; index < elements; index += 1) {
    values[index] = (Math.imul(index, 2_654_435_761) + 12_345) | 0;
  }
}

function transform(values: Int32Array, elements: number, rounds: number): void {
  for (let index = 0; index < elements; index += 1) {
    let value = values[index];
    for (let round = 0; round < rounds; round += 1) {
      value = (Math.imul(value, 1_664_525) + 1_013_904_223) | 0;
    }
    values[index] = value;
  }
}

function checksum(values: Int32Array, elements: number): number {
  let result = 0;
  for (let index = 0; index < elements; index += 1) result ^= values[index];
  return result >>> 0;
}

function runDenoSerial(scenario: MatrixScenario): BackendPoint {
  const values = new Int32Array(scenario.elements);
  initialize(values, scenario.elements);
  for (let warmup = 0; warmup < scenario.warmups; warmup += 1) {
    transform(values, scenario.elements, scenario.computeRounds);
  }
  const samples: number[] = [];
  for (let batch = 0; batch < scenario.batches; batch += 1) {
    const startedAt = performance.now();
    transform(values, scenario.elements, scenario.computeRounds);
    samples.push(performance.now() - startedAt);
  }
  const timing = summarize(samples);
  return {
    backend: "deno-serial",
    workers: 1,
    elements: scenario.elements,
    compute_rounds: scenario.computeRounds,
    median_us: timing.median * 1_000,
    p95_us: timing.p95 * 1_000,
    checksum: checksum(values, scenario.elements),
  };
}

function scenarioArgs(scenario: MatrixScenario): string[] {
  return [
    "--elements",
    String(scenario.elements),
    "--rounds",
    String(scenario.computeRounds),
    "--warmups",
    String(scenario.warmups),
    "--batches",
    String(scenario.batches),
  ];
}

async function commandReport(command: string, args: string[]): Promise<CommandReport> {
  const output = await new Deno.Command(command, {
    args,
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!output.success) {
    throw new Error(new TextDecoder().decode(output.stderr));
  }
  return JSON.parse(new TextDecoder().decode(output.stdout));
}

async function runNative(
  executable: string,
  backend: string,
  workers: number,
  scenario: MatrixScenario,
): Promise<BackendPoint> {
  const report = await commandReport(executable, [
    "--backend",
    backend,
    "--workers",
    String(workers),
    ...scenarioArgs(scenario),
  ]);
  return { backend: report.backend, workers: report.workers, ...report.scenario };
}

async function runMayo(
  wasm: boolean,
  workers: number,
  scenario: MatrixScenario,
): Promise<BackendPoint> {
  const args = [
    "run",
    "--allow-read",
    "./dist/mayo_bench.js",
    "--workers",
    String(workers),
    ...scenarioArgs(scenario),
  ];
  if (wasm) args.push("--wasm");
  const report = await commandReport(Deno.execPath(), args);
  return { backend: report.backend, workers: report.workers, ...report.scenario };
}

async function runScenario(
  scenario: MatrixScenario,
  workers: number,
): Promise<BackendPoint[]> {
  const serial = runDenoSerial(scenario);
  const parallel = await Promise.all([
    runNative("./dist/c-bench", "pthread", workers, scenario),
    runNative("./dist/c-bench", "mmap", workers, scenario),
    runNative("./dist/rust-bench", "std", workers, scenario),
    runNative("./dist/rust-bench", "rayon", workers, scenario),
    runMayo(false, workers, scenario),
    runMayo(true, workers, scenario),
  ]);
  const points = [serial, ...parallel];
  const checksums = new Set(points.map((point) => point.checksum));
  if (checksums.size !== 1) {
    throw new Error(
      `checksum mismatch for ${scenario.elements}x${scenario.computeRounds}: ${
        points.map((point) => `${point.backend}=${point.checksum}`).join(", ")
      }`,
    );
  }
  return points;
}

function formatUs(value: number): string {
  return value < 1_000 ? value.toFixed(1) : `${(value / 1_000).toFixed(2)}ms`;
}

function printMatrix(scenarios: readonly MatrixScenario[], points: readonly BackendPoint[]): void {
  const backends = [...new Set(points.map((point) => point.backend))];
  console.log(`warm pools, shared buffers, startup excluded; latency is median dispatch time`);
  console.log(
    "elements".padStart(10) +
      "rounds".padStart(9) +
      "ops".padStart(13) +
      backends.map((backend) => backend.padStart(18)).join(""),
  );
  for (const scenario of scenarios) {
    const row = points.filter((point) =>
      point.elements === scenario.elements && point.compute_rounds === scenario.computeRounds
    );
    console.log(
      String(scenario.elements).padStart(10) +
        String(scenario.computeRounds).padStart(9) +
        String(scenario.elements * scenario.computeRounds).padStart(13) +
        backends.map((backend) => {
          const point = row.find((candidate) => candidate.backend === backend);
          return (point === undefined ? "-" : formatUs(point.median_us)).padStart(18);
        }).join(""),
    );
  }
}

function mayoBreakEven(points: readonly BackendPoint[]): BreakEven | undefined {
  const serial = points.filter((point) => point.backend === "deno-serial");
  const mayo = points.filter((point) => point.backend === "mayo");
  return classifyBreakEven(mayo.map((parallel) => {
    const baseline = serial.find((candidate) =>
      candidate.elements === parallel.elements &&
      candidate.compute_rounds === parallel.compute_rounds
    );
    if (baseline === undefined) throw new Error("missing Deno serial baseline");
    return {
      operations: parallel.elements * parallel.compute_rounds,
      serialUs: baseline.median_us,
      parallelUs: parallel.median_us,
    };
  }));
}

async function main(): Promise<void> {
  const config = parseArgs(Deno.args);
  const scenarios = scenarioGrid(config.quick);
  const groups: BackendPoint[][] = [];
  for (const scenario of scenarios) groups.push(await runScenario(scenario, config.workers));
  const points = groups.flat();
  const breakEven = mayoBreakEven(points);
  if (config.json) {
    console.log(JSON.stringify({ config, scenarios, points, mayo_break_even: breakEven }, null, 2));
    return;
  }
  printMatrix(scenarios, points);
  console.log(
    breakEven === undefined
      ? "Mayo did not beat the Deno serial baseline in this grid."
      : `Mayo first beat Deno serial at ${breakEven.operations} LCG operations (${
        breakEven.speedup.toFixed(2)
      }x).`,
  );
}

if (import.meta.main) await main();
