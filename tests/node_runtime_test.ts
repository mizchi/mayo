import assert from "node:assert/strict";

async function expectRuntime(
  runtime: "node" | "bun",
  artifact: string,
  expected: RegExp,
) {
  const output = await new Deno.Command(runtime, {
    args: [artifact],
    stdout: "piped",
    stderr: "piped",
  }).output();
  assert.equal(output.success, true, new TextDecoder().decode(output.stderr));
  assert.match(new TextDecoder().decode(output.stdout), expected);
}

for (const runtime of ["node", "bun"] as const) {
  Deno.test(`prebuilt MoonBit Host and Worker communicate under ${runtime}`, async () => {
    await expectRuntime(runtime, "dist/client_test.js", /MoonBit Mayo client: ok/);
  });

  Deno.test(`shared Wasm guest communicates under ${runtime}`, async () => {
    await expectRuntime(
      runtime,
      "dist/wasm_host.js",
      /MoonBit Wasm zero-copy shared kernel: ok/,
    );
  });
}
