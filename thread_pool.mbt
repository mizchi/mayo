///|
/// One stable kernel identity and argument layout inside a manifest.
pub struct KernelSpec {
  priv id_ : Int
  priv layout_hash_ : Int
}

///|
/// Defines one kernel in a generated manifest. IDs must be positive and layout
/// hashes must be non-zero.
pub fn kernel_spec(id~ : Int, layout_hash~ : Int) -> KernelSpec {
  if id <= 0 {
    abort("kernel id must be positive")
  }
  if layout_hash == 0 {
    abort("kernel layout hash must not be zero")
  }
  { id_: id, layout_hash_: layout_hash }
}

///|
pub fn KernelSpec::id(self : KernelSpec) -> Int {
  self.id_
}

///|
pub fn KernelSpec::layout_hash(self : KernelSpec) -> Int {
  self.layout_hash_
}

///|
/// The complete Host/Guest contract for one prebuilt Worker artifact.
pub struct KernelManifest {
  priv id_ : String
  priv protocol_id_ : String
  priv kernels_ : Array[KernelSpec]
}

///|
extern "js" fn valid_kernel_manifest_id(id : String) -> Bool = "(id) => id.length > 0 && Array.from(id).every((char) => { const code = char.charCodeAt(0); return code >= 0x21 && code <= 0x7e; })"

///|
fn build_kernel_protocol_id(id : String, kernels : Array[KernelSpec]) -> String {
  let result = StringBuilder::new()
  result.write_string(KERNEL_PROTOCOL_PREFIX)
  result.write_string("|")
  result.write_string(id.length().to_string())
  result.write_string(":")
  result.write_string(id)
  result.write_string("|")
  result.write_string(kernels.length().to_string())
  for spec in kernels {
    result.write_string("|")
    result.write_string(spec.id_.to_string())
    result.write_string(":")
    result.write_string(spec.layout_hash_.to_string())
  }
  result.to_string()
}

///|
/// Defines a manifest shared by generated Host descriptors and Guest entries.
/// Kernel specs must be sorted by strictly increasing ID.
pub fn kernel_manifest(
  id : String,
  kernels : Array[KernelSpec],
) -> KernelManifest {
  if !valid_kernel_manifest_id(id) {
    abort("kernel manifest id must be non-empty printable ASCII")
  }
  if kernels.is_empty() {
    abort("kernel manifest must contain at least one spec")
  }
  let mut previous_id = 0
  for spec in kernels {
    if spec.id_ <= previous_id {
      abort("kernel specs must use unique, increasing ids")
    }
    previous_id = spec.id_
  }
  let copied = kernels.copy()
  {
    id_: id,
    protocol_id_: build_kernel_protocol_id(id, copied),
    kernels_: copied,
  }
}

///|
pub fn KernelManifest::id(self : KernelManifest) -> String {
  self.id_
}

///|
/// Builds raw Pool options while retaining the manifest handshake. Most
/// applications should use `ThreadPool::open`; this bridge is for adapters and
/// benchmark harnesses that need direct `Pool` access.
pub fn kernel_manifest_pool_options(
  manifest : KernelManifest,
  worker_url : String,
  capacity~ : Int,
  worker_count? : Int = 4,
  timeout_ms? : Int = 30000,
) -> PoolOptions {
  kernel_pool_options(
    kernel_contract(manifest.protocol_id_),
    worker_url,
    capacity~,
    worker_count~,
    timeout_ms~,
  )
}

///|
fn KernelManifest::contains(self : KernelManifest, spec : KernelSpec) -> Bool {
  for expected in self.kernels_ {
    if expected.id_ == spec.id_ && expected.layout_hash_ == spec.layout_hash_ {
      return true
    }
  }
  false
}

///|
/// An opaque call descriptor for one ahead-of-time kernel.
pub struct KernelCall {
  priv protocol_id_ : String
  priv kernel_id_ : Int
  priv layout_hash_ : Int
  priv argument_ : Int
}

///|
/// Creates a Host call bound to a manifest and one of its kernel specs.
pub fn kernel_call(
  manifest : KernelManifest,
  kernel : KernelSpec,
  argument? : Int = 0,
) -> KernelCall {
  if !manifest.contains(kernel) {
    abort("kernel spec does not belong to manifest")
  }
  {
    protocol_id_: manifest.protocol_id_,
    kernel_id_: kernel.id_,
    layout_hash_: kernel.layout_hash_,
    argument_: argument,
  }
}

///|
/// One Guest implementation bound to a generated kernel spec.
pub struct KernelEntry {
  priv spec_ : KernelSpec
  priv kernel_ : (SharedSlice, Int, Int, Int) -> Unit
}

///|
pub fn kernel_entry(
  spec : KernelSpec,
  kernel : (SharedSlice, Int, Int, Int) -> Unit,
) -> KernelEntry {
  { spec_: spec, kernel_: kernel }
}

///|
/// A Worker-backed logical thread pool using a manifest-bound kernel ABI.
pub struct ThreadPool {
  priv pool : Pool
  priv protocol_id_ : String
}

///|
/// The signed 32-bit shared array owned by a `ThreadPool`.
pub struct SharedI32 {
  priv pool : Pool
  priv protocol_id_ : String
  priv values_ : SharedSlice
}

///|
/// A structured-concurrency scope for spawning data-parallel kernel calls.
pub struct ThreadScope[X] {
  priv pool : Pool
  priv protocol_id_ : String
  priv group : @async.TaskGroup[X]
  priv mut tail : @async.Task[RunResult]?
}

///|
/// A scoped handle for a spawned kernel call.
pub struct JoinHandle {
  priv task : @async.Task[RunResult]
}

///|
fn normalize_pool_error(error : Error) -> PoolError {
  match error {
    PoolError::InvalidArgument(message) => PoolError::InvalidArgument(message)
    PoolError::WorkerFailed(message) => PoolError::WorkerFailed(message)
    PoolError::Timeout(message) => PoolError::Timeout(message)
    PoolError::Closed => PoolError::Closed
    PoolError::Busy => PoolError::Busy
    _ => PoolError::WorkerFailed(error.to_string())
  }
}

///|
fn Pool::resolve_range_end(self : Pool, end : Int) -> Int {
  if end == -1 {
    self.capacity()
  } else {
    end
  }
}

///|
/// Opens a prebuilt JavaScript Worker artifact and verifies its complete kernel
/// manifest before shared memory is initialized.
pub async fn ThreadPool::open(
  manifest : KernelManifest,
  worker_url : String,
  capacity~ : Int,
  workers? : Int = 4,
  timeout_ms? : Int = 30000,
) -> ThreadPool raise PoolError {
  let pool = Pool::create(
    kernel_manifest_pool_options(
      manifest,
      worker_url,
      capacity~,
      worker_count=workers,
      timeout_ms~,
    ),
  )
  { pool, protocol_id_: manifest.protocol_id_ }
}

///|
/// Returns the shared signed 32-bit array visible to every Worker.
pub fn ThreadPool::shared_i32(self : ThreadPool) -> SharedI32 {
  {
    pool: self.pool,
    protocol_id_: self.protocol_id_,
    values_: self.pool.values(),
  }
}

///|
pub fn ThreadPool::worker_count(self : ThreadPool) -> Int {
  self.pool.worker_count()
}

///|
pub fn ThreadPool::capacity(self : ThreadPool) -> Int {
  self.pool.capacity()
}

///|
pub fn ThreadPool::close(self : ThreadPool) -> Unit {
  self.pool.close()
}

///|
/// Runs a kernel over a range without blocking the calling JavaScript agent.
/// Omit `end` to process the full shared array.
pub async fn ThreadPool::par_for(
  self : ThreadPool,
  kernel : KernelCall,
  start? : Int = 0,
  end? : Int = -1,
) -> RunResult raise PoolError {
  self.run_kernel_call(kernel, start~, end~)
}

///|
fn validate_kernel_call(
  protocol_id : String,
  kernel : KernelCall,
) -> Unit raise PoolError {
  if kernel.protocol_id_ != protocol_id {
    raise PoolError::InvalidArgument(
      "kernel call manifest does not match this ThreadPool",
    )
  }
}

///|
fn kernel_status_error(
  worker : Int,
  kernel_id : Int,
  status : Int,
) -> PoolError {
  let reason = match status {
    KERNEL_STATUS_UNKNOWN => "unknown kernel id"
    KERNEL_STATUS_LAYOUT_MISMATCH => "kernel layout hash mismatch"
    value => "kernel status \{value}"
  }
  PoolError::WorkerFailed(
    "Worker \{worker} rejected kernel \{kernel_id}: \{reason}",
  )
}

///|
/// Runs a manifest-bound kernel synchronously through the raw Pool adapter.
/// Browser document main threads must use `ThreadPool::par_for` instead.
pub fn Pool::run_kernel(
  self : Pool,
  kernel : KernelCall,
  end~ : Int,
  start? : Int = 0,
) -> RunResult raise PoolError {
  if is_browser_main_thread() {
    raise PoolError::InvalidArgument(
      "run_kernel cannot block a browser main thread; use ThreadPool::par_for",
    )
  }
  validate_kernel_call(self.protocol_id_, kernel)
  if !self.permit.try_acquire() {
    raise PoolError::Busy
  }
  defer self.permit.release()
  let pending = self.start_run(
    start~,
    end~,
    argument=kernel.argument_,
    kernel_id=kernel.kernel_id_,
    layout_hash=kernel.layout_hash_,
  )
  let mut failed_worker = -1
  let mut failed_status = KERNEL_STATUS_OK
  for id = 0; id < self.workers.length(); id = id + 1 {
    let base = id * CONTROL_SLOT_LENGTH
    wait_for_value(
      self.control,
      base + CONTROL_DONE_EPOCH,
      pending.epoch,
      self.timeout_ms,
    )
    let status = atomic_load(self.control, base + CONTROL_STATUS)
    if status != KERNEL_STATUS_OK && failed_worker == -1 {
      failed_worker = id
      failed_status = status
    }
  }
  if failed_worker != -1 {
    raise kernel_status_error(failed_worker, kernel.kernel_id_, failed_status)
  }
  { epoch: pending.epoch, elapsed_ms: performance_now() - pending.started_at }
}

///|
async fn ThreadPool::run_kernel_call(
  self : ThreadPool,
  kernel : KernelCall,
  start~ : Int,
  end~ : Int,
) -> RunResult raise PoolError {
  validate_kernel_call(self.protocol_id_, kernel)
  self.pool.run_kernel_async(
    start~,
    end=self.pool.resolve_range_end(end),
    kernel_id=kernel.kernel_id_,
    layout_hash=kernel.layout_hash_,
    argument=kernel.argument_,
  )
}

///|
async fn Pool::run_kernel_async(
  self : Pool,
  end~ : Int,
  start~ : Int,
  kernel_id~ : Int,
  layout_hash~ : Int,
  argument~ : Int,
) -> RunResult raise PoolError {
  self.permit.acquire() catch {
    error => raise PoolError::WorkerFailed(error.to_string())
  }
  defer self.permit.release()
  let pending = self.start_run(
    start~,
    end~,
    argument~,
    kernel_id~,
    layout_hash~,
  )
  let mut failed_worker = -1
  let mut failed_status = KERNEL_STATUS_OK
  for id = 0; id < self.workers.length(); id = id + 1 {
    let base = id * CONTROL_SLOT_LENGTH
    wait_for_value_async(
      self.control,
      base + CONTROL_DONE_EPOCH,
      pending.epoch,
      self.timeout_ms,
    )
    let status = atomic_load(self.control, base + CONTROL_STATUS)
    if status != KERNEL_STATUS_OK && failed_worker == -1 {
      failed_worker = id
      failed_status = status
    }
  }
  if failed_worker != -1 {
    raise kernel_status_error(failed_worker, kernel_id, failed_status)
  }
  { epoch: pending.epoch, elapsed_ms: performance_now() - pending.started_at }
}

///|
/// Runs scoped kernel calls. Every spawned call finishes before this function
/// returns, even when its handle is not explicitly joined.
pub async fn[X] ThreadPool::scope(
  self : ThreadPool,
  body : async (ThreadScope[X]) -> X,
) -> X raise PoolError {
  @async.with_task_group(group => {
    body({ pool: self.pool, protocol_id_: self.protocol_id_, group, tail: None })
  }) catch {
    error => raise normalize_pool_error(error)
  }
}

///|
/// Spawns one data-parallel call inside this scope. Calls sharing a pool are
/// admitted in FIFO order and each call partitions its range across all Workers.
pub fn[X] ThreadScope::spawn(
  self : ThreadScope[X],
  kernel : KernelCall,
  start? : Int = 0,
  end? : Int = -1,
) -> JoinHandle {
  let pool = self.pool
  let protocol_id = self.protocol_id_
  let previous = self.tail
  let task = self.group.spawn(allow_failure=true, () => {
    if previous is Some(previous_task) {
      ignore(previous_task.wait()) catch {
        _ => ()
      }
    }
    validate_kernel_call(protocol_id, kernel)
    pool.run_kernel_async(
      start~,
      end=pool.resolve_range_end(end),
      kernel_id=kernel.kernel_id_,
      layout_hash=kernel.layout_hash_,
      argument=kernel.argument_,
    )
  })
  self.tail = Some(task)
  { task, }
}

///|
/// Waits for a scoped kernel call and returns its dispatch result.
pub async fn JoinHandle::join(self : JoinHandle) -> RunResult raise PoolError {
  self.task.wait() catch {
    error => raise normalize_pool_error(error)
  }
}

///|
pub fn SharedI32::length(self : SharedI32) -> Int {
  self.values_.length()
}

///|
pub fn SharedI32::byte_length(self : SharedI32) -> Int {
  self.values_.byte_length()
}

///|
pub fn SharedI32::fill(self : SharedI32, value : Int) -> Unit {
  self.values_.fill(value)
}

///|
pub fn SharedI32::load(self : SharedI32, index : Int) -> Int {
  self.values_.load(index)
}

///|
pub fn SharedI32::store(self : SharedI32, index : Int, value : Int) -> Unit {
  self.values_.store(index, value)
}

///|
/// Runs a kernel over this array without exposing its scheduler range.
pub async fn SharedI32::par_for(
  self : SharedI32,
  kernel : KernelCall,
  start? : Int = 0,
  end? : Int = -1,
) -> RunResult raise PoolError {
  validate_kernel_call(self.protocol_id_, kernel)
  self.pool.run_kernel_async(
    start~,
    end=self.pool.resolve_range_end(end),
    kernel_id=kernel.kernel_id_,
    layout_hash=kernel.layout_hash_,
    argument=kernel.argument_,
  )
}
