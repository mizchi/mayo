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
  show_browser_result("running", "range pool passed; starting typed guest")
  let guest = @mayo.SyncGuest::create(
    @contract.contract(),
    @mayo.sync_guest_options("./sync_guest.js", mailbox_bytes=65536),
  )
  defer guest.close()
  show_browser_result("running", "typed guest ready; calling contract")
  let response = guest.call_async({ name: "Web", values: [3, 5, 8], scale: 4 })
  if response.message != "hello Web" ||
    response.total != 64 ||
    response.item_count != 3 {
    abort("unexpected typed Web guest response")
  }
  show_browser_result("running", "typed JS guest passed; starting Wasm guest")
  let wasm_contract : @mayo.SyncContract[
    @wasm_contract.WasmSumRequest,
    @wasm_contract.WasmSumResponse,
  ] = @mayo.sync_contract(@wasm_contract.contract_id())
  let wasm_guest = @mayo.SyncGuest::create(
    wasm_contract,
    @mayo.wasm_sync_guest_options(
      "./mayo_wasm_guest.js",
      "./wasm_guest.wasm",
      mailbox_bytes=65536,
    ),
  )
  defer wasm_guest.close()
  let wasm_response = wasm_guest.call_async({
    name: "Web",
    values: [3, 5, 8],
    scale: 4,
  })
  if wasm_response.message != "hello Web from Wasm" ||
    wasm_response.total != 64 ||
    wasm_response.item_count != 3 {
    abort("unexpected typed Wasm guest response")
  }
  show_browser_result(
    "passed", "MoonBit Web client passed: range pool, typed JS guest, and typed Wasm guest",
  )
}
