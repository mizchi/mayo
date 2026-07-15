import assert from "node:assert/strict";

import { runMayoSuite, runMayoWasmSuite, runMoonbitSuite } from "./suite.ts";

interface NativeReport {
  memory: { checksum: number };
  compute: { checksum: number };
}

async function runNative(executable: string, backend: string): Promise<NativeReport> {
  const output = await new Deno.Command(executable, {
    args: ["--backend", backend, "--workers", "2", "--quick"],
    stdout: "piped",
    stderr: "piped",
  }).output();
  assert.equal(output.success, true, new TextDecoder().decode(output.stderr));
  return JSON.parse(new TextDecoder().decode(output.stdout));
}

Deno.test("all warm pools produce matching shared-buffer checksums", async () => {
  const reports = await Promise.all([
    runNative("./dist/c-bench", "pthread"),
    runNative("./dist/c-bench", "mmap"),
    runNative("./dist/rust-bench", "std"),
    runNative("./dist/rust-bench", "rayon"),
    runMoonbitSuite({ workerCount: 2, quick: true }),
    runMayoSuite({ workerCount: 2, quick: true }),
    runMayoWasmSuite({ workerCount: 2, quick: true }),
  ]);

  assert.equal(new Set(reports.map((report) => report.memory.checksum)).size, 1);
  assert.equal(new Set(reports.map((report) => report.compute.checksum)).size, 1);
});
