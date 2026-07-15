///|
async fn main {
  let threads = @mayo.ThreadPool::open(
    "./mayo_worker.js",
    capacity=1048576,
    workers=4,
  )
  defer threads.close()
  let values = threads.shared_i32()
  values.fill(1)
  let result = values.par_for(@kernel.mix(rounds=64))
  println(
    "MoonBit host dispatched epoch \{result.epoch} in \{result.elapsed_ms} ms",
  )
}
