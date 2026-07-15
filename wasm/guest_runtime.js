const moduleUrl = new URL(import.meta.url);
const contractId = moduleUrl.searchParams.get("mayo-contract");
const wasmPath = moduleUrl.searchParams.get("mayo-wasm");

async function instantiateWasm(url, memory) {
  const imports = { env: { memory } };
  if (url.protocol === "file:" && typeof Deno !== "undefined") {
    return await WebAssembly.instantiate(await Deno.readFile(url), imports);
  }
  const response = await fetch(url);
  if (!response.ok) throw new Error(`failed to fetch Wasm kernel: ${response.status}`);
  if (typeof WebAssembly.instantiateStreaming === "function") {
    try {
      return await WebAssembly.instantiateStreaming(response.clone(), imports);
    } catch {
      // Servers without application/wasm still work through the byte fallback.
    }
  }
  return await WebAssembly.instantiate(await response.arrayBuffer(), imports);
}

function requireFunction(exports, name) {
  const value = exports[name];
  if (typeof value !== "function") throw new Error(`Wasm kernel is missing export ${name}`);
  return value;
}

const textEncoder = new TextEncoder();

function fnv1a(text) {
  let hash = 0x811c9dc5 | 0;
  for (const byte of textEncoder.encode(text)) {
    hash = Math.imul(hash ^ byte, 0x01000193);
  }
  return hash | 0;
}

async function initializeKernel(message) {
  if (!(message.memory instanceof WebAssembly.Memory)) {
    throw new Error("Mayo Wasm kernel requires shared WebAssembly.Memory");
  }
  if (!(message.memory.buffer instanceof SharedArrayBuffer)) {
    throw new Error("Mayo Wasm kernel memory is not shared");
  }
  const instantiated = await instantiateWasm(new URL(wasmPath, moduleUrl), message.memory);
  const wasm = instantiated.instance.exports;
  const abiVersion = requireFunction(wasm, "mayo_abi_version");
  const contractHash = requireFunction(wasm, "mayo_contract_hash");
  const run = requireFunction(wasm, "mayo_run");
  if (abiVersion() !== 2) throw new Error(`unsupported Mayo Wasm ABI: ${abiVersion()}`);
  if (contractHash() !== fnv1a(contractId)) {
    throw new Error("Wasm kernel contract does not match the host contract");
  }
  return run;
}

function runWorker(message, run) {
  const shared = new Int32Array(
    message.memory.buffer,
    message.controlOffset * Int32Array.BYTES_PER_ELEMENT,
    message.dataOffset - message.controlOffset,
  );
  let seenEpoch = Atomics.load(shared, message.slotBase);
  Atomics.store(shared, message.slotBase + 1, -1);
  Atomics.notify(shared, message.slotBase + 1, 1);
  globalThis.postMessage({ type: "initialized", id: message.id });
  while (true) {
    while (Atomics.load(shared, message.slotBase) === seenEpoch) {
      Atomics.wait(shared, message.slotBase, seenEpoch);
    }
    seenEpoch = Atomics.load(shared, message.slotBase);
    if (Atomics.load(shared, message.slotBase + 5) !== 0) return;
    const start = Atomics.load(shared, message.slotBase + 2);
    const end = Atomics.load(shared, message.slotBase + 3);
    const argument = Atomics.load(shared, message.slotBase + 4);
    const status = run(
      message.dataOffset,
      message.dataCapacity,
      start,
      end,
      argument,
    );
    if (status !== 0) throw new Error(`Wasm kernel rejected descriptor: ${status}`);
    Atomics.store(shared, message.slotBase + 1, seenEpoch);
    Atomics.notify(shared, message.slotBase + 1, 1);
  }
}

if (!contractId) throw new Error("missing mayo-contract Worker parameter");
if (!wasmPath) throw new Error("missing mayo-wasm Worker parameter");

globalThis.onmessage = async (event) => {
  const message = event.data;
  if (message.type !== "atomic-init") return;
  try {
    const run = await initializeKernel(message);
    runWorker(message, run);
  } catch (error) {
    globalThis.postMessage({
      type: "startup-error",
      message: error instanceof Error ? error.message : String(error),
    });
  }
};

globalThis.postMessage({ type: "online", protocol: contractId });
