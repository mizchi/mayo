const moduleUrl = new URL(import.meta.url);
const contractId = moduleUrl.searchParams.get("mayo-contract");
const wasmPath = moduleUrl.searchParams.get("mayo-wasm");

async function instantiateWasm(url) {
  if (url.protocol === "file:" && typeof Deno !== "undefined") {
    return await WebAssembly.instantiate(await Deno.readFile(url));
  }
  const response = await fetch(url);
  if (!response.ok) throw new Error(`failed to fetch Wasm guest: ${response.status}`);
  if (typeof WebAssembly.instantiateStreaming === "function") {
    try {
      return await WebAssembly.instantiateStreaming(response.clone());
    } catch {
      // Servers without application/wasm still work through the byte fallback.
    }
  }
  return await WebAssembly.instantiate(await response.arrayBuffer());
}

function requireFunction(exports, name) {
  const value = exports[name];
  if (typeof value !== "function") throw new Error(`Wasm guest is missing export ${name}`);
  return value;
}

async function startGuest() {
  if (!contractId) throw new Error("missing mayo-contract Worker parameter");
  if (!wasmPath) throw new Error("missing mayo-wasm Worker parameter");
  const instantiated = await instantiateWasm(new URL(wasmPath, moduleUrl));
  const wasm = instantiated.instance.exports;
  if (!(wasm.memory instanceof WebAssembly.Memory)) {
    throw new Error("Wasm guest is missing exported memory");
  }

  const abiVersion = requireFunction(wasm, "mayo_abi_version");
  const abiCapacity = requireFunction(wasm, "mayo_abi_capacity");
  const contractHash = requireFunction(wasm, "mayo_contract_hash");
  const requestPtr = requireFunction(wasm, "mayo_request_ptr");
  const responsePtr = requireFunction(wasm, "mayo_response_ptr");
  const handle = requireFunction(wasm, "mayo_handle");

  if (abiVersion() !== 1) throw new Error(`unsupported Mayo Wasm ABI: ${abiVersion()}`);

  const textEncoder = new TextEncoder();

  function fnv1a(text) {
    let hash = 0x811c9dc5 | 0;
    for (const byte of textEncoder.encode(text)) {
      hash = Math.imul(hash ^ byte, 0x01000193);
    }
    return hash | 0;
  }

  const contractMatches = contractHash() === fnv1a(contractId);

  function writeResult(values, status, bytes) {
    const payloadCapacity = values.byteLength - 16;
    if (bytes.byteLength > payloadCapacity) {
      values[1] = 0;
      values[2] = -1;
      return;
    }
    new Uint8Array(values.buffer, values.byteOffset + 16, bytes.byteLength).set(bytes);
    values[1] = bytes.byteLength;
    values[2] = status;
  }

  function writeError(values, message) {
    writeResult(values, -1, textEncoder.encode(message));
  }

  function dispatch(values) {
    try {
      const requestLength = values[0];
      const payloadCapacity = values.byteLength - 16;
      const capacity = abiCapacity();
      if (requestLength < 0 || requestLength > payloadCapacity || requestLength > capacity) {
        writeError(values, "request exceeds the Wasm guest ABI capacity");
        return;
      }
      const requestBytes = new Uint8Array(
        values.buffer,
        values.byteOffset + 16,
        requestLength,
      );
      new Uint8Array(wasm.memory.buffer, requestPtr(), requestLength).set(requestBytes);
      const responseLength = handle(requestLength);
      if (responseLength === -1) {
        writeError(values, "request did not match the Wasm guest contract");
        return;
      }
      if (responseLength < -1) {
        writeError(values, `Wasm guest response requires ${-responseLength - 2} bytes`);
        return;
      }
      if (responseLength > capacity) {
        writeError(values, "Wasm guest returned an invalid response length");
        return;
      }
      writeResult(
        values,
        1,
        new Uint8Array(wasm.memory.buffer, responsePtr(), responseLength),
      );
    } catch (error) {
      writeError(values, error instanceof Error ? error.message : String(error));
    }
  }

  function runWorker(shared, slotBase, dataOffset) {
    const values = new Int32Array(
      shared.buffer,
      shared.byteOffset + dataOffset * Int32Array.BYTES_PER_ELEMENT,
      shared.length - dataOffset,
    );
    let seenEpoch = Atomics.load(shared, slotBase);
    Atomics.store(shared, slotBase + 1, -1);
    Atomics.notify(shared, slotBase + 1, 1);
    while (true) {
      while (Atomics.load(shared, slotBase) === seenEpoch) {
        Atomics.wait(shared, slotBase, seenEpoch);
      }
      seenEpoch = Atomics.load(shared, slotBase);
      if (Atomics.load(shared, slotBase + 5) !== 0) return;
      dispatch(values);
      Atomics.store(shared, slotBase + 1, seenEpoch);
      Atomics.notify(shared, slotBase + 1, 1);
    }
  }

  globalThis.onmessage = (event) => {
    const message = event.data;
    if (message.type !== "atomic-init") return;
    const shared = new Int32Array(message.shared);
    globalThis.postMessage({ type: "initialized", id: message.id });
    runWorker(shared, message.slotBase, message.dataOffset);
  };

  globalThis.postMessage({
    type: "online",
    protocol: contractMatches ? contractId : "mayo.wasm.contract-mismatch",
  });
}

try {
  await startGuest();
} catch (error) {
  globalThis.postMessage({
    type: "startup-error",
    message: error instanceof Error ? error.message : String(error),
  });
}
