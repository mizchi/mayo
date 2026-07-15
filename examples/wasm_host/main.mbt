///|
extern "js" fn fail_wasm_test() -> Unit = "() => { console.error('MoonBit Wasm shared kernel: failed'); Deno.exit(1); }"

///|
extern "js" fn mix(value : Int) -> Int = "(value) => (Math.imul(value, 1664525) + 1013904223) | 0"

///|
fn expected(value : Int, rounds : Int) -> Int {
  let mut result = value
  for round = 0; round < rounds; round = round + 1 {
    result = mix(result)
  }
  result
}

///|
async fn create_pool(
  contract : @mayo.KernelContract,
  wasm_url : String,
) -> @mayo.Pool raise @mayo.PoolError {
  @mayo.Pool::create(
    @mayo.wasm_kernel_pool_options(
      contract,
      "./mayo_wasm_kernel.js",
      wasm_url,
      capacity=17,
      worker_count=3,
    ),
  )
}

///|
async fn run_wasm_test() -> Unit raise @mayo.PoolError {
  let mut mismatch_rejected = false
  ignore(
    create_pool(
      @mayo.kernel_contract("mayo.example.shared-mix/v2"),
      "./wasm_guest.wasm",
    ),
  ) catch {
    _ => mismatch_rejected = true
  }
  if !mismatch_rejected {
    abort("mismatched Wasm kernel contract was accepted")
  }
  let mut missing_artifact_rejected = false
  ignore(
    create_pool(
      @mayo.kernel_contract(@contract.contract_id()),
      "./missing.wasm",
    ),
  ) catch {
    _ => missing_artifact_rejected = true
  }
  if !missing_artifact_rejected {
    abort("missing Wasm kernel artifact was accepted")
  }

  let pool = create_pool(
    @mayo.kernel_contract(@contract.contract_id()),
    "./wasm_guest.wasm",
  )
  defer pool.close()
  let values = pool.values()
  for index = 0; index < values.length(); index = index + 1 {
    values.store(index, index)
  }
  let result = pool.run(start=2, end=15, argument=3)
  if result.epoch != 1 {
    abort("unexpected Wasm kernel epoch")
  }
  for index = 0; index < values.length(); index = index + 1 {
    let rounds = if index >= 2 && index < 15 { 3 } else { 0 }
    if values.load(index) != expected(index, rounds) {
      abort("unexpected shared Wasm value at index \{index}")
    }
  }
  println("MoonBit Wasm zero-copy shared kernel: ok")
}

///|
async fn main {
  run_wasm_test() catch {
    _ => fail_wasm_test()
  }
}
