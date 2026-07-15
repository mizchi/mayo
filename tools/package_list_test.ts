import assert from "node:assert/strict";

Deno.test("published module contains runtime packages but not development fixtures", async () => {
  const output = await new Deno.Command("moon", {
    args: ["package", "--list", "--frozen"],
    stdout: "piped",
    stderr: "piped",
  }).output();
  assert.equal(output.success, true, new TextDecoder().decode(output.stderr));
  const decoder = new TextDecoder();
  const files = new Set(
    `${decoder.decode(output.stdout)}\n${decoder.decode(output.stderr)}`.split("\n"),
  );
  for (
    const required of [
      "host_client.mbt",
      "thread_pool.mbt",
      "json/json_contract.mbt",
      "wasm/abi/abi.mbt",
      "wasm/guest_runtime.js",
      "docs/kernel-abi-v4.md",
      "docs/kernel-abi-v4.ja.md",
    ]
  ) {
    assert.equal(files.has(required), true, `package is missing ${required}`);
  }
  for (
    const prefix of [
      ".github/",
      "bench/",
      "examples/",
      "native/",
      "tests/",
      "tools/",
      "worker/",
    ]
  ) {
    assert.equal(
      [...files].some((file) => file.startsWith(prefix)),
      false,
      `package unexpectedly contains ${prefix}`,
    );
  }
  assert.equal(files.has("host_client_wbtest.mbt"), false);
  assert.equal(files.has("mayo.build.json"), false);
});
