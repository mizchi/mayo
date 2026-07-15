import assert from "node:assert/strict";

import { classifyBreakEven, scenarioGrid } from "./break_even.ts";

Deno.test("break-even grid keeps dispatch and compute cases deterministic", () => {
  assert.deepEqual(scenarioGrid(true), [
    { elements: 0, computeRounds: 0, warmups: 10, batches: 100 },
    { elements: 1_024, computeRounds: 1, warmups: 3, batches: 30 },
    { elements: 1_024, computeRounds: 16, warmups: 3, batches: 30 },
    { elements: 65_536, computeRounds: 1, warmups: 3, batches: 10 },
    { elements: 65_536, computeRounds: 16, warmups: 3, batches: 3 },
  ]);
});

Deno.test("break-even classification finds the first winning workload", () => {
  assert.deepEqual(
    classifyBreakEven([
      { operations: 0, serialUs: 2, parallelUs: 20 },
      { operations: 1_024, serialUs: 15, parallelUs: 22 },
      { operations: 16_384, serialUs: 90, parallelUs: 40 },
      { operations: 1_048_576, serialUs: 2_000, parallelUs: 600 },
    ]),
    { operations: 16_384, speedup: 2.25 },
  );
  assert.equal(
    classifyBreakEven([{ operations: 1, serialUs: 1, parallelUs: 2 }]),
    undefined,
  );
});
