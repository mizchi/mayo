///|
extern "js" fn mix(value : Int) -> Int = "(value) => (Math.imul(value, 1664525) + 1013904223) | 0"

///|
fn mix_rounds(value : Int, rounds : Int) -> Int {
  let mut result = value
  for round = 0; round < rounds; round = round + 1 {
    result = mix(result)
  }
  result
}

///|
async fn main {
  let mut contract_mismatch_failed = false
  ignore(
    @mayo.ThreadPool::open(
      @mayo.kernel_manifest("mayo.example.wrong/v1", [
        @mayo.kernel_spec(id=1, layout_hash=1),
      ]),
      "./mayo_worker.js",
      capacity=1,
      workers=1,
    ),
  ) catch {
    _ => contract_mismatch_failed = true
  }
  if !contract_mismatch_failed {
    abort("mismatched JS kernel contract was accepted")
  }
  let mut invalid_options_failed = false
  ignore(
    @mayo.ThreadPool::open(
      @kernel.manifest(),
      "./mayo_worker.js",
      capacity=1,
      workers=0,
    ),
  ) catch {
    _ => invalid_options_failed = true
  }
  if !invalid_options_failed {
    abort("invalid worker_count was accepted")
  }
  let threads = @mayo.ThreadPool::open(
    @kernel.manifest(),
    "./mayo_worker.js",
    capacity=17,
    workers=3,
  )
  let values = threads.shared_i32()
  for index = 0; index < values.length(); index = index + 1 {
    values.store(index, index)
  }
  let first = values.par_for(@kernel.mix(rounds=2), start=2, end=15)
  let second = values.par_for(@kernel.add(delta=1))
  let dynamic = values.par_chunks(@kernel.add(delta=2))
  let mut invalid_grain_failed = false
  ignore(values.par_chunks(@kernel.noop(), grain=-1, end=0)) catch {
    _ => invalid_grain_failed = true
  }
  if !invalid_grain_failed {
    abort("negative dynamic grain was accepted")
  }
  let mut invalid_range_failed = false
  ignore(values.par_for(@kernel.noop(), start=-1, end=1)) catch {
    _ => invalid_range_failed = true
  }
  if !invalid_range_failed {
    abort("invalid range was accepted")
  }
  let foreign_spec = @mayo.kernel_spec(id=1, layout_hash=1)
  let foreign_call = @mayo.kernel_call(
    @mayo.kernel_manifest("mayo.example.foreign/v1", [foreign_spec]),
    foreign_spec,
  )
  let mut foreign_call_failed = false
  ignore(values.par_for(foreign_call, end=0)) catch {
    _ => foreign_call_failed = true
  }
  if !foreign_call_failed {
    abort("foreign kernel descriptor was accepted")
  }
  let (queued_first, queued_second) = threads.scope(scope => {
    let first_task = scope.spawn(@kernel.noop(), end=0)
    let second_task = scope.spawn(@kernel.noop(), end=0)
    (first_task.join(), second_task.join())
  })
  let mut invalid_spawn_failed = false
  threads.scope(scope => {
    let invalid_task = scope.spawn(@kernel.noop(), start=-1, end=0)
    ignore(invalid_task.join()) catch {
      _ => invalid_spawn_failed = true
    }
  })
  if !invalid_spawn_failed {
    abort("invalid scoped dispatch was accepted")
  }
  if first.epoch != 1 || second.epoch != 2 || dynamic.epoch != 3 {
    abort("unexpected Mayo epoch")
  }
  if dynamic.grain <= 0 {
    abort("auto grain was not selected")
  }
  for index = 0; index < values.length(); index = index + 1 {
    let expected = if index >= 2 && index < 15 {
      mix_rounds(index, 2) + 3
    } else {
      index + 3
    }
    if values.load(index) != expected {
      abort("Mayo transform mismatch at index \{index}")
    }
  }
  if queued_first.epoch != 4 || queued_second.epoch != 5 {
    abort("concurrent async dispatches were not queued in FIFO order")
  }

  let mut cancelled = false
  threads.scope(scope => {
    let task = scope.spawn_chunks(@kernel.mix(rounds=1000000), grain=1)
    @async.sleep(1)
    if !threads.cancel_current() {
      abort("active dynamic dispatch was not cancellable")
    }
    ignore(task.join()) catch {
      @mayo.PoolError::Cancelled => cancelled = true
      _ => abort("unexpected cancellation error")
    }
  })
  if !cancelled {
    abort("dynamic dispatch completed instead of reporting cancellation")
  }
  ignore(values.par_for(@kernel.noop(), end=0))

  threads.close()
  let mut closed_pool_failed = false
  ignore(values.par_for(@kernel.noop(), end=0)) catch {
    _ => closed_pool_failed = true
  }
  if !closed_pool_failed {
    abort("closed pool accepted a dispatch")
  }

  let failure_pool = @mayo.ThreadPool::open(
    @kernel.manifest(),
    "./mayo_worker.js",
    capacity=1,
    workers=1,
  )
  defer failure_pool.close()
  let failure_values = failure_pool.shared_i32()
  let mut kernel_failed = false
  ignore(failure_values.par_for(@kernel.fail(), end=1)) catch {
    @mayo.PoolError::WorkerFailed(_) => kernel_failed = true
    _ => abort("unexpected kernel failure")
  }
  if !kernel_failed {
    abort("kernel panic did not fail its dispatch")
  }
  let mut poisoned_failed = false
  ignore(failure_values.par_for(@kernel.noop(), end=0)) catch {
    @mayo.PoolError::WorkerFailed(_) => poisoned_failed = true
    _ => abort("unexpected poisoned pool error")
  }
  if !poisoned_failed {
    abort("poisoned pool accepted another dispatch")
  }

  let recovery_pool = @mayo.ThreadPool::open(
    @kernel.manifest(),
    "./mayo_worker.js",
    capacity=1,
    workers=2,
    recovery=@mayo.RecoveryPolicy::RestartWorkers,
  )
  defer recovery_pool.close()
  let recovery_values = recovery_pool.shared_i32()
  let mut recoverable_failed = false
  ignore(recovery_values.par_for(@kernel.fail(), end=1)) catch {
    @mayo.PoolError::WorkerFailed(_) => recoverable_failed = true
    _ => abort("unexpected recoverable worker failure")
  }
  if !recoverable_failed {
    abort("recovery pool did not report the failed dispatch")
  }
  ignore(recovery_values.par_for(@kernel.noop(), end=0))

  let reduce_pool = @mayo.ThreadPool::open(
    @kernel.manifest(),
    "./mayo_worker.js",
    capacity=16,
    workers=4,
  )
  defer reduce_pool.close()
  let reduce_values = reduce_pool.shared_i32()
  for index = 0; index < reduce_values.length(); index = index + 1 {
    reduce_values.store(index, index + 1)
  }
  let sum = reduce_values.par_reduce(@kernel.sum(), init=0, combine=fn(
    left,
    right,
  ) {
    left + right
  })
  if sum.value != 136 || sum.epoch != 1 {
    abort("parallel reduction returned an unexpected result")
  }
  let single = reduce_values.par_reduce(
    @kernel.sum(),
    init=0,
    combine=fn(left, right) { left * 10 + right },
    end=1,
  )
  if single.value != 1 || single.epoch != 2 {
    abort("parallel reduction combined an empty weighted range")
  }
  let arena_pool = @mayo.ThreadPool::open(
    @kernel.manifest(),
    "./mayo_worker.js",
    capacity=8,
    workers=2,
  )
  defer arena_pool.close()
  let arena = arena_pool.arena()
  let left = arena.allocate(length=3)
  let right = arena.allocate(length=5)
  if left.offset() != 0 || right.offset() != 3 || arena.remaining() != 0 {
    abort("shared arena allocated overlapping regions")
  }
  left.fill(7)
  right.store(0, 9)
  if left.load(2) != 7 || right.load(0) != 9 {
    abort("shared arena region access failed")
  }
  arena.reset()
  let scratch = arena.allocate_worker_scratch(
    workers=arena_pool.worker_count(),
    words_per_worker=2,
  )
  if scratch.worker_offset(0) != 0 || scratch.worker_offset(1) != 2 {
    abort("worker scratch regions overlap")
  }
  let scratch_pool = @mayo.ThreadPool::open(
    @kernel.manifest(),
    "./mayo_worker.js",
    capacity=4,
    workers=4,
  )
  defer scratch_pool.close()
  let scratch_arena = scratch_pool.arena()
  let guest_scratch = scratch_arena.allocate_worker_scratch(
    workers=scratch_pool.worker_count(),
    words_per_worker=1,
  )
  ignore(
    scratch_pool.par_for(
      @kernel.write_worker_id(scratch_base=guest_scratch.worker_offset(0)),
      end=0,
    ),
  )
  for worker = 0; worker < scratch_pool.worker_count(); worker = worker + 1 {
    if guest_scratch.worker_region(worker).load(0) != worker + 1 {
      abort("guest Worker could not address its scratch region")
    }
  }
  let zip_pool = @mayo.ThreadPool::open(
    @kernel.manifest(),
    "./mayo_worker.js",
    capacity=8,
    workers=2,
  )
  defer zip_pool.close()
  let zip_arena = zip_pool.arena()
  let zip_left = zip_arena.allocate(length=4)
  let zip_right = zip_arena.allocate(length=4)
  for index = 0; index < 4; index = index + 1 {
    zip_left.store(index, index + 1)
    zip_right.store(index, (index + 1) * 10)
  }
  ignore(
    zip_left.par_zip(zip_right, fn(delta) { @kernel.zip_add(right_delta=delta) }),
  )
  ignore(zip_left.par_pipeline([@kernel.add(delta=1), @kernel.add(delta=2)]))
  ignore(zip_left.par_for_each(@kernel.noop()))
  ignore(zip_left.par_map_in_place(@kernel.noop()))
  for index = 0; index < 4; index = index + 1 {
    if zip_left.load(index) != (index + 1) * 11 + 3 {
      abort("high-level parallel combinator returned an unexpected value")
    }
  }
  println("MoonBit Mayo client: ok")
}
