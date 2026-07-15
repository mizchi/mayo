import type { BenchmarkReport } from "./suite.ts";

export interface PerformanceBudget {
  schema: "mayo.performance-budget/v1";
  max_dispatch_median_us: number;
  max_dispatch_p95_us: number;
  max_dispatch_vs_pthread: number;
  min_memory_vs_pthread: number;
  min_compute_vs_rayon: number;
  min_wasm_compute_vs_rayon: number;
}

export interface PerformanceFailure {
  backend: string;
  metric: string;
  actual: number;
  limit: number;
}

interface CompareOutput {
  config: { workers: number; quick: boolean; json: boolean };
  reports: BenchmarkReport[];
}

function requireReport(
  reports: readonly BenchmarkReport[],
  backend: string,
): BenchmarkReport {
  const report = reports.find((candidate) => candidate.backend === backend);
  if (report === undefined) throw new Error(`performance report is missing ${backend}`);
  return report;
}

export function evaluatePerformance(
  reports: readonly BenchmarkReport[],
  budget: PerformanceBudget,
): PerformanceFailure[] {
  if (budget.schema !== "mayo.performance-budget/v1") {
    throw new Error(`unsupported performance budget: ${budget.schema}`);
  }
  const pthread = requireReport(reports, "c-pthread");
  const rayon = requireReport(reports, "rust-rayon");
  const failures: PerformanceFailure[] = [];

  for (const backend of ["mayo", "mayo-wasm"]) {
    const report = requireReport(reports, backend);
    const computeFloor = backend === "mayo-wasm"
      ? budget.min_wasm_compute_vs_rayon
      : budget.min_compute_vs_rayon;
    const checks = [
      {
        metric: "dispatch.median_us",
        actual: report.dispatch.median_us,
        limit: budget.max_dispatch_median_us,
        failed: report.dispatch.median_us > budget.max_dispatch_median_us,
      },
      {
        metric: "dispatch.p95_us",
        actual: report.dispatch.p95_us,
        limit: budget.max_dispatch_p95_us,
        failed: report.dispatch.p95_us > budget.max_dispatch_p95_us,
      },
      {
        metric: "dispatch.vs_pthread",
        actual: report.dispatch.median_us / pthread.dispatch.median_us,
        limit: budget.max_dispatch_vs_pthread,
        failed: report.dispatch.median_us / pthread.dispatch.median_us >
          budget.max_dispatch_vs_pthread,
      },
      {
        metric: "memory.vs_pthread",
        actual: report.memory.gib_per_s / pthread.memory.gib_per_s,
        limit: budget.min_memory_vs_pthread,
        failed: report.memory.gib_per_s / pthread.memory.gib_per_s <
          budget.min_memory_vs_pthread,
      },
      {
        metric: "compute.vs_rayon",
        actual: report.compute.mops / rayon.compute.mops,
        limit: computeFloor,
        failed: report.compute.mops / rayon.compute.mops < computeFloor,
      },
    ];
    for (const check of checks) {
      if (check.failed) failures.push({ backend, ...check });
    }
  }
  return failures.map(({ backend, metric, actual, limit }) => ({
    backend,
    metric,
    actual,
    limit,
  }));
}

async function runComparison(workers: number): Promise<CompareOutput> {
  const output = await new Deno.Command(Deno.execPath(), {
    args: [
      "run",
      "--allow-read",
      "--allow-run",
      "bench/compare.ts",
      "--workers",
      String(workers),
      "--quick",
      "--json",
    ],
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!output.success) throw new Error(new TextDecoder().decode(output.stderr));
  return JSON.parse(new TextDecoder().decode(output.stdout)) as CompareOutput;
}

async function main(): Promise<void> {
  let workers = Math.min(4, navigator.hardwareConcurrency || 1);
  let outputPath = "dist/performance-report.json";
  for (let index = 0; index < Deno.args.length; index += 1) {
    switch (Deno.args[index]) {
      case "--workers":
        workers = Number(Deno.args[++index]);
        break;
      case "--output":
        outputPath = Deno.args[++index];
        break;
      default:
        throw new Error(`unknown argument: ${Deno.args[index]}`);
    }
  }
  if (!Number.isSafeInteger(workers) || workers < 1) {
    throw new Error("workers must be a positive integer");
  }

  const budget = JSON.parse(
    await Deno.readTextFile(new URL("./performance_budget.json", import.meta.url)),
  ) as PerformanceBudget;
  const comparison = await runComparison(workers);
  const failures = evaluatePerformance(comparison.reports, budget);
  const artifact = {
    ...comparison,
    performance_budget: budget,
    performance_gate: { passed: failures.length === 0, failures },
  };
  await Deno.writeTextFile(outputPath, `${JSON.stringify(artifact, null, 2)}\n`);

  if (failures.length > 0) {
    const summary = failures.map((failure) =>
      `${failure.backend} ${failure.metric}: ${failure.actual.toFixed(3)} (limit ${failure.limit})`
    ).join("\n");
    throw new Error(`performance budget exceeded:\n${summary}`);
  }
  console.log(`performance budget: ok (${workers} workers; report: ${outputPath})`);
}

if (import.meta.main) await main();
