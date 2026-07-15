///|
/// Web Worker handle kept private behind `Pool`.
#external
priv type HostWorker

///|
/// Deno SharedArrayBuffer handle. Kept private behind `SharedSlice`.
#external
priv type HostSharedArrayBuffer

///|
/// Optional shared WebAssembly memory. JavaScript Workers ignore this value.
#external
priv type HostWasmMemory

///|
/// Shared views allocated for one pool.
priv struct HostShared {
  buffer : HostSharedArrayBuffer
  memory : HostWasmMemory
  control : SharedInts
  values : SharedSlice
  control_offset : Int
  data_offset : Int
}

///|
extern "js" fn create_host_shared(
  worker_count : Int,
  capacity : Int,
  slot_length : Int,
  use_wasm_memory : Bool,
  wasm_shared_base : Int,
  wasm_max_pages : Int,
) -> HostShared =
  #| (workerCount, capacity, slotLength, useWasmMemory, wasmSharedBase, wasmMaxPages) => {
  #|   const controlElements = workerCount * slotLength;
  #|   const sharedBase = useWasmMemory ? wasmSharedBase : 0;
  #|   const dataOffset = sharedBase +
  #|     Math.ceil(controlElements / slotLength) * slotLength;
  #|   const requiredBytes =
  #|     (dataOffset + capacity) * Int32Array.BYTES_PER_ELEMENT;
  #|   const pageBytes = 64 * 1024;
  #|   const pages = Math.ceil(requiredBytes / pageBytes);
  #|   if (useWasmMemory && pages > wasmMaxPages) {
  #|     throw new Error(`shared Wasm pool exceeds the ${wasmMaxPages}-page ABI limit`);
  #|   }
  #|   const memory = useWasmMemory
  #|     ? new WebAssembly.Memory({
  #|       initial: Math.max(64, pages),
  #|       maximum: wasmMaxPages,
  #|       shared: true,
  #|     })
  #|     : undefined;
  #|   const buffer = memory?.buffer ?? new SharedArrayBuffer(requiredBytes);
  #|   return {
  #|     buffer,
  #|     memory,
  #|     control: new Int32Array(
  #|       buffer,
  #|       sharedBase * Int32Array.BYTES_PER_ELEMENT,
  #|       dataOffset - sharedBase,
  #|     ),
  #|     values: new Int32Array(
  #|       buffer,
  #|       dataOffset * Int32Array.BYTES_PER_ELEMENT,
  #|       capacity,
  #|     ),
  #|     control_offset: sharedBase,
  #|     data_offset: dataOffset,
  #|   };
  #| }

///|
extern "js" fn start_host_worker(
  worker_url : String,
  protocol_id : String,
  timeout_ms : Int,
) -> @js_async.Promise[HostWorker] =
  #| (workerUrl, protocolId, timeoutMs) => new Promise((resolve, reject) => {
  #|   const baseUrl = globalThis.document?.baseURI ??
  #|     globalThis.Deno?.mainModule ?? globalThis.location?.href ??
  #|     `file://${globalThis.process?.cwd?.() ?? "."}/`;
  #|   const worker = new Worker(new URL(workerUrl, baseUrl), { type: "module" });
  #|   const timeout = setTimeout(() => {
  #|     cleanup();
  #|     worker.terminate();
  #|     reject(new Error(`worker startup timed out after ${timeoutMs} ms`));
  #|   }, timeoutMs);
  #|   const onMessage = (event) => {
  #|     if (event.data?.type === "startup-error") {
  #|       cleanup();
  #|       worker.terminate();
  #|       reject(new Error(event.data.message ?? "worker startup failed"));
  #|       return;
  #|     }
  #|     if (event.data?.type !== "online") return;
  #|     if (event.data.protocol !== protocolId) {
  #|       cleanup();
  #|       worker.terminate();
  #|       reject(new Error(
  #|         `worker contract mismatch: expected ${protocolId}, received ${String(event.data.protocol)}`,
  #|       ));
  #|       return;
  #|     }
  #|     cleanup();
  #|     resolve(worker);
  #|   };
  #|   const onError = (event) => {
  #|     event.preventDefault?.();
  #|     cleanup();
  #|     worker.terminate();
  #|     reject(event.error instanceof Error ? event.error : new Error(event.message));
  #|   };
  #|   const cleanup = () => {
  #|     clearTimeout(timeout);
  #|     worker.removeEventListener("message", onMessage);
  #|     worker.removeEventListener("error", onError);
  #|   };
  #|   worker.addEventListener("message", onMessage);
  #|   worker.addEventListener("error", onError);
  #| })

///|
#borrow(worker, buffer)
extern "js" fn initialize_host_worker(
  worker : HostWorker,
  id : Int,
  buffer : HostSharedArrayBuffer,
  memory : HostWasmMemory,
  control_offset : Int,
  slot_base : Int,
  data_offset : Int,
  data_capacity : Int,
  timeout_ms : Int,
) -> @js_async.Promise[Unit] =
  #| (worker, id, buffer, memory, controlOffset, slotBase, dataOffset, dataCapacity, timeoutMs) =>
  #|   new Promise((resolve, reject) => {
  #|     const timeout = setTimeout(() => {
  #|       cleanup();
  #|       reject(new Error(`worker initialization timed out after ${timeoutMs} ms`));
  #|     }, timeoutMs);
  #|     const onMessage = (event) => {
  #|       if (event.data?.type === "startup-error") {
  #|         cleanup();
  #|         reject(new Error(event.data.message ?? "worker initialization failed"));
  #|         return;
  #|       }
  #|       if (event.data?.type !== "initialized" || event.data.id !== id) return;
  #|       cleanup();
  #|       resolve(undefined);
  #|     };
  #|     const onError = (event) => {
  #|       event.preventDefault?.();
  #|       cleanup();
  #|       reject(event.error instanceof Error ? event.error : new Error(event.message));
  #|     };
  #|     const cleanup = () => {
  #|       clearTimeout(timeout);
  #|       worker.removeEventListener("message", onMessage);
  #|       worker.removeEventListener("error", onError);
  #|     };
  #|     worker.addEventListener("message", onMessage);
  #|     worker.addEventListener("error", onError);
  #|     worker.postMessage({
  #|       type: "atomic-init",
  #|       id,
  #|       shared: buffer,
  #|       memory,
  #|       controlOffset,
  #|       slotBase,
  #|       dataOffset,
  #|       dataCapacity,
  #|     });
  #|   })

///|
#borrow(self)
extern "js" fn HostWorker::terminate(self : HostWorker) -> Unit = "(self) => self.terminate()"

///|
extern "js" fn performance_now() -> Double = "() => performance.now()"

///|
#borrow(shared)
extern "js" fn atomic_wait_timeout(
  shared : SharedInts,
  index : Int,
  expected : Int,
  timeout_ms : Double,
) -> Unit = "(shared, index, expected, timeoutMs) => { Atomics.wait(shared, index, expected, timeoutMs); }"

///|
/// Whether the current JavaScript agent is a browser document main thread.
extern "js" fn is_browser_main_thread() -> Bool = "() => typeof document !== 'undefined'"

///|
/// Builds an absolute generic Wasm guest URL and carries startup parameters in
/// its query string. The glue resolves `wasm_url` relative to itself.
extern "js" fn wasm_guest_worker_url(
  worker_url : String,
  wasm_url : String,
  protocol_id : String,
) -> String =
  #| (workerUrl, wasmUrl, protocolId) => {
  #|   const baseUrl = globalThis.document?.baseURI ??
  #|     globalThis.Deno?.mainModule ?? globalThis.location?.href ??
  #|     `file://${globalThis.process?.cwd?.() ?? "."}/`;
  #|   const url = new URL(workerUrl, baseUrl);
  #|   url.searchParams.set("mayo-wasm", wasmUrl);
  #|   url.searchParams.set("mayo-contract", protocolId);
  #|   return url.href;
  #| }

///| Non-blocking wait for browser main threads, with a timer fallback for

///|
/// runtimes that do not expose `Atomics.waitAsync`.
#borrow(shared)
extern "js" fn atomic_wait_async_timeout(
  shared : SharedInts,
  index : Int,
  expected : Int,
  timeout_ms : Int,
) -> @js_async.Promise[Bool] =
  #| async (shared, index, expected, timeoutMs) => {
  #|   const deadline = performance.now() + timeoutMs;
  #|   const useWaitAsync = typeof document !== "undefined" &&
  #|     typeof Atomics.waitAsync === "function";
  #|   while (Atomics.load(shared, index) !== expected) {
  #|     const remaining = deadline - performance.now();
  #|     if (remaining <= 0) return false;
  #|     const current = Atomics.load(shared, index);
  #|     if (useWaitAsync) {
  #|       const wait = Atomics.waitAsync(shared, index, current, remaining);
  #|       const outcome = wait.async ? await wait.value : wait.value;
  #|       if (outcome === "timed-out" && Atomics.load(shared, index) !== expected) {
  #|         return false;
  #|       }
  #|     } else {
  #|       await new Promise((resolve) => setTimeout(resolve, Math.min(remaining, 1)));
  #|     }
  #|   }
  #|   return true;
  #| }
