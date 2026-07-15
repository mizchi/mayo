import assert from "node:assert/strict";

import type { BenchmarkReport, ScenarioReport } from "./suite.ts";
import { evaluatePerformance, type PerformanceBudget } from "./regression.ts";

const budget: PerformanceBudget = {
  schema: "mayo.performance-budget/v1",
  max_dispatch_median_us: 100,
  max_dispatch_p95_us: 500,
  max_dispatch_vs_pthread: 5,
  min_memory_vs_pthread: 0.25,
  min_compute_vs_rayon: 0.2,
};

function scenario(
  median_us: number,
  p95_us: number,
  gib_per_s: number,
  mops: number,
): ScenarioReport {
  return {
    elements: 1,
    compute_rounds: 1,
    median_us,
    p95_us,
    gib_per_s,
    mops,
    checksum: 1,
  };
}

function report(
  backend: string,
  dispatchUs: number,
  dispatchP95Us: number,
  memoryGiB: number,
  computeMops: number,
): BenchmarkReport {
  return {
    backend,
    workers: 4,
    dispatch: scenario(dispatchUs, dispatchP95Us, 0, 0),
    memory: scenario(1, 1, memoryGiB, 0),
    compute: scenario(1, 1, 0, computeMops),
  };
}

Deno.test("performance gate accepts portable in-run ratios", () => {
  const failures = evaluatePerformance([
    report("c-pthread", 10, 20, 20, 1_000),
    report("rust-rayon", 20, 40, 18, 2_000),
    report("mayo", 40, 100, 10, 1_000),
    report("mayo-wasm", 30, 80, 12, 1_500),
  ], budget);

  assert.deepEqual(failures, []);
});

Deno.test("performance gate reports each regressed dimension", () => {
  const failures = evaluatePerformance([
    report("c-pthread", 10, 20, 20, 1_000),
    report("rust-rayon", 20, 40, 18, 2_000),
    report("mayo", 101, 501, 4, 399),
    report("mayo-wasm", 20, 40, 10, 1_000),
  ], budget);

  assert.deepEqual(
    failures.map(({ backend, metric }) => ({ backend, metric })),
    [
      { backend: "mayo", metric: "dispatch.median_us" },
      { backend: "mayo", metric: "dispatch.p95_us" },
      { backend: "mayo", metric: "dispatch.vs_pthread" },
      { backend: "mayo", metric: "memory.vs_pthread" },
      { backend: "mayo", metric: "compute.vs_rayon" },
    ],
  );
});
