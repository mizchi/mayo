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
  threads.close()
  let mut closed_pool_failed = false
  ignore(values.par_for(@kernel.noop(), end=0)) catch {
    _ => closed_pool_failed = true
  }
  if !closed_pool_failed {
    abort("closed pool accepted a dispatch")
  }
  if first.epoch != 1 || second.epoch != 2 {
    abort("unexpected Mayo epoch")
  }
  for index = 0; index < values.length(); index = index + 1 {
    let expected = if index >= 2 && index < 15 {
      mix_rounds(index, 2) + 1
    } else {
      index + 1
    }
    if values.load(index) != expected {
      abort("Mayo transform mismatch at index \{index}")
    }
  }
  if queued_first.epoch != 3 || queued_second.epoch != 4 {
    abort("concurrent async dispatches were not queued in FIFO order")
  }
  println("MoonBit Mayo client: ok")
}
