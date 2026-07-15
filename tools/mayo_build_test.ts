import assert from "node:assert/strict";

import { buildPlan, parseBuildConfig } from "./mayo_build.ts";

Deno.test("build config plans descriptor generation and JS/Wasm artifacts", () => {
  const config = parseBuildConfig({
    version: 1,
    schema: "kernels/mayo.kernel.json",
    descriptor: "kernels/kernel.generated.mbt",
    artifacts: [
      { package: "guest/js_worker", target: "js", output: "dist/worker.js" },
      { package: "guest/wasm_worker", target: "wasm", output: "dist/worker.wasm" },
    ],
  });
  assert.deepEqual(buildPlan(config), {
    schema: "kernels/mayo.kernel.json",
    descriptor: "kernels/kernel.generated.mbt",
    artifacts: [
      {
        package: "guest/js_worker",
        target: "js",
        source: "_build/js/release/build/guest/js_worker/js_worker.js",
        output: "dist/worker.js",
      },
      {
        package: "guest/wasm_worker",
        target: "wasm",
        source: "_build/wasm/release/build/guest/wasm_worker/wasm_worker.wasm",
        output: "dist/worker.wasm",
      },
    ],
  });
});

Deno.test("build config rejects paths outside the repository", () => {
  assert.throws(
    () =>
      parseBuildConfig({
        version: 1,
        artifacts: [
          { package: "../guest", target: "js", output: "dist/worker.js" },
        ],
      }),
    /repository-relative/,
  );
});
