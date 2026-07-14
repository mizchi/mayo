import assert from "node:assert/strict";

import { mixReference, MoonbitMessagePool } from "./message_pool.ts";

Deno.test("MoonBit worker pool reuses workers and transforms disjoint shared ranges", async () => {
  const workerUrl = new URL("../dist/bench_worker.js", import.meta.url);
  const shared = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 17);
  const values = new Int32Array(shared);
  for (let index = 0; index < values.length; index += 1) values[index] = index;

  const pool = await MoonbitMessagePool.create(workerUrl, 3, shared);
  try {
    await pool.transform(values.length, 2);
    await pool.transform(values.length, 2);
  } finally {
    pool.close();
  }

  for (let index = 0; index < values.length; index += 1) {
    assert.equal(values[index] >>> 0, mixReference(index, 4));
  }
});

Deno.test("MoonBit worker pool can dispatch an empty batch", async () => {
  const workerUrl = new URL("../dist/bench_worker.js", import.meta.url);
  const shared = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
  const pool = await MoonbitMessagePool.create(workerUrl, 2, shared);
  try {
    await pool.transform(0, 0);
    await pool.transform(0, 0);
  } finally {
    pool.close();
  }
});
