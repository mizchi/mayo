///|
/// Deno Worker handle kept private behind `Pool`.
#external
priv type HostWorker

///|
/// Deno SharedArrayBuffer handle. Kept private behind `SharedSlice`.
#external
priv type HostSharedArrayBuffer

///|
/// Shared views allocated for one pool.
priv struct HostShared {
  buffer : HostSharedArrayBuffer
  control : SharedInts
  values : SharedSlice
  data_offset : Int
}

///|
extern "js" fn create_host_shared(
  worker_count : Int,
  capacity : Int,
  slot_length : Int,
) -> HostShared =
  #| (workerCount, capacity, slotLength) => {
  #|   const controlElements = workerCount * slotLength;
  #|   const dataOffset = Math.ceil(controlElements / slotLength) * slotLength;
  #|   const buffer = new SharedArrayBuffer(
  #|     (dataOffset + capacity) * Int32Array.BYTES_PER_ELEMENT,
  #|   );
  #|   return {
  #|     buffer,
  #|     control: new Int32Array(buffer, 0, dataOffset),
  #|     values: new Int32Array(
  #|       buffer,
  #|       dataOffset * Int32Array.BYTES_PER_ELEMENT,
  #|       capacity,
  #|     ),
  #|     data_offset: dataOffset,
  #|   };
  #| }

///|
extern "js" fn start_host_worker(
  worker_url : String,
  timeout_ms : Int,
) -> @js_async.Promise[HostWorker] =
  #| (workerUrl, timeoutMs) => new Promise((resolve, reject) => {
  #|   const worker = new Worker(new URL(workerUrl, import.meta.url), { type: "module" });
  #|   const timeout = setTimeout(() => {
  #|     cleanup();
  #|     worker.terminate();
  #|     reject(new Error(`worker startup timed out after ${timeoutMs} ms`));
  #|   }, timeoutMs);
  #|   const onMessage = (event) => {
  #|     if (event.data?.type !== "online") return;
  #|     cleanup();
  #|     resolve(worker);
  #|   };
  #|   const onError = (event) => {
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
  slot_base : Int,
  data_offset : Int,
  timeout_ms : Int,
) -> @js_async.Promise[Unit] =
  #| (worker, id, buffer, slotBase, dataOffset, timeoutMs) =>
  #|   new Promise((resolve, reject) => {
  #|     const timeout = setTimeout(() => {
  #|       cleanup();
  #|       reject(new Error(`worker initialization timed out after ${timeoutMs} ms`));
  #|     }, timeoutMs);
  #|     const onMessage = (event) => {
  #|       if (event.data?.type !== "initialized" || event.data.id !== id) return;
  #|       cleanup();
  #|       resolve(undefined);
  #|     };
  #|     const onError = (event) => {
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
  #|       slotBase,
  #|       dataOffset,
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
