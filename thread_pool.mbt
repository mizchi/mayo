///|
/// One stable kernel identity and argument layout inside a manifest.
pub struct KernelSpec {
  priv id_ : Int
  priv layout_hash_ : Int
  priv kind_ : Int
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
  { id_: id, layout_hash_: layout_hash, kind_: 0 }
}

///|
/// Defines one reduction kernel in a generated manifest.
pub fn reducer_spec(id~ : Int, layout_hash~ : Int) -> KernelSpec {
  if id <= 0 {
    abort("kernel id must be positive")
  }
  if layout_hash == 0 {
    abort("kernel layout hash must not be zero")
  }
  { id_: id, layout_hash_: layout_hash, kind_: 1 }
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
    result.write_string(":")
    result.write_string(spec.kind_.to_string())
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
  recovery? : RecoveryPolicy = PoisonPool,
) -> PoolOptions {
  kernel_pool_options(
    kernel_contract(manifest.protocol_id_),
    worker_url,
    capacity~,
    worker_count~,
    timeout_ms~,
    recovery~,
  )
}

///|
fn KernelManifest::contains(self : KernelManifest, spec : KernelSpec) -> Bool {
  for expected in self.kernels_ {
    if expected.id_ == spec.id_ &&
      expected.layout_hash_ == spec.layout_hash_ &&
      expected.kind_ == spec.kind_ {
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
/// An opaque call descriptor for one ahead-of-time reduction kernel.
pub struct ReducerCall {
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
  if kernel.kind_ != 0 {
    abort("reduction specs must use reducer_call")
  }
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
/// Creates a Host reduction call bound to a manifest reducer spec.
pub fn reducer_call(
  manifest : KernelManifest,
  reducer : KernelSpec,
  argument? : Int = 0,
) -> ReducerCall {
  if !manifest.contains(reducer) {
    abort("reducer spec does not belong to manifest")
  }
  if reducer.kind_ != 1 {
    abort("map specs must use kernel_call")
  }
  {
    protocol_id_: manifest.protocol_id_,
    kernel_id_: reducer.id_,
    layout_hash_: reducer.layout_hash_,
    argument_: argument,
  }
}

///|
/// One Guest implementation bound to a generated kernel spec.
pub struct KernelEntry {
  priv spec_ : KernelSpec
  priv kernel_ : (SharedSlice, Int, Int, Int) -> Int
}

///|
pub fn kernel_entry(
  spec : KernelSpec,
  kernel : (SharedSlice, Int, Int, Int) -> Unit,
) -> KernelEntry {
  if spec.kind_ != 0 {
    abort("reduction specs must use reducer_entry")
  }
  {
    spec_: spec,
    kernel_: fn(values, start, end, argument) {
      kernel(values, start, end, argument)
      0
    },
  }
}

///|
/// Binds a reduction implementation to a generated reducer spec.
pub fn reducer_entry(
  spec : KernelSpec,
  reducer : (SharedSlice, Int, Int, Int) -> Int,
) -> KernelEntry {
  if spec.kind_ != 1 {
    abort("map specs must use kernel_entry")
  }
  { spec_: spec, kernel_: reducer }
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
/// A monotonic allocator over one pool-owned shared Int32 buffer.
pub struct SharedArena {
  priv values_ : SharedI32
  priv mut cursor_ : Int
}

///|
/// A non-overlapping relative view allocated from `SharedArena`.
pub struct SharedRegion {
  priv values_ : SharedI32
  priv offset_ : Int
  priv length_ : Int
}

///|
/// Equal-sized scratch regions reserved for each Worker.
pub struct WorkerScratch {
  priv region_ : SharedRegion
  priv workers_ : Int
  priv words_per_worker_ : Int
}

///|
/// Pure reservation logic kept separate from arena state.
fn reserve_region(cursor : Int, length : Int, capacity : Int) -> (Int, Int)? {
  if cursor < 0 || length < 0 || cursor > capacity || length > capacity - cursor {
    None
  } else {
    Some((cursor, cursor + length))
  }
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
/// Result of a deterministic two-stage signed 32-bit reduction.
pub(all) struct ReduceResult {
  value : Int
  epoch : Int
  elapsed_ms : Double
}

///|
fn normalize_pool_error(error : Error) -> PoolError {
  match error {
    PoolError::InvalidArgument(message) => PoolError::InvalidArgument(message)
    PoolError::WorkerFailed(message) => PoolError::WorkerFailed(message)
    PoolError::Timeout(message) => PoolError::Timeout(message)
    PoolError::Closed => PoolError::Closed
    PoolError::Busy => PoolError::Busy
    PoolError::Cancelled => PoolError::Cancelled
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
  recovery? : RecoveryPolicy = PoisonPool,
) -> ThreadPool raise PoolError {
  let pool = Pool::create(
    kernel_manifest_pool_options(
      manifest,
      worker_url,
      capacity~,
      worker_count=workers,
      timeout_ms~,
      recovery~,
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

///| Creates a fresh monotonic arena over the complete shared buffer.

///|
/// Allocate layouts before dispatching kernels that use them.
pub fn ThreadPool::arena(self : ThreadPool) -> SharedArena {
  { values_: self.shared_i32(), cursor_: 0 }
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
/// Requests cooperative cancellation of the active dynamic dispatch.
/// Static `par_for` kernels run to completion and ignore this request.
pub fn ThreadPool::cancel_current(self : ThreadPool) -> Bool {
  self.pool.cancel_active()
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
  self.run_kernel_call(kernel, start~, end~, grain=0)
}

///|
/// Runs a kernel through Worker-local shard cursors. Workers repeatedly claim
/// chunks from their own and then other Worker shards until the range is
/// exhausted.
pub async fn ThreadPool::par_chunks(
  self : ThreadPool,
  kernel : KernelCall,
  grain? : Int = 0,
  start? : Int = 0,
  end? : Int = -1,
) -> RunResult raise PoolError {
  if grain < 0 {
    raise PoolError::InvalidArgument("grain must not be negative")
  }
  self.run_kernel_call(
    kernel,
    start~,
    end~,
    grain=if grain == 0 { -1 } else { grain },
  )
}

///| Runs one reduction kernel per static Worker range, then combines partial

///|
/// results on the Host in ascending Worker ID order.
pub async fn ThreadPool::par_reduce(
  self : ThreadPool,
  reducer : ReducerCall,
  init~ : Int,
  combine~ : (Int, Int) -> Int,
  start? : Int = 0,
  end? : Int = -1,
) -> ReduceResult raise PoolError {
  validate_reducer_call(self.protocol_id_, reducer)
  self.pool.run_reducer_async(
    reducer,
    init~,
    combine~,
    start~,
    end=self.pool.resolve_range_end(end),
  )
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
fn validate_reducer_call(
  protocol_id : String,
  reducer : ReducerCall,
) -> Unit raise PoolError {
  if reducer.protocol_id_ != protocol_id {
    raise PoolError::InvalidArgument(
      "reducer call manifest does not match this ThreadPool",
    )
  }
}

///|
/// Runs a manifest-bound kernel synchronously through the raw Pool adapter.
/// Browser document main threads must use `ThreadPool::par_for` instead.
pub fn Pool::run_kernel(
  self : Pool,
  kernel : KernelCall,
  end~ : Int,
  start? : Int = 0,
  grain? : Int = 0,
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
    grain~,
  )
  defer self.finish_run(pending.epoch)
  let runtime_worker = self.wait_run(pending.epoch)
  if runtime_worker >= 0 {
    let message = "Worker \{runtime_worker} failed kernel \{kernel.kernel_id_}: runtime failure"
    self.poison(message)
    raise PoolError::WorkerFailed(message)
  }
  let (failed_worker, failed_status) = self.first_failed_status()
  if failed_worker >= 0 {
    raise worker_status_error(failed_worker, kernel.kernel_id_, failed_status)
  }
  if pending.grain == 0 {
    self.record_worker_weights()
  }
  {
    epoch: pending.epoch,
    elapsed_ms: performance_now() - pending.started_at,
    grain: pending.grain,
  }
}

///|
async fn ThreadPool::run_kernel_call(
  self : ThreadPool,
  kernel : KernelCall,
  start~ : Int,
  end~ : Int,
  grain~ : Int,
) -> RunResult raise PoolError {
  validate_kernel_call(self.protocol_id_, kernel)
  self.pool.run_kernel_async(
    start~,
    end=self.pool.resolve_range_end(end),
    kernel_id=kernel.kernel_id_,
    layout_hash=kernel.layout_hash_,
    argument=kernel.argument_,
    grain~,
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
  grain~ : Int,
) -> RunResult raise PoolError {
  self.permit.acquire() catch {
    error => raise PoolError::WorkerFailed(error.to_string())
  }
  defer self.permit.release()
  if grain < -1 {
    raise PoolError::InvalidArgument("grain must not be negative")
  }
  let resolved_grain = if grain == -1 {
    self.auto_grain(kernel_id, end - start)
  } else {
    grain
  }
  let pending = self.start_run(
    start~,
    end~,
    argument~,
    kernel_id~,
    layout_hash~,
    grain=resolved_grain,
  )
  defer self.finish_run(pending.epoch)
  let runtime_worker = self.wait_run_async(pending.epoch)
  if runtime_worker >= 0 {
    let message = "Worker \{runtime_worker} failed kernel \{kernel_id}: runtime failure"
    self.recover_runtime_failure(message)
    raise PoolError::WorkerFailed(message)
  }
  let (failed_worker, failed_status) = self.first_failed_status()
  if failed_worker >= 0 {
    raise worker_status_error(failed_worker, kernel_id, failed_status)
  }
  let elapsed_ms = performance_now() - pending.started_at
  if resolved_grain > 0 {
    self.record_kernel_timing(kernel_id, end - start, elapsed_ms)
  } else {
    self.record_worker_weights()
  }
  { epoch: pending.epoch, elapsed_ms, grain: resolved_grain }
}

///|
async fn Pool::run_reducer_async(
  self : Pool,
  reducer : ReducerCall,
  init~ : Int,
  combine~ : (Int, Int) -> Int,
  start~ : Int,
  end~ : Int,
) -> ReduceResult raise PoolError {
  validate_reducer_call(self.protocol_id_, reducer)
  self.permit.acquire() catch {
    error => raise PoolError::WorkerFailed(error.to_string())
  }
  defer self.permit.release()
  let pending = self.start_run(
    start~,
    end~,
    argument=reducer.argument_,
    kernel_id=reducer.kernel_id_,
    layout_hash=reducer.layout_hash_,
    grain=0,
  )
  defer self.finish_run(pending.epoch)
  let runtime_worker = self.wait_run_async(pending.epoch)
  if runtime_worker >= 0 {
    let message = "Worker \{runtime_worker} failed reducer \{reducer.kernel_id_}: runtime failure"
    self.recover_runtime_failure(message)
    raise PoolError::WorkerFailed(message)
  }
  let (failed_worker, failed_status) = self.first_failed_status()
  if failed_worker >= 0 {
    raise worker_status_error(failed_worker, reducer.kernel_id_, failed_status)
  }
  self.record_worker_weights()
  let mut value = init
  for id = 0; id < self.workers.length(); id = id + 1 {
    let base = id * CONTROL_SLOT_LENGTH
    let worker_start = atomic_load(self.control, base + CONTROL_RANGE_START)
    let worker_end = atomic_load(self.control, base + CONTROL_RANGE_END)
    if worker_start < worker_end {
      value = combine(value, atomic_load(self.control, base + CONTROL_RESULT))
    }
  }
  {
    value,
    epoch: pending.epoch,
    elapsed_ms: performance_now() - pending.started_at,
  }
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
      grain=0,
    )
  })
  self.tail = Some(task)
  { task, }
}

///|
/// Spawns a dynamically scheduled call. Cancellation is observed between
/// claimed chunks, so `grain` is also the cancellation granularity.
pub fn[X] ThreadScope::spawn_chunks(
  self : ThreadScope[X],
  kernel : KernelCall,
  grain? : Int = 0,
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
    if grain < 0 {
      raise PoolError::InvalidArgument("grain must not be negative")
    }
    validate_kernel_call(protocol_id, kernel)
    pool.run_kernel_async(
      start~,
      end=pool.resolve_range_end(end),
      kernel_id=kernel.kernel_id_,
      layout_hash=kernel.layout_hash_,
      argument=kernel.argument_,
      grain=if grain == 0 { -1 } else { grain },
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
/// Returns the complete shared buffer used by generated layout headers.
pub fn SharedArena::shared_i32(self : SharedArena) -> SharedI32 {
  self.values_
}

///|
pub fn SharedArena::capacity(self : SharedArena) -> Int {
  self.values_.length()
}

///|
pub fn SharedArena::remaining(self : SharedArena) -> Int {
  self.capacity() - self.cursor_
}

///|
/// Resets allocation state without modifying shared data.
pub fn SharedArena::reset(self : SharedArena) -> Unit {
  self.cursor_ = 0
}

///|
/// Allocates one non-overlapping region.
pub fn SharedArena::allocate(
  self : SharedArena,
  length~ : Int,
) -> SharedRegion raise PoolError {
  match reserve_region(self.cursor_, length, self.capacity()) {
    Some((offset, next)) => {
      self.cursor_ = next
      { values_: self.values_, offset_: offset, length_: length }
    }
    None =>
      raise PoolError::InvalidArgument(
        "shared arena cannot allocate \{length} words with \{self.remaining()} remaining",
      )
  }
}

///|
/// Allocates one fixed-size scratch region per Worker.
pub fn SharedArena::allocate_worker_scratch(
  self : SharedArena,
  workers~ : Int,
  words_per_worker~ : Int,
) -> WorkerScratch raise PoolError {
  if workers <= 0 ||
    words_per_worker < 0 ||
    (words_per_worker > 0 && workers > 2147483647 / words_per_worker) {
    raise PoolError::InvalidArgument("invalid Worker scratch dimensions")
  }
  let region = self.allocate(length=workers * words_per_worker)
  { region_: region, workers_: workers, words_per_worker_: words_per_worker }
}

///|
pub fn WorkerScratch::worker_offset(self : WorkerScratch, worker : Int) -> Int {
  if worker < 0 || worker >= self.workers_ {
    abort("Worker scratch index is outside the pool")
  }
  self.region_.offset_ + worker * self.words_per_worker_
}

///|
pub fn WorkerScratch::words_per_worker(self : WorkerScratch) -> Int {
  self.words_per_worker_
}

///|
pub fn WorkerScratch::worker_region(
  self : WorkerScratch,
  worker : Int,
) -> SharedRegion {
  {
    values_: self.region_.values_,
    offset_: self.worker_offset(worker),
    length_: self.words_per_worker_,
  }
}

///|
pub fn SharedRegion::offset(self : SharedRegion) -> Int {
  self.offset_
}

///|
pub fn SharedRegion::length(self : SharedRegion) -> Int {
  self.length_
}

///|
fn SharedRegion::absolute_index(self : SharedRegion, index : Int) -> Int {
  if index < 0 || index >= self.length_ {
    abort("shared region index is outside its allocation")
  }
  self.offset_ + index
}

///|
pub fn SharedRegion::load(self : SharedRegion, index : Int) -> Int {
  self.values_.load(self.absolute_index(index))
}

///|
pub fn SharedRegion::store(
  self : SharedRegion,
  index : Int,
  value : Int,
) -> Unit {
  self.values_.store(self.absolute_index(index), value)
}

///|
pub fn SharedRegion::fill(self : SharedRegion, value : Int) -> Unit {
  for index = 0; index < self.length_; index = index + 1 {
    self.values_.store(self.offset_ + index, value)
  }
}

///|
fn SharedRegion::dynamic_grain(
  self : SharedRegion,
  grain : Int,
) -> Int raise PoolError {
  ignore(self)
  if grain < 0 {
    raise PoolError::InvalidArgument("grain must not be negative")
  }
  if grain == 0 {
    -1
  } else {
    grain
  }
}

///|
/// Applies a registered in-place map kernel to this region.
pub async fn SharedRegion::par_map_in_place(
  self : SharedRegion,
  kernel : KernelCall,
  grain? : Int = 0,
) -> RunResult raise PoolError {
  validate_kernel_call(self.values_.protocol_id_, kernel)
  self.values_.pool.run_kernel_async(
    start=self.offset_,
    end=self.offset_ + self.length_,
    kernel_id=kernel.kernel_id_,
    layout_hash=kernel.layout_hash_,
    argument=kernel.argument_,
    grain=self.dynamic_grain(grain),
  )
}

///|
/// Alias for `par_map_in_place` when the kernel is used for side effects.
pub async fn SharedRegion::par_for_each(
  self : SharedRegion,
  kernel : KernelCall,
  grain? : Int = 0,
) -> RunResult raise PoolError {
  self.par_map_in_place(kernel, grain~)
}

///| Applies a zip kernel to two equal-length regions from the same shared

///|
/// allocation. The factory receives `right.offset - left.offset`.
pub async fn SharedRegion::par_zip(
  self : SharedRegion,
  right : SharedRegion,
  kernel : (Int) -> KernelCall,
  grain? : Int = 0,
) -> RunResult raise PoolError {
  if self.length_ != right.length_ {
    raise PoolError::InvalidArgument("zip regions must have equal lengths")
  }
  if !shared_slice_same_buffer(self.values_.values_, right.values_.values_) {
    raise PoolError::InvalidArgument(
      "zip regions must belong to the same shared allocation",
    )
  }
  self.par_map_in_place(kernel(right.offset_ - self.offset_), grain~)
}

///|
/// Dispatches registered kernels sequentially over the same region.
pub async fn SharedRegion::par_pipeline(
  self : SharedRegion,
  kernels : Array[KernelCall],
  grain? : Int = 0,
) -> Array[RunResult] raise PoolError {
  let results : Array[RunResult] = []
  for kernel in kernels {
    results.push(self.par_map_in_place(kernel, grain~))
  }
  results
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
    grain=0,
  )
}

///|
/// Runs a kernel over dynamically claimed chunks of this shared array.
pub async fn SharedI32::par_chunks(
  self : SharedI32,
  kernel : KernelCall,
  grain? : Int = 0,
  start? : Int = 0,
  end? : Int = -1,
) -> RunResult raise PoolError {
  if grain < 0 {
    raise PoolError::InvalidArgument("grain must not be negative")
  }
  validate_kernel_call(self.protocol_id_, kernel)
  self.pool.run_kernel_async(
    start~,
    end=self.pool.resolve_range_end(end),
    kernel_id=kernel.kernel_id_,
    layout_hash=kernel.layout_hash_,
    argument=kernel.argument_,
    grain=if grain == 0 { -1 } else { grain },
  )
}

///| Reduces a range using Worker-local partials and a deterministic Host

///|
/// combine function.
pub async fn SharedI32::par_reduce(
  self : SharedI32,
  reducer : ReducerCall,
  init~ : Int,
  combine~ : (Int, Int) -> Int,
  start? : Int = 0,
  end? : Int = -1,
) -> ReduceResult raise PoolError {
  validate_reducer_call(self.protocol_id_, reducer)
  self.pool.run_reducer_async(
    reducer,
    init~,
    combine~,
    start~,
    end=self.pool.resolve_range_end(end),
  )
}
