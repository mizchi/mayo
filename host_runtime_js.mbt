///|
/// Web Worker handle kept private behind `Pool`.
#external
priv type HostWorker

///|
/// JavaScript SharedArrayBuffer handle. Kept private behind `SharedSlice`.
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
  #| async (workerUrl, protocolId, timeoutMs) => {
  #|   const runtimeEntry = globalThis.process?.argv?.[1];
  #|   const runtimeEntryUrl = runtimeEntry
  #|     ? `file://${runtimeEntry.startsWith("/") ? "" : "/"}${runtimeEntry.replaceAll("\\", "/")}`
  #|     : undefined;
  #|   const baseUrl = globalThis.document?.baseURI ??
  #|     globalThis.Deno?.mainModule ?? globalThis.location?.href ?? runtimeEntryUrl ??
  #|     `file://${globalThis.process?.cwd?.() ?? "."}/`;
  #|   const resolvedWorkerUrl = new URL(workerUrl, baseUrl);
  #|   let worker;
  #|   const isBun = typeof globalThis.process?.versions?.bun === "string";
  #|   if (typeof globalThis.Worker === "function") {
  #|     worker = new globalThis.Worker(resolvedWorkerUrl, { type: "module" });
  #|   } else {
  #|     const { Worker: NodeWorker } = await import("node:worker_threads");
  #|     const bootstrap = [
  #|       'import { parentPort, workerData } from "node:worker_threads";',
  #|       'const pending = [];',
  #|       'globalThis.postMessage = (data) => parentPort.postMessage(data);',
  #|       'parentPort.on("message", (data) => {',
  #|       '  if (typeof globalThis.onmessage === "function") globalThis.onmessage({ data });',
  #|       '  else pending.push(data);',
  #|       '});',
  #|       'await import(workerData.moduleUrl);',
  #|       'for (const data of pending) globalThis.onmessage({ data });',
  #|     ].join("\n");
  #|     worker = new NodeWorker(
  #|       new URL(`data:text/javascript,${encodeURIComponent(bootstrap)}`),
  #|       { type: "module", workerData: { moduleUrl: resolvedWorkerUrl.href } },
  #|     );
  #|   }
  #|   return await new Promise((resolve, reject) => {
  #|   const listen = (type, listener) => {
  #|     if (typeof worker.addEventListener === "function") {
  #|       worker.addEventListener(type, listener);
  #|       return () => worker.removeEventListener(type, listener);
  #|     }
  #|     const wrapped = type === "message"
  #|       ? (data) => listener({ data })
  #|       : (error) => listener({ error, message: error?.message });
  #|     worker.on(type, wrapped);
  #|     return () => worker.off(type, wrapped);
  #|   };
  #|   let removeMessage = () => {};
  #|   let removeError = () => {};
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
  #|     removeMessage();
  #|     removeError();
  #|   };
  #|   removeMessage = listen("message", onMessage);
  #|   removeError = listen("error", onError);
  #|   if (isBun && resolvedWorkerUrl.searchParams.has("mayo-contract")) {
  #|     const wasmPath = resolvedWorkerUrl.searchParams.get("mayo-wasm");
  #|     worker.postMessage({
  #|       type: "mayo-wasm-bootstrap",
  #|       contractId: resolvedWorkerUrl.searchParams.get("mayo-contract"),
  #|       wasmUrl: new URL(wasmPath, resolvedWorkerUrl).href,
  #|     });
  #|   }
  #|   });
  #| }

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
  #|     const listen = (type, listener) => {
  #|       if (typeof worker.addEventListener === "function") {
  #|         worker.addEventListener(type, listener);
  #|         return () => worker.removeEventListener(type, listener);
  #|       }
  #|       const wrapped = type === "message"
  #|         ? (data) => listener({ data })
  #|         : (error) => listener({ error, message: error?.message });
  #|       worker.on(type, wrapped);
  #|       return () => worker.off(type, wrapped);
  #|     };
  #|     let removeMessage = () => {};
  #|     let removeError = () => {};
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
  #|       removeMessage();
  #|       removeError();
  #|     };
  #|     removeMessage = listen("message", onMessage);
  #|     removeError = listen("error", onError);
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
  #|   const runtimeEntry = globalThis.process?.argv?.[1];
  #|   const runtimeEntryUrl = runtimeEntry
  #|     ? `file://${runtimeEntry.startsWith("/") ? "" : "/"}${runtimeEntry.replaceAll("\\", "/")}`
  #|     : undefined;
  #|   const baseUrl = globalThis.document?.baseURI ??
  #|     globalThis.Deno?.mainModule ?? globalThis.location?.href ?? runtimeEntryUrl ??
  #|     `file://${globalThis.process?.cwd?.() ?? "."}/`;
  #|   const url = new URL(workerUrl, baseUrl);
  #|   url.searchParams.set("mayo-wasm", wasmUrl);
  #|   url.searchParams.set("mayo-contract", protocolId);
  #|   return url.href;
  #| }

///|
/// Non-blocking wait for browser main threads, with a timer fallback for
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

///|
/// Waits until every Worker completes `epoch`, or returns the first Worker
/// that reports a runtime failure. `-1` means complete and `-2` means timeout.
#borrow(shared)
extern "js" fn atomic_wait_run_async(
  shared : SharedInts,
  worker_count : Int,
  slot_length : Int,
  done_offset : Int,
  status_offset : Int,
  epoch : Int,
  runtime_failed_status : Int,
  timeout_ms : Int,
) -> @js_async.Promise[Int] =
  #| async (
  #|   shared,
  #|   workerCount,
  #|   slotLength,
  #|   doneOffset,
  #|   statusOffset,
  #|   epoch,
  #|   runtimeFailedStatus,
  #|   timeoutMs,
  #| ) => {
  #|   const deadline = performance.now() + timeoutMs;
  #|   const useWaitAsync = typeof document !== "undefined" &&
  #|     typeof Atomics.waitAsync === "function";
  #|   while (true) {
  #|     let pendingIndex = -1;
  #|     for (let id = 0; id < workerCount; id += 1) {
  #|       const base = id * slotLength;
  #|       if (Atomics.load(shared, base + doneOffset) === epoch) {
  #|         if (Atomics.load(shared, base + statusOffset) === runtimeFailedStatus) {
  #|           return id;
  #|         }
  #|       } else if (pendingIndex === -1) {
  #|         pendingIndex = base + doneOffset;
  #|       }
  #|     }
  #|     if (pendingIndex === -1) return -1;
  #|     const remaining = deadline - performance.now();
  #|     if (remaining <= 0) return -2;
  #|     const waitMs = Math.min(remaining, 1);
  #|     const current = Atomics.load(shared, pendingIndex);
  #|     if (useWaitAsync) {
  #|       const wait = Atomics.waitAsync(shared, pendingIndex, current, waitMs);
  #|       if (wait.async) await wait.value;
  #|     } else {
  #|       await new Promise((resolve) => setTimeout(resolve, waitMs));
  #|     }
  #|   }
  #| }
