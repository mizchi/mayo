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
    @mayo.Pool::create(
      @mayo.kernel_pool_options(
        @mayo.kernel_contract("mayo.example.shared-mix/v2"),
        "./mayo_worker.js",
        capacity=1,
        worker_count=1,
      ),
    ),
  ) catch {
    _ => contract_mismatch_failed = true
  }
  if !contract_mismatch_failed {
    abort("mismatched JS kernel contract was accepted")
  }
  let mut invalid_options_failed = false
  ignore(
    @mayo.Pool::create(
      @mayo.kernel_pool_options(
        @mayo.kernel_contract(@contract.contract_id()),
        "./mayo_worker.js",
        capacity=1,
        worker_count=0,
      ),
    ),
  ) catch {
    _ => invalid_options_failed = true
  }
  if !invalid_options_failed {
    abort("invalid worker_count was accepted")
  }
  let pool = @mayo.Pool::create(
    @mayo.kernel_pool_options(
      @mayo.kernel_contract(@contract.contract_id()),
      "./mayo_worker.js",
      capacity=17,
      worker_count=3,
    ),
  )
  let values = pool.values()
  for index = 0; index < values.length(); index = index + 1 {
    values.store(index, index)
  }
  let first = pool.run(start=2, end=15, argument=2)
  let second = pool.run(start=0, end=17, argument=1)
  let mut invalid_range_failed = false
  ignore(pool.run(start=-1, end=1)) catch {
    _ => invalid_range_failed = true
  }
  if !invalid_range_failed {
    abort("invalid range was accepted")
  }
  pool.close()
  let mut closed_pool_failed = false
  ignore(pool.run(end=0)) catch {
    _ => closed_pool_failed = true
  }
  if !closed_pool_failed {
    abort("closed pool accepted a dispatch")
  }
  if first.epoch != 1 || second.epoch != 2 {
    abort("unexpected Mayo epoch")
  }
  for index = 0; index < values.length(); index = index + 1 {
    let rounds = if index >= 2 && index < 15 { 3 } else { 1 }
    if values.load(index) != mix_rounds(index, rounds) {
      abort("Mayo transform mismatch at index \{index}")
    }
  }
  let queued_pool = @mayo.Pool::create(
    @mayo.kernel_pool_options(
      @mayo.kernel_contract(@contract.contract_id()),
      "./mayo_worker.js",
      capacity=0,
      worker_count=1,
    ),
  )
  let (queued_first, queued_second) = @async.with_task_group(group => {
    let first_task = group.spawn(() => queued_pool.run_async(end=0))
    let second_task = group.spawn(() => queued_pool.run_async(end=0))
    (first_task.wait(), second_task.wait())
  })
  queued_pool.close()
  if queued_first.epoch != 1 || queued_second.epoch != 2 {
    abort("concurrent async dispatches were not queued in FIFO order")
  }
  println("MoonBit Mayo client: ok")
}
