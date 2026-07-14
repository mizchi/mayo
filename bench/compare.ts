import { type BenchmarkReport, runMayoSuite, runMoonbitSuite } from "./suite.ts";

interface Config {
  workers: number;
  quick: boolean;
  json: boolean;
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

async function runNative(
  executable: string,
  backend: string,
  config: Config,
): Promise<BenchmarkReport> {
  const args = ["--backend", backend, "--workers", String(config.workers)];
  if (config.quick) args.push("--quick");
  const output = await new Deno.Command(executable, {
    args,
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!output.success) {
    throw new Error(new TextDecoder().decode(output.stderr));
  }
  return JSON.parse(new TextDecoder().decode(output.stdout));
}

function validateChecksums(reports: readonly BenchmarkReport[]): void {
  for (const scenario of ["memory", "compute"] as const) {
    const checksums = new Set(reports.map((report) => report[scenario].checksum));
    if (checksums.size !== 1) {
      throw new Error(
        `${scenario} checksum mismatch: ${
          reports.map((report) => `${report.backend}=${report[scenario].checksum}`).join(", ")
        }`,
      );
    }
  }
}

function fixed(value: number, digits = 2): string {
  return value.toFixed(digits);
}

function printTable(reports: readonly BenchmarkReport[]): void {
  console.log(
    "backend".padEnd(19) +
      "dispatch p50".padStart(15) +
      "dispatch p95".padStart(15) +
      "memory".padStart(14) +
      "GiB/s".padStart(11) +
      "compute".padStart(14) +
      "Mops/s".padStart(12),
  );
  for (const report of reports) {
    console.log(
      report.backend.padEnd(19) +
        `${fixed(report.dispatch.median_us)} us`.padStart(15) +
        `${fixed(report.dispatch.p95_us)} us`.padStart(15) +
        `${fixed(report.memory.median_us / 1_000)} ms`.padStart(14) +
        fixed(report.memory.gib_per_s).padStart(11) +
        `${fixed(report.compute.median_us / 1_000)} ms`.padStart(14) +
        fixed(report.compute.mops).padStart(12),
    );
  }
}

async function main(): Promise<void> {
  const config = parseArgs(Deno.args);
  const reports: BenchmarkReport[] = [];
  reports.push(await runNative("./dist/c-bench", "pthread", config));
  reports.push(await runNative("./dist/c-bench", "mmap", config));
  reports.push(await runNative("./dist/rust-bench", "std", config));
  reports.push(await runNative("./dist/rust-bench", "rayon", config));
  reports.push(await runMoonbitSuite({ workerCount: config.workers, quick: config.quick }));
  reports.push(await runMayoSuite({ workerCount: config.workers, quick: config.quick }));
  validateChecksums(reports);

  if (config.json) {
    console.log(JSON.stringify({ config, reports }, null, 2));
    return;
  }
  console.log(
    `warm pools, ${config.workers} workers, shared u32 buffer, startup excluded${
      config.quick ? " (quick)" : ""
    }`,
  );
  console.log(
    config.quick
      ? "memory: 1 MiB, one LCG read-modify-write; compute: 64 KiB, 16 LCG rounds"
      : "memory: 16 MiB, one LCG read-modify-write; compute: 1 MiB, 64 LCG rounds",
  );
  printTable(reports);
  console.log(
    `checksums: memory=${reports[0].memory.checksum}, compute=${reports[0].compute.checksum}`,
  );
}

if (import.meta.main) await main();
