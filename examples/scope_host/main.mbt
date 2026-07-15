///|
/// Demonstrates `ThreadPool::scope` structured concurrency: two calls are
/// spawned together and both are guaranteed to finish before `scope` returns,
/// even though only the second call is joined explicitly here.
async fn main {
  let threads = @mayo.ThreadPool::open(
    "./mayo_worker.js",
    capacity=1048576,
    workers=4,
  )
  defer threads.close()
  let values = threads.shared_i32()
  values.fill(1)
  let (first, second) = threads.scope(scope => {
    let first_task = scope.spawn(@kernel.mix(rounds=1))
    let second_task = scope.spawn(@kernel.mix(rounds=8))
    (first_task.join(), second_task.join())
  })
  if first.epoch >= second.epoch {
    abort("expected the first spawned call to be admitted before the second")
  }
  println(
    "MoonBit scoped host: dispatch 1 (rounds=1) finished epoch \{first.epoch} in \{first.elapsed_ms} ms",
  )
  println(
    "MoonBit scoped host: dispatch 2 (rounds=8) finished epoch \{second.epoch} in \{second.elapsed_ms} ms",
  )
}
