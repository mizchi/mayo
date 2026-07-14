///|
/// Shared memory layout: [mutex, counter, start barrier].
fn wait_for_start(shared : @mayo.SharedInts) -> Unit {
  while atomic_load(shared, 2) == 0 {
    atomic_wait(shared, 2, 0)
  }
}

///|
fn lock(shared : @mayo.SharedInts) -> Unit {
  while atomic_compare_exchange(shared, 0, 0, 1) != 0 {
    atomic_wait(shared, 0, 1)
  }
}

///|
fn unlock(shared : @mayo.SharedInts) -> Unit {
  atomic_store(shared, 0, 0)
  atomic_notify_one(shared, 0)
}

///|
fn run_counter(shared : @mayo.SharedInts, iterations : Int) -> Int {
  wait_for_start(shared)
  for i = 0; i < iterations; i = i + 1 {
    lock(shared)
    let current = atomic_load(shared, 1)
    atomic_store(shared, 1, current + 1)
    unlock(shared)
  }
  atomic_load(shared, 1)
}
