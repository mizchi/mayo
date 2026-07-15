import { patchSharedMemory } from "../wasm/patch_shared_memory.ts";

function assertEquals<T>(actual: T, expected: T): void {
  if (!Object.is(actual, expected)) {
    throw new Error(`expected ${String(expected)}, received ${String(actual)}`);
  }
}

Deno.test("patchSharedMemory changes an imported memory to shared", async () => {
  const module = new Uint8Array([
    0x00,
    0x61,
    0x73,
    0x6d,
    0x01,
    0x00,
    0x00,
    0x00,
    0x02,
    0x10,
    0x01,
    0x03,
    0x65,
    0x6e,
    0x76,
    0x06,
    0x6d,
    0x65,
    0x6d,
    0x6f,
    0x72,
    0x79,
    0x02,
    0x01,
    0x01,
    0x02,
  ]);

  const patched = patchSharedMemory(module);
  assertEquals(patched[patched.length - 3], 0x03);

  const memory = new WebAssembly.Memory({
    initial: 1,
    maximum: 2,
    shared: true,
  });
  await WebAssembly.instantiate(patched, { env: { memory } });
});

Deno.test("patchSharedMemory rejects modules without env.memory", () => {
  const emptyModule = new Uint8Array([
    0x00,
    0x61,
    0x73,
    0x6d,
    0x01,
    0x00,
    0x00,
    0x00,
  ]);
  let message = "";
  try {
    patchSharedMemory(emptyModule);
  } catch (error) {
    message = error instanceof Error ? error.message : String(error);
  }
  assertEquals(message, "Wasm module does not import env.memory");
});
