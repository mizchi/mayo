import assert from "node:assert/strict";

const wasmUrl = new URL(
  "../_build/wasm/release/build/examples/wasm_guest/wasm_guest.wasm",
  import.meta.url,
);

Deno.test("MoonBit emits a shared env.memory import without binary rewriting", async () => {
  const bytes = await Deno.readFile(wasmUrl);
  const shared = new WebAssembly.Memory({
    initial: 64,
    maximum: 512,
    shared: true,
  });
  await WebAssembly.instantiate(bytes, { env: { memory: shared } });

  const unshared = new WebAssembly.Memory({ initial: 64, maximum: 512 });
  await assert.rejects(
    WebAssembly.instantiate(bytes, { env: { memory: unshared } }),
    WebAssembly.LinkError,
  );
});
