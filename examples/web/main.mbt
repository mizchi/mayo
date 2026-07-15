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
  let pool = @mayo.Pool::create(
    @mayo.pool_options("./mayo_worker.js", capacity=17, worker_count=3),
  )
  defer pool.close()
  let values = pool.values()
  for index = 0; index < values.length(); index = index + 1 {
    values.store(index, index)
  }
  let mut sync_run_failed = false
  ignore(pool.run(end=0)) catch {
    _ => sync_run_failed = true
  }
  if !sync_run_failed {
    abort("synchronous run was accepted on a browser main thread")
  }
  let first = pool.run_async(start=2, end=15, argument=2)
  let second = pool.run_async(end=17, argument=1)
  if first.epoch != 1 || second.epoch != 2 {
    abort("unexpected Mayo epoch")
  }
  for index = 0; index < values.length(); index = index + 1 {
    let rounds = if index >= 2 && index < 15 { 3 } else { 1 }
    if values.load(index) != mix_rounds(index, rounds) {
      abort("Mayo Web transform mismatch at index \{index}")
    }
  }
  show_browser_result(
    "passed", "MoonBit Web client passed: 3 Workers, epochs 1 and 2",
  )
}
