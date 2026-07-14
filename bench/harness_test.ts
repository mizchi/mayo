import assert from "node:assert/strict";

import { measureWorkerStartup, runContendedCounter, summarize } from "./harness.ts";

Deno.test("summarize calculates stable percentile statistics", () => {
  assert.deepEqual(summarize([5, 1, 4, 2, 3]), {
    count: 5,
    min: 1,
    median: 3,
    p95: 4.8,
    max: 5,
    mean: 3,
  });
});

Deno.test("prebuilt MoonBit workers update one shared counter under contention", async () => {
  const result = await runContendedCounter({
    workerUrl: new URL("../dist/bench_worker.js", import.meta.url),
    workerCount: 2,
    iterationsPerWorker: 2_000,
  });

  assert.equal(result.finalCounter, 4_000);
  assert.equal(result.expectedCounter, 4_000);
  assert.equal(result.workerOnlineMs.length, 2);
  assert.equal(result.workerExecutionMs.length, 2);
  assert.ok(result.readyWallMs >= 0);
  assert.ok(result.executionWallMs >= 0);
  assert.ok(result.lifecycleWallMs >= result.executionWallMs);
});

Deno.test("worker startup measures constructor-to-online latency", async () => {
  const samples = await measureWorkerStartup(
    new URL("../dist/bench_worker.js", import.meta.url),
    3,
  );

  assert.equal(samples.length, 3);
  assert.ok(samples.every((sample) => Number.isFinite(sample) && sample >= 0));
});
