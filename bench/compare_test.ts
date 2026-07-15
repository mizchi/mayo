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

Deno.test("native and Mayo custom scenarios use the same matrix contract", async () => {
  const scenario = [
    "--elements",
    "1024",
    "--rounds",
    "4",
    "--warmups",
    "1",
    "--batches",
    "2",
  ];
  const commands = [
    ["./dist/c-bench", ["--backend", "pthread", "--workers", "2", ...scenario]],
    ["./dist/c-bench", ["--backend", "mmap", "--workers", "2", ...scenario]],
    ["./dist/rust-bench", ["--backend", "std", "--workers", "2", ...scenario]],
    ["./dist/rust-bench", ["--backend", "rayon", "--workers", "2", ...scenario]],
    [
      Deno.execPath(),
      ["run", "--allow-read", "./dist/mayo_bench.js", "--workers", "2", ...scenario],
    ],
    [
      Deno.execPath(),
      [
        "run",
        "--allow-read",
        "./dist/mayo_bench.js",
        "--workers",
        "2",
        "--wasm",
        ...scenario,
      ],
    ],
  ] as const;
  const reports = await Promise.all(commands.map(async ([command, args]) => {
    const output = await new Deno.Command(command, {
      args: [...args],
      stdout: "piped",
      stderr: "piped",
    }).output();
    assert.equal(output.success, true, new TextDecoder().decode(output.stderr));
    return JSON.parse(new TextDecoder().decode(output.stdout)) as {
      scenario: { checksum: number };
    };
  }));
  assert.equal(new Set(reports.map((report) => report.scenario.checksum)).size, 1);
});
