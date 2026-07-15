///|
async fn main {
  let pool = @mayo.Pool::create(
    @mayo.kernel_pool_options(
      @mayo.kernel_contract(@contract.contract_id()),
      "./mayo_worker.js",
      capacity=1048576,
      worker_count=4,
    ),
  )
  defer pool.close()
  let values = pool.values()
  values.fill(1)
  let result = pool.run(end=values.length(), argument=64)
  println(
    "MoonBit host dispatched epoch \{result.epoch} in \{result.elapsed_ms} ms",
  )
}
