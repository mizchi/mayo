///|
extern "js" fn browser_is_cross_origin_isolated() -> Bool = "() => globalThis.crossOriginIsolated === true"

///|
extern "js" fn show_browser_result(state : String, detail : String) -> Unit =
  #| (state, detail) => {
  #|   document.documentElement.dataset.mayoState = state;
  #|   const output = document.querySelector("[data-testid='status']");
  #|   output.dataset.state = state;
  #|   output.textContent = detail;
  #| }

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
  if !browser_is_cross_origin_isolated() {
    abort("Mayo Web requires cross-origin isolation")
  }
  let threads = @mayo.ThreadPool::open(
    @kernel.manifest(),
    "./mayo_worker.js",
    capacity=17,
    workers=3,
  )
  defer threads.close()
  let values = threads.shared_i32()
  for index = 0; index < values.length(); index = index + 1 {
    values.store(index, index)
  }
  let first = values.par_for(@kernel.mix(rounds=2), start=2, end=15)
  let second = values.par_for(@kernel.add(delta=1))
  let dynamic = values.par_chunks(@kernel.add(delta=2))
  if first.epoch != 1 || second.epoch != 2 || dynamic.epoch != 3 {
    abort("unexpected Mayo epoch")
  }
  if dynamic.grain <= 0 {
    abort("Web auto grain was not selected")
  }
  for index = 0; index < values.length(); index = index + 1 {
    let expected = if index >= 2 && index < 15 {
      mix_rounds(index, 2) + 3
    } else {
      index + 3
    }
    if values.load(index) != expected {
      abort("Mayo Web transform mismatch at index \{index}")
    }
  }
  let (queued_first, queued_second) = threads.scope(scope => {
    let first_task = scope.spawn(@kernel.noop(), end=0)
    let second_task = scope.spawn(@kernel.noop(), end=0)
    (first_task.join(), second_task.join())
  })
  if queued_first.epoch != 4 || queued_second.epoch != 5 {
    abort("concurrent Web dispatches were not queued in FIFO order")
  }
  threads.close()
  show_browser_result(
    "running", "JS range pool passed; starting shared Wasm kernel",
  )
  let wasm_pool = @mayo.Pool::create(
    @mayo.wasm_kernel_pool_options(
      @mayo.kernel_contract(@wasm_contract.contract_id()),
      "./mayo_wasm_kernel.js",
      "./wasm_guest.wasm",
      capacity=17,
      worker_count=3,
    ),
  )
  defer wasm_pool.close()
  let wasm_values = wasm_pool.values()
  for index = 0; index < wasm_values.length(); index = index + 1 {
    wasm_values.store(index, index)
  }
  ignore(wasm_pool.run_async(start=2, end=15, argument=3))
  for index = 0; index < wasm_values.length(); index = index + 1 {
    let rounds = if index >= 2 && index < 15 { 3 } else { 0 }
    if wasm_values.load(index) != mix_rounds(index, rounds) {
      abort("shared Wasm transform mismatch at index \{index}")
    }
  }
  show_browser_result(
    "passed", "MoonBit Web client passed: JS and Wasm zero-copy pools",
  )
}
