///|
/// An opaque call descriptor for one ahead-of-time range kernel.
///
/// Generated kernel packages can return this type without exposing Mayo's raw
/// `(start, end, argument)` scheduler descriptor to application code.
pub struct KernelCall {
  priv argument_ : Int
}

///|
/// Creates a call for the single range kernel installed by the Worker artifact.
///
/// This is the manual bridge used until kernel descriptors are generated from a
/// registry. Application-specific packages should wrap it with a named function.
pub fn kernel_call(argument? : Int = 0) -> KernelCall {
  { argument_: argument }
}

///|
/// A Worker-backed logical thread pool using Mayo's built-in range ABI.
pub struct ThreadPool {
  priv pool : Pool
}

///|
/// The signed 32-bit shared array owned by a `ThreadPool`.
pub struct SharedI32 {
  priv pool : Pool
  priv values_ : SharedSlice
}

///|
/// A structured-concurrency scope for spawning data-parallel kernel calls.
pub struct ThreadScope[X] {
  priv pool : Pool
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
/// Opens a prebuilt JavaScript Worker artifact using the built-in
/// `mayo.range/v1` ABI. The kernel contract is intentionally hidden from this
/// facade.
pub async fn ThreadPool::open(
  worker_url : String,
  capacity~ : Int,
  workers? : Int = 4,
  timeout_ms? : Int = 30000,
) -> ThreadPool raise PoolError {
  let pool = Pool::create(
    pool_options(worker_url, capacity~, worker_count=workers, timeout_ms~),
  )
  { pool, }
}

///|
/// Returns the shared signed 32-bit array visible to every Worker.
pub fn ThreadPool::shared_i32(self : ThreadPool) -> SharedI32 {
  { pool: self.pool, values_: self.pool.values() }
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
  self.pool.run_async(
    start~,
    end=self.pool.resolve_range_end(end),
    argument=kernel.argument_,
  )
}

///|
/// Runs scoped kernel calls. Every spawned call finishes before this function
/// returns, even when its handle is not explicitly joined.
pub async fn[X] ThreadPool::scope(
  self : ThreadPool,
  body : async (ThreadScope[X]) -> X,
) -> X raise PoolError {
  @async.with_task_group(group => body({ pool: self.pool, group, tail: None })) catch {
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
  let previous = self.tail
  let task = self.group.spawn(allow_failure=true, () => {
    if previous is Some(previous_task) {
      ignore(previous_task.wait()) catch {
        _ => ()
      }
    }
    pool.run_async(
      start~,
      end=pool.resolve_range_end(end),
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
  self.pool.run_async(
    start~,
    end=self.pool.resolve_range_end(end),
    argument=kernel.argument_,
  )
}
