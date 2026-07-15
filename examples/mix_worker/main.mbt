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
fn main {
  @mayo.serve_kernels(@kernel.manifest(), [
    @kernel.mix_entry(mix_range),
    @kernel.add_entry(add_range),
  ])
}
