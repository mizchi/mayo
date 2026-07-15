///|
/// A versioned contract shared by separately compiled host and kernel bundles.
///
/// The contract describes the layout and meaning of the shared `Int32` data
/// region. Change its identifier whenever that layout or kernel semantics
/// changes incompatibly.
pub struct KernelContract {
  priv id_ : String
}

///|
/// Defines a versioned zero-copy kernel contract.
pub fn kernel_contract(id : String) -> KernelContract {
  { id_: id }
}

///|
/// Returns the identifier checked during the Worker handshake.
pub fn KernelContract::id(self : KernelContract) -> String {
  self.id_
}

///|
/// Configuration for creating a persistent Web Worker pool.
pub struct PoolOptions {
  priv worker_url : String
  priv worker_count : Int
  priv capacity : Int
  priv timeout_ms : Int
  priv protocol_id : String
  priv use_wasm_memory : Bool
}

///|
/// Builds options for a pool. `worker_url` is resolved relative to the
/// generated host module URL.
pub fn pool_options(
  worker_url : String,
  capacity~ : Int,
  worker_count? : Int = 4,
  timeout_ms? : Int = 30000,
) -> PoolOptions {
  kernel_pool_options(
    kernel_contract(RANGE_PROTOCOL_ID),
    worker_url,
    capacity~,
    worker_count~,
    timeout_ms~,
  )
}

///|
/// Builds options for a separately compiled JavaScript kernel.
pub fn kernel_pool_options(
  contract : KernelContract,
  worker_url : String,
  capacity~ : Int,
  worker_count? : Int = 4,
  timeout_ms? : Int = 30000,
) -> PoolOptions {
  {
    worker_url,
    worker_count,
    capacity,
    timeout_ms,
    protocol_id: contract.id_,
    use_wasm_memory: false,
  }
}

///|
/// Builds options for an allocation-free MoonBit/Wasm kernel using shared
/// WebAssembly linear memory. The generic JavaScript Worker glue and Wasm
/// artifact URLs are resolved relative to the generated host module.
pub fn wasm_kernel_pool_options(
  contract : KernelContract,
  worker_url : String,
  wasm_url : String,
  capacity~ : Int,
  worker_count? : Int = 4,
  timeout_ms? : Int = 30000,
) -> PoolOptions {
  {
    worker_url: wasm_guest_worker_url(worker_url, wasm_url, contract.id_),
    worker_count,
    capacity,
    timeout_ms,
    protocol_id: contract.id_,
    use_wasm_memory: true,
  }
}

///|
/// Timing and dispatch identifier for one completed batch.
pub(all) struct RunResult {
  epoch : Int
  elapsed_ms : Double
}

///|
/// Errors raised by pool construction and dispatch.
pub suberror PoolError {
  InvalidArgument(String)
  WorkerFailed(String)
  Timeout(String)
  Closed
  Busy
}

///|
/// Persistent Web Worker pool for prebuilt MoonBit kernels.
pub struct Pool {
  priv workers : Array[HostWorker]
  priv control : SharedInts
  priv values_ : SharedSlice
  priv permit : @async.Semaphore
  priv timeout_ms : Int
  priv mut epoch : Int
  priv mut closed : Bool
}

///|
/// A non-overlapping range assigned to one Worker.
priv struct WorkRange {
  start : Int
  end : Int
}

///|
/// State captured when a batch is dispatched.
priv struct PendingRun {
  epoch : Int
  started_at : Double
}

///|
/// Pure static partitioning kept separate from the dispatch state machine.
fn partition_range(
  start : Int,
  end : Int,
  worker_id : Int,
  worker_count : Int,
) -> WorkRange {
  let length = end - start
  let chunk_length = length / worker_count
  let extra_workers = length % worker_count
  let extra_before = if worker_id < extra_workers {
    worker_id
  } else {
    extra_workers
  }
  let worker_start = start + chunk_length * worker_id + extra_before
  let extra_length = if worker_id < extra_workers { 1 } else { 0 }
  { start: worker_start, end: worker_start + chunk_length + extra_length }
}

///|
fn terminate_workers(workers : Array[HostWorker]) -> Unit {
  for worker in workers {
    worker.terminate()
  }
}

///|
fn wasm_capacity_limit(worker_count : Int) -> Int {
  WASM_MAX_PAGES * WASM_PAGE_WORDS -
  WASM_SHARED_BASE_WORDS -
  worker_count * CONTROL_SLOT_LENGTH
}

///|
fn wait_for_value(
  control : SharedInts,
  index : Int,
  expected : Int,
  timeout_ms : Int,
) -> Unit raise PoolError {
  let deadline = performance_now() + timeout_ms.to_double()
  while atomic_load(control, index) != expected {
    let remaining = deadline - performance_now()
    if remaining <= 0.0 {
      raise PoolError::Timeout(
        "control index \{index} did not reach \{expected}",
      )
    }
    let wait_ms = if remaining < 1.0 { remaining } else { 1.0 }
    let current = atomic_load(control, index)
    atomic_wait_timeout(control, index, current, wait_ms)
  }
}

///|
async fn wait_for_value_async(
  control : SharedInts,
  index : Int,
  expected : Int,
  timeout_ms : Int,
) -> Unit raise PoolError {
  let completed = atomic_wait_async_timeout(
    control, index, expected, timeout_ms,
  ).wait() catch {
    error => raise PoolError::WorkerFailed(error.to_string())
  }
  if !completed {
    raise PoolError::Timeout("control index \{index} did not reach \{expected}")
  }
}

///| Uses blocking initialization on Deno and non-blocking initialization in a

///|
/// browser document.
async fn wait_for_worker_ready(
  control : SharedInts,
  index : Int,
  timeout_ms : Int,
) -> Unit raise PoolError {
  if is_browser_main_thread() {
    wait_for_value_async(control, index, -1, timeout_ms)
  } else {
    wait_for_value(control, index, -1, timeout_ms)
  }
}

///|
/// Starts and initializes all persistent Workers. Any Worker started before a
/// construction failure is terminated.
pub async fn Pool::create(options : PoolOptions) -> Pool raise PoolError {
  if options.worker_count < 1 {
    raise PoolError::InvalidArgument("worker_count must be positive")
  }
  if options.capacity < 0 {
    raise PoolError::InvalidArgument("capacity must be non-negative")
  }
  if options.timeout_ms < 1 {
    raise PoolError::InvalidArgument("timeout_ms must be positive")
  }
  if options.protocol_id.is_empty() {
    raise PoolError::InvalidArgument("kernel contract id must not be empty")
  }
  if options.use_wasm_memory &&
    options.capacity > wasm_capacity_limit(options.worker_count) {
    raise PoolError::InvalidArgument(
      "shared Wasm capacity exceeds the ABI memory limit",
    )
  }
  let shared = create_host_shared(
    options.worker_count,
    options.capacity,
    CONTROL_SLOT_LENGTH,
    options.use_wasm_memory,
    WASM_SHARED_BASE_WORDS,
    WASM_MAX_PAGES,
  )
  let workers : Array[HostWorker] = []
  for id = 0; id < options.worker_count; id = id + 1 {
    ignore(id)
    let worker = start_host_worker(
      options.worker_url,
      options.protocol_id,
      options.timeout_ms,
    ).wait() catch {
      error => {
        terminate_workers(workers)
        raise PoolError::WorkerFailed(error.to_string())
      }
    }
    workers.push(worker)
  }
  for id = 0; id < workers.length(); id = id + 1 {
    initialize_host_worker(
      workers[id],
      id,
      shared.buffer,
      shared.memory,
      shared.control_offset,
      id * CONTROL_SLOT_LENGTH,
      shared.data_offset,
      options.capacity,
      options.timeout_ms,
    ).wait() catch {
      error => {
        terminate_workers(workers)
        raise PoolError::WorkerFailed(error.to_string())
      }
    }
  }
  for id = 0; id < workers.length(); id = id + 1 {
    wait_for_worker_ready(
      shared.control,
      id * CONTROL_SLOT_LENGTH + CONTROL_DONE_EPOCH,
      options.timeout_ms,
    ) catch {
      error => {
        terminate_workers(workers)
        raise error
      }
    }
  }
  {
    workers,
    control: shared.control,
    values_: shared.values,
    permit: @async.Semaphore(1),
    timeout_ms: options.timeout_ms,
    epoch: 0,
    closed: false,
  }
}

///|
/// Returns the number of persistent Workers owned by this pool.
pub fn Pool::worker_count(self : Pool) -> Int {
  self.workers.length()
}

///|
/// Returns the number of signed 32-bit elements in the shared data region.
pub fn Pool::capacity(self : Pool) -> Int {
  self.values_.length()
}

///|
/// Returns the shared data region passed to Worker kernels.
pub fn Pool::values(self : Pool) -> SharedSlice {
  self.values_
}

///|
/// Validates and dispatches one statically partitioned batch.
fn Pool::start_run(
  self : Pool,
  end~ : Int,
  start? : Int = 0,
  argument? : Int = 0,
) -> PendingRun raise PoolError {
  if self.closed {
    raise PoolError::Closed
  }
  if start < 0 || end < start || end > self.capacity() {
    raise PoolError::InvalidArgument(
      "range [\{start}, \{end}) is outside shared values",
    )
  }
  self.epoch = if self.epoch == 2147483647 { 1 } else { self.epoch + 1 }
  let epoch = self.epoch
  let started_at = performance_now()
  let workers = self.workers.length()
  for id = 0; id < workers; id = id + 1 {
    let base = id * CONTROL_SLOT_LENGTH
    let range = partition_range(start, end, id, workers)
    atomic_store(self.control, base + CONTROL_RANGE_START, range.start)
    atomic_store(self.control, base + CONTROL_RANGE_END, range.end)
    atomic_store(self.control, base + CONTROL_ARGUMENT, argument)
    atomic_store(self.control, base + CONTROL_STOP, 0)
    atomic_store(self.control, base + CONTROL_EPOCH, epoch)
    atomic_notify_one(self.control, base + CONTROL_EPOCH)
  }
  { epoch, started_at }
}

///|
/// Runs one statically partitioned batch synchronously.
///
/// Use this on Deno or another JavaScript agent that permits blocking. Browser
/// document main threads must use `run_async`.
pub fn Pool::run(
  self : Pool,
  end~ : Int,
  start? : Int = 0,
  argument? : Int = 0,
) -> RunResult raise PoolError {
  if is_browser_main_thread() {
    raise PoolError::InvalidArgument(
      "run cannot block a browser main thread; use run_async",
    )
  }
  if !self.permit.try_acquire() {
    raise PoolError::Busy
  }
  defer self.permit.release()
  let pending = self.start_run(end~, start~, argument~)
  for id = 0; id < self.workers.length(); id = id + 1 {
    wait_for_value(
      self.control,
      id * CONTROL_SLOT_LENGTH + CONTROL_DONE_EPOCH,
      pending.epoch,
      self.timeout_ms,
    )
  }
  { epoch: pending.epoch, elapsed_ms: performance_now() - pending.started_at }
}

///|
/// Runs one statically partitioned batch without blocking the calling agent.
/// Concurrent calls wait for this pool in FIFO order. This is the host API for
/// browser document main threads.
pub async fn Pool::run_async(
  self : Pool,
  end~ : Int,
  start? : Int = 0,
  argument? : Int = 0,
) -> RunResult raise PoolError {
  self.permit.acquire() catch {
    error => raise PoolError::WorkerFailed(error.to_string())
  }
  defer self.permit.release()
  let pending = self.start_run(end~, start~, argument~)
  for id = 0; id < self.workers.length(); id = id + 1 {
    wait_for_value_async(
      self.control,
      id * CONTROL_SLOT_LENGTH + CONTROL_DONE_EPOCH,
      pending.epoch,
      self.timeout_ms,
    )
  }
  { epoch: pending.epoch, elapsed_ms: performance_now() - pending.started_at }
}

///|
/// Stops every Worker. Calling `close` more than once is safe.
pub fn Pool::close(self : Pool) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for id = 0; id < self.workers.length(); id = id + 1 {
    let base = id * CONTROL_SLOT_LENGTH
    atomic_store(self.control, base + CONTROL_STOP, 1)
    atomic_store(
      self.control,
      base + CONTROL_EPOCH,
      atomic_load(self.control, base + CONTROL_EPOCH) + 1,
    )
    atomic_notify_one(self.control, base + CONTROL_EPOCH)
  }
  terminate_workers(self.workers)
}
