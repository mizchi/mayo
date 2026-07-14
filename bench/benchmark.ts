import { measureWorkerStartup, runContendedCounter, summarize } from "./harness.ts";

interface Config {
  workers: number;
  iterations: number;
  samples: number;
  rounds: number;
  json: boolean;
}

function parsePositiveInteger(name: string, value: string | undefined): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1) {
    throw new Error(`${name} must be a positive integer, received: ${value}`);
  }
  return parsed;
}

function parseArgs(args: readonly string[]): Config {
  const values = new Map<string, string>();
  let json = false;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--json") {
      json = true;
      continue;
    }
    const matched = argument.match(/^--([^=]+)(?:=(.+))?$/);
    if (!matched) throw new Error(`unknown argument: ${argument}`);
    const [, key, inlineValue] = matched;
    const value = inlineValue ?? args[++index];
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`--${key} requires a value`);
    }
    values.set(key, value);
  }
  const hardwareConcurrency = navigator.hardwareConcurrency || 1;
  return {
    workers: parsePositiveInteger(
      "workers",
      values.get("workers") ?? String(Math.min(4, hardwareConcurrency)),
    ),
    iterations: parsePositiveInteger("iterations", values.get("iterations") ?? "50000"),
    samples: parsePositiveInteger("samples", values.get("samples") ?? "30"),
    rounds: parsePositiveInteger("rounds", values.get("rounds") ?? "10"),
    json,
  };
}

function formatMs(value: number): string {
  return `${value.toFixed(3)} ms`;
}

function formatSummary(label: string, values: readonly number[]): string {
  const summary = summarize(values);
  return `${label.padEnd(24)} median=${formatMs(summary.median).padStart(11)}  p95=${
    formatMs(summary.p95).padStart(11)
  }  min=${formatMs(summary.min).padStart(11)}  max=${formatMs(summary.max).padStart(11)}`;
}

async function measureStartupPairs(noopUrl: URL, moonbitUrl: URL, samples: number) {
  const noop: number[] = [];
  const moonbit: number[] = [];
  const additional: number[] = [];
  for (let sample = 0; sample < samples; sample += 1) {
    const order = sample % 2 === 0 ? [noopUrl, moonbitUrl] : [moonbitUrl, noopUrl];
    const first = (await measureWorkerStartup(order[0], 1))[0];
    const second = (await measureWorkerStartup(order[1], 1))[0];
    const noopValue = order[0] === noopUrl ? first : second;
    const moonbitValue = order[0] === moonbitUrl ? first : second;
    noop.push(noopValue);
    moonbit.push(moonbitValue);
    additional.push(moonbitValue - noopValue);
  }
  return { noop, moonbit, additional };
}

async function main() {
  const config = parseArgs(Deno.args);
  const noopUrl = new URL("./noop_worker.js", import.meta.url);
  const moonbitUrl = new URL("../dist/bench_worker.js", import.meta.url);
  const artifactBytes = (await Deno.stat(moonbitUrl)).size;
  const startup = await measureStartupPairs(noopUrl, moonbitUrl, config.samples);

  const contention = [];
  for (let round = 0; round < config.rounds; round += 1) {
    const result = await runContendedCounter({
      workerUrl: moonbitUrl,
      workerCount: config.workers,
      iterationsPerWorker: config.iterations,
    });
    if (result.finalCounter !== result.expectedCounter) {
      throw new Error(
        `counter mismatch: expected ${result.expectedCounter}, received ${result.finalCounter}`,
      );
    }
    contention.push(result);
  }

  const report = {
    runtime: {
      deno: Deno.version.deno,
      v8: Deno.version.v8,
      typescript: Deno.version.typescript,
      os: Deno.build.os,
      arch: Deno.build.arch,
      hardwareConcurrency: navigator.hardwareConcurrency,
    },
    config,
    artifact: {
      url: moonbitUrl.href,
      bytes: artifactBytes,
    },
    startup: {
      emptyWorker: summarize(startup.noop),
      moonbitWorker: summarize(startup.moonbit),
      estimatedMoonbitAdditional: summarize(startup.additional),
      raw: startup,
    },
    contention: {
      readyWallMs: summarize(contention.map((result) => result.readyWallMs)),
      executionWallMs: summarize(contention.map((result) => result.executionWallMs)),
      lifecycleWallMs: summarize(contention.map((result) => result.lifecycleWallMs)),
      workerOnlineMs: summarize(contention.flatMap((result) => result.workerOnlineMs)),
      workerExecutionMs: summarize(contention.flatMap((result) => result.workerExecutionMs)),
      counters: contention.map((result) => result.finalCounter),
      raw: contention,
    },
  };

  if (config.json) {
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  console.log(
    `Deno ${report.runtime.deno} / V8 ${report.runtime.v8} / ${report.runtime.os}-${report.runtime.arch}`,
  );
  console.log(`logical CPUs: ${report.runtime.hardwareConcurrency}`);
  console.log(`prebuilt MoonBit worker: ${artifactBytes} bytes`);
  console.log(`startup: ${config.samples} interleaved samples (constructor -> online)`);
  console.log(formatSummary("empty Deno Worker", startup.noop));
  console.log(formatSummary("MoonBit Worker", startup.moonbit));
  console.log(formatSummary("MoonBit additional (est.)", startup.additional));
  console.log("");
  console.log(
    `contention: ${config.workers} workers x ${config.iterations.toLocaleString()} increments x ${config.rounds} rounds`,
  );
  console.log(
    formatSummary("batch create -> ready", contention.map((result) => result.readyWallMs)),
  );
  console.log(
    formatSummary("start -> all results", contention.map((result) => result.executionWallMs)),
  );
  console.log(
    formatSummary("create -> all results", contention.map((result) => result.lifecycleWallMs)),
  );
  console.log(
    `counter: ${contention[0].finalCounter.toLocaleString()} / expected ${
      contention[0].expectedCounter.toLocaleString()
    } (all rounds verified)`,
  );
}

if (import.meta.main) await main();
