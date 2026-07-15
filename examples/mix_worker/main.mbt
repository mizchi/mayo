///|
extern "js" fn mix(value : Int) -> Int = "(value) => (Math.imul(value, 1664525) + 1013904223) | 0"

///|
fn mix_range(
  shared : @mayo.SharedSlice,
  start : Int,
  end : Int,
  rounds : Int,
) -> Unit {
  for index = start; index < end; index = index + 1 {
    let mut value = shared.load(index)
    for round = 0; round < rounds; round = round + 1 {
      value = mix(value)
    }
    shared.store(index, value)
  }
}

///|
fn add_range(
  shared : @mayo.SharedSlice,
  start : Int,
  end : Int,
  delta : Int,
) -> Unit {
  for index = start; index < end; index = index + 1 {
    shared.store(index, shared.load(index) + delta)
  }
}

///|
fn fail_range(
  _shared : @mayo.SharedSlice,
  _start : Int,
  _end : Int,
  _argument : Int,
) -> Unit {
  abort("intentional kernel failure")
}

///|
fn sum_range(
  shared : @mayo.SharedSlice,
  start : Int,
  end : Int,
  _argument : Int,
) -> Int {
  let mut result = 0
  for index = start; index < end; index = index + 1 {
    result = result + shared.load(index)
  }
  result
}

///|
fn zip_add_range(
  shared : @mayo.SharedSlice,
  start : Int,
  end : Int,
  right_delta : Int,
) -> Unit {
  for index = start; index < end; index = index + 1 {
    shared.store(index, shared.load(index) + shared.load(index + right_delta))
  }
}

///|
fn write_worker_id(
  shared : @mayo.SharedSlice,
  _start : Int,
  _end : Int,
  scratch_base : Int,
) -> Unit {
  let worker = shared.worker_id()
  shared.store(scratch_base + worker, worker + 1)
}

///|
fn main {
  @mayo.serve_kernels(@kernel.manifest(), [
    @kernel.mix_entry(mix_range),
    @kernel.add_entry(add_range),
    @kernel.fail_entry(fail_range),
    @kernel.sum_entry(sum_range),
    @kernel.zip_add_entry(zip_add_range),
    @kernel.write_worker_id_entry(write_worker_id),
  ])
}
