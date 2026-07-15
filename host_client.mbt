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
/// Policy applied after an uncaught Worker kernel failure.
pub(all) enum RecoveryPolicy {
  PoisonPool
  RestartWorkers
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
  priv recovery : RecoveryPolicy
}

///|
/// Builds options for a pool. `worker_url` is resolved relative to the runtime
/// entry URL (or the browser document URL).
pub fn pool_options(
  worker_url : String,
  capacity~ : Int,
  worker_count? : Int = 4,
  timeout_ms? : Int = 30000,
  recovery? : RecoveryPolicy = PoisonPool,
) -> PoolOptions {
  kernel_pool_options(
    kernel_contract(RANGE_PROTOCOL_ID),
    worker_url,
    capacity~,
    worker_count~,
    timeout_ms~,
    recovery~,
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
  recovery? : RecoveryPolicy = PoisonPool,
) -> PoolOptions {
  {
    worker_url,
    worker_count,
    capacity,
    timeout_ms,
    protocol_id: contract.id_,
    use_wasm_memory: false,
    recovery,
  }
}

///|
/// Builds options for an allocation-free MoonBit/Wasm kernel using shared
/// WebAssembly linear memory. The generic JavaScript Worker glue and Wasm
/// artifact URLs are resolved relative to the runtime entry URL (or the
/// browser document URL).
pub fn wasm_kernel_pool_options(
  contract : KernelContract,
  worker_url : String,
  wasm_url : String,
  capacity~ : Int,
  worker_count? : Int = 4,
  timeout_ms? : Int = 30000,
  recovery? : RecoveryPolicy = PoisonPool,
) -> PoolOptions {
  {
    worker_url: wasm_guest_worker_url(worker_url, wasm_url, contract.id_),
    worker_count,
    capacity,
    timeout_ms,
    protocol_id: contract.id_,
    use_wasm_memory: true,
    recovery,
  }
}

///|
/// Timing and dispatch identifier for one completed batch.
pub(all) struct RunResult {
  epoch : Int
  elapsed_ms : Double
  grain : Int
}

///|
/// Errors raised by pool construction and dispatch.
pub suberror PoolError {
  InvalidArgument(String)
  WorkerFailed(String)
  Timeout(String)
  Closed
  Busy
  Cancelled
}

///|
/// Persistent Web Worker pool for prebuilt MoonBit kernels.
pub struct Pool {
  priv workers : Array[HostWorker]
  priv control : SharedInts
  priv values_ : SharedSlice
  priv protocol_id_ : String
  priv permit : @async.Semaphore
  priv timeout_ms : Int
  priv mut epoch : Int
  priv mut closed : Bool
  priv mut active_epoch : Int
  priv mut cancel_sequence : Int
  priv mut failure : String?
  priv timings : Array[KernelTiming]
  priv worker_url_ : String
  priv recovery_ : RecoveryPolicy
  priv shared_ : HostShared
  priv worker_count_ : Int
  priv worker_weights : Array[Double]
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
  grain : Int
}

///|
/// Historical execution cost kept separately from scheduling state.
priv struct KernelTiming {
  kernel_id : Int
  mut ms_per_item : Double
}

///| Chooses roughly eight initial chunks per Worker, then targets a 100µs

///|
/// chunk once an observed per-item cost is available.
fn choose_auto_grain(length : Int, workers : Int, ms_per_item : Double?) -> Int {
  if length <= 0 {
    return 1
  }
  let maximum = if length % workers == 0 {
    length / workers
  } else {
    length / workers + 1
  }
  let candidate = match ms_per_item {
    Some(cost) if cost > 0.0 => (0.1 / cost).to_int()
    _ => {
      let lanes = workers * 8
      if length % lanes == 0 {
        length / lanes
      } else {
        length / lanes + 1
      }
    }
  }
  if candidate < 1 {
    1
  } else if candidate > maximum {
    maximum
  } else {
    candidate
  }
}

///|
/// Partitions a range by positive relative Worker throughput weights.
fn partition_weighted(
  start : Int,
  end : Int,
  worker_id : Int,
  weights : Array[Double],
) -> WorkRange {
  let mut total = 0.0
  let mut before = 0.0
  for id = 0; id < weights.length(); id = id + 1 {
    let weight = if weights[id] > 0.0 { weights[id] } else { 1.0 }
    total = total + weight
    if id < worker_id {
      before = before + weight
    }
  }
  let own = if weights[worker_id] > 0.0 { weights[worker_id] } else { 1.0 }
  let length = (end - start).to_double()
  let worker_start = start + (length * before / total).to_int()
  let worker_end = if worker_id + 1 == weights.length() {
    end
  } else {
    start + (length * (before + own) / total).to_int()
  }
  { start: worker_start, end: worker_end }
}

///|
fn terminate_workers(workers : Array[HostWorker]) -> Unit {
  for worker in workers {
    worker.terminate()
  }
}

///|
/// Starts a complete Worker set against an existing shared allocation.
async fn launch_workers(
  worker_url : String,
  protocol_id : String,
  worker_count : Int,
  capacity : Int,
  timeout_ms : Int,
  shared : HostShared,
) -> Array[HostWorker] raise PoolError {
  let workers : Array[HostWorker] = []
  for id = 0; id < worker_count; id = id + 1 {
    ignore(id)
    let worker = start_host_worker(worker_url, protocol_id, timeout_ms).wait() catch {
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
      capacity,
      timeout_ms,
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
      timeout_ms,
    ) catch {
      error => {
        terminate_workers(workers)
        raise error
      }
    }
  }
  workers
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

///|
/// Uses blocking initialization on non-browser agents and non-blocking
/// initialization in a browser document.
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
  let workers = launch_workers(
    options.worker_url,
    options.protocol_id,
    options.worker_count,
    options.capacity,
    options.timeout_ms,
    shared,
  )
  let worker_weights = Array::make(options.worker_count, 1.0)
  {
    workers,
    control: shared.control,
    values_: shared.values,
    protocol_id_: options.protocol_id,
    permit: @async.Semaphore(1),
    timeout_ms: options.timeout_ms,
    epoch: 0,
    closed: false,
    active_epoch: 0,
    cancel_sequence: 0,
    failure: None,
    timings: [],
    worker_url_: options.worker_url,
    recovery_: options.recovery,
    shared_: shared,
    worker_count_: options.worker_count,
    worker_weights,
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
  kernel_id? : Int = 0,
  layout_hash? : Int = 0,
  grain? : Int = 0,
) -> PendingRun raise PoolError {
  if self.failure is Some(message) {
    raise PoolError::WorkerFailed(message)
  }
  if self.closed {
    raise PoolError::Closed
  }
  if start < 0 || end < start || end > self.capacity() {
    raise PoolError::InvalidArgument(
      "range [\{start}, \{end}) is outside shared values",
    )
  }
  if grain < 0 {
    raise PoolError::InvalidArgument("grain must not be negative")
  }
  self.epoch = if self.epoch == 2147483647 { 1 } else { self.epoch + 1 }
  let epoch = self.epoch
  self.active_epoch = epoch
  let started_at = performance_now()
  let workers = self.workers.length()
  atomic_store(self.control, CONTROL_WORKER_COUNT, workers)
  for id = 0; id < workers; id = id + 1 {
    let base = id * CONTROL_SLOT_LENGTH
    let range = partition_weighted(start, end, id, self.worker_weights)
    atomic_store(self.control, base + CONTROL_RANGE_START, range.start)
    atomic_store(self.control, base + CONTROL_RANGE_END, range.end)
    atomic_store(self.control, base + CONTROL_ARGUMENT, argument)
    atomic_store(self.control, base + CONTROL_KERNEL_ID, kernel_id)
    atomic_store(self.control, base + CONTROL_LAYOUT_HASH, layout_hash)
    atomic_store(self.control, base + CONTROL_STATUS, KERNEL_STATUS_OK)
    atomic_store(self.control, base + CONTROL_RESULT, 0)
    atomic_store(self.control, base + CONTROL_ELAPSED_US, 0)
    atomic_store(self.control, base + CONTROL_DYNAMIC_CURSOR, range.start)
    atomic_store(self.control, base + CONTROL_GRAIN, grain)
    atomic_store(
      self.control,
      base + CONTROL_CANCEL_BASELINE,
      self.cancel_sequence,
    )
    atomic_store(self.control, base + CONTROL_STOP, 0)
    atomic_store(self.control, base + CONTROL_EPOCH, epoch)
    atomic_notify_one(self.control, base + CONTROL_EPOCH)
  }
  { epoch, started_at, grain }
}

///|
fn Pool::kernel_timing(self : Pool, kernel_id : Int) -> Double? {
  for timing in self.timings {
    if timing.kernel_id == kernel_id {
      return Some(timing.ms_per_item)
    }
  }
  None
}

///|
fn Pool::auto_grain(self : Pool, kernel_id : Int, length : Int) -> Int {
  choose_auto_grain(
    length,
    self.workers.length(),
    self.kernel_timing(kernel_id),
  )
}

///|
fn Pool::record_kernel_timing(
  self : Pool,
  kernel_id : Int,
  length : Int,
  elapsed_ms : Double,
) -> Unit {
  if length <= 0 || elapsed_ms <= 0.0 {
    return
  }
  let observed = elapsed_ms *
    self.workers.length().to_double() /
    length.to_double()
  for timing in self.timings {
    if timing.kernel_id == kernel_id {
      timing.ms_per_item = timing.ms_per_item * 0.75 + observed * 0.25
      return
    }
  }
  self.timings.push({ kernel_id, ms_per_item: observed })
}

///|
fn Pool::record_worker_weights(self : Pool) -> Unit {
  for id = 0; id < self.workers.length(); id = id + 1 {
    let base = id * CONTROL_SLOT_LENGTH
    let length = atomic_load(self.control, base + CONTROL_RANGE_END) -
      atomic_load(self.control, base + CONTROL_RANGE_START)
    let elapsed_us = atomic_load(self.control, base + CONTROL_ELAPSED_US)
    if length > 0 && elapsed_us > 0 {
      let observed = length.to_double() / elapsed_us.to_double()
      self.worker_weights[id] = self.worker_weights[id] * 0.75 + observed * 0.25
    }
  }
}

///|
fn Pool::finish_run(self : Pool, epoch : Int) -> Unit {
  if self.active_epoch == epoch {
    self.active_epoch = 0
  }
}

///|
fn Pool::poison(self : Pool, message : String) -> Unit {
  if self.failure is None {
    self.failure = Some(message)
    self.active_epoch = 0
    terminate_workers(self.workers)
  }
}

///|
async fn Pool::restart_workers(self : Pool) -> Unit raise PoolError {
  terminate_workers(self.workers)
  self.workers.clear()
  self.active_epoch = 0
  let workers = launch_workers(
    self.worker_url_,
    self.protocol_id_,
    self.worker_count_,
    self.capacity(),
    self.timeout_ms,
    self.shared_,
  )
  for worker in workers {
    self.workers.push(worker)
  }
}

///|
async fn Pool::recover_runtime_failure(
  self : Pool,
  message : String,
) -> Unit raise PoolError {
  match self.recovery_ {
    PoisonPool => self.poison(message)
    RestartWorkers =>
      self.restart_workers() catch {
        _ => {
          let recovery_message = "\{message}; Worker restart failed"
          self.poison(recovery_message)
          raise PoolError::WorkerFailed(recovery_message)
        }
      }
  }
}

///|
fn Pool::cancel_active(self : Pool) -> Bool {
  if self.closed || self.failure is Some(_) || self.active_epoch == 0 {
    return false
  }
  self.cancel_sequence = if self.cancel_sequence == 2147483647 {
    1
  } else {
    self.cancel_sequence + 1
  }
  atomic_store(self.control, CONTROL_CANCEL_SEQUENCE, self.cancel_sequence)
  true
}

///|
fn worker_status_message(worker : Int, kernel_id : Int, status : Int) -> String {
  let subject = if kernel_id == 0 {
    "range kernel"
  } else {
    "kernel \{kernel_id}"
  }
  let reason = match status {
    KERNEL_STATUS_UNKNOWN => "unknown kernel id"
    KERNEL_STATUS_LAYOUT_MISMATCH => "kernel layout hash mismatch"
    KERNEL_STATUS_RUNTIME_FAILED => "runtime failure"
    value => "kernel status \{value}"
  }
  "Worker \{worker} failed \{subject}: \{reason}"
}

///|
fn worker_status_error(
  worker : Int,
  kernel_id : Int,
  status : Int,
) -> PoolError {
  if status == KERNEL_STATUS_CANCELLED {
    return PoolError::Cancelled
  }
  PoolError::WorkerFailed(worker_status_message(worker, kernel_id, status))
}

///|
/// Waits for a dispatch while checking every Worker for a runtime failure.
fn Pool::wait_run(self : Pool, epoch : Int) -> Int raise PoolError {
  let deadline = performance_now() + self.timeout_ms.to_double()
  while true {
    let mut pending_index = -1
    for id = 0; id < self.workers.length(); id = id + 1 {
      let base = id * CONTROL_SLOT_LENGTH
      if atomic_load(self.control, base + CONTROL_DONE_EPOCH) == epoch {
        if atomic_load(self.control, base + CONTROL_STATUS) ==
          KERNEL_STATUS_RUNTIME_FAILED {
          return id
        }
      } else if pending_index == -1 {
        pending_index = base + CONTROL_DONE_EPOCH
      }
    }
    if pending_index == -1 {
      return -1
    }
    let remaining = deadline - performance_now()
    if remaining <= 0.0 {
      raise PoolError::Timeout("dispatch epoch \{epoch} did not complete")
    }
    let wait_ms = if remaining < 1.0 { remaining } else { 1.0 }
    let current = atomic_load(self.control, pending_index)
    atomic_wait_timeout(self.control, pending_index, current, wait_ms)
  } nobreak {
    -1
  }
}

///|
async fn Pool::wait_run_async(self : Pool, epoch : Int) -> Int raise PoolError {
  let outcome = atomic_wait_run_async(
    self.control,
    self.workers.length(),
    CONTROL_SLOT_LENGTH,
    CONTROL_DONE_EPOCH,
    CONTROL_STATUS,
    epoch,
    KERNEL_STATUS_RUNTIME_FAILED,
    self.timeout_ms,
  ).wait() catch {
    error => raise PoolError::WorkerFailed(error.to_string())
  }
  if outcome == -2 {
    raise PoolError::Timeout("dispatch epoch \{epoch} did not complete")
  }
  outcome
}

///|
fn Pool::first_failed_status(self : Pool) -> (Int, Int) {
  for id = 0; id < self.workers.length(); id = id + 1 {
    let status = atomic_load(
      self.control,
      id * CONTROL_SLOT_LENGTH + CONTROL_STATUS,
    )
    if status != KERNEL_STATUS_OK {
      return (id, status)
    }
  }
  (-1, KERNEL_STATUS_OK)
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
  defer self.finish_run(pending.epoch)
  let runtime_worker = self.wait_run(pending.epoch)
  if runtime_worker >= 0 {
    let message = "Worker \{runtime_worker} failed range kernel: runtime failure"
    self.poison(message)
    raise PoolError::WorkerFailed(message)
  }
  let (failed_worker, failed_status) = self.first_failed_status()
  if failed_worker >= 0 {
    self.poison(worker_status_message(failed_worker, 0, failed_status))
    raise worker_status_error(failed_worker, 0, failed_status)
  }
  self.record_worker_weights()
  {
    epoch: pending.epoch,
    elapsed_ms: performance_now() - pending.started_at,
    grain: pending.grain,
  }
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
  defer self.finish_run(pending.epoch)
  let runtime_worker = self.wait_run_async(pending.epoch)
  if runtime_worker >= 0 {
    let message = "Worker \{runtime_worker} failed range kernel: runtime failure"
    self.recover_runtime_failure(message)
    raise PoolError::WorkerFailed(message)
  }
  let (failed_worker, failed_status) = self.first_failed_status()
  if failed_worker >= 0 {
    self.recover_runtime_failure(
      worker_status_message(failed_worker, 0, failed_status),
    )
    raise worker_status_error(failed_worker, 0, failed_status)
  }
  self.record_worker_weights()
  {
    epoch: pending.epoch,
    elapsed_ms: performance_now() - pending.started_at,
    grain: pending.grain,
  }
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
