///|

///|
extern "js" fn mix(value : Int) -> Int = "(value) => (Math.imul(value, 1664525) + 1013904223) | 0"

///|
fn run_transform(
  shared : @mayo.SharedInts,
  start : Int,
  end : Int,
  compute_rounds : Int,
) -> Unit {
  for index = start; index < end; index = index + 1 {
    let mut value = direct_load(shared, index)
    for round = 0; round < compute_rounds; round = round + 1 {
      value = mix(value)
    }
    direct_store(shared, index, value)
  }
}

///|
fn run_atomic_transform(
  shared : @mayo.SharedSlice,
  start : Int,
  end : Int,
  compute_rounds : Int,
) -> Unit {
  for index = start; index < end; index = index + 1 {
    let mut value = shared.load(index)
    for round = 0; round < compute_rounds; round = round + 1 {
      value = mix(value)
    }
    shared.store(index, value)
  }
}

///|
#borrow(shared)
extern "js" fn direct_load(shared : @mayo.SharedInts, index : Int) -> Int = "(shared, index) => shared[index] | 0"

///|
#borrow(shared)
extern "js" fn direct_store(
  shared : @mayo.SharedInts,
  index : Int,
  value : Int,
) -> Unit = "(shared, index, value) => { shared[index] = value; }"
