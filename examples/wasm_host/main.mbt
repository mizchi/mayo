///|
extern "js" fn fail_wasm_test() -> Unit = "() => { console.error('MoonBit Wasm host/guest: failed'); Deno.exit(1); }"

///|
async fn run_wasm_test() -> Unit raise @mayo.SyncError {
  let wrong_contract : @mayo.SyncContract[
    @contract.WasmSumRequest,
    @contract.WasmSumResponse,
  ] = @mayo.sync_contract("mayo.example.wasm-sum/v2")
  let mut mismatch_rejected = false
  ignore(
    @mayo.SyncGuest::create(
      wrong_contract,
      @mayo.wasm_sync_guest_options(
        "./mayo_wasm_guest.js",
        "./wasm_guest.wasm",
        mailbox_bytes=65536,
      ),
    ),
  ) catch {
    _ => mismatch_rejected = true
  }
  if !mismatch_rejected {
    abort("mismatched Wasm guest contract was accepted")
  }
  let missing_artifact_contract : @mayo.SyncContract[
    @contract.WasmSumRequest,
    @contract.WasmSumResponse,
  ] = @mayo.sync_contract(@contract.contract_id())
  let mut missing_artifact_rejected = false
  ignore(
    @mayo.SyncGuest::create(
      missing_artifact_contract,
      @mayo.wasm_sync_guest_options(
        "./mayo_wasm_guest.js",
        "./missing.wasm",
        mailbox_bytes=65536,
      ),
    ),
  ) catch {
    _ => missing_artifact_rejected = true
  }
  if !missing_artifact_rejected {
    abort("missing Wasm guest artifact was accepted")
  }
  let contract : @mayo.SyncContract[
    @contract.WasmSumRequest,
    @contract.WasmSumResponse,
  ] = @mayo.sync_contract(@contract.contract_id())
  let guest = @mayo.SyncGuest::create(
    contract,
    @mayo.wasm_sync_guest_options(
      "./mayo_wasm_guest.js",
      "./wasm_guest.wasm",
      mailbox_bytes=65536,
    ),
  )
  defer guest.close()
  let response = guest.call({ name: "MoonBit", values: [3, 5, 8], scale: 4 })
  if response.message != "hello MoonBit from Wasm" ||
    response.total != 64 ||
    response.item_count != 3 {
    abort("unexpected Wasm guest response")
  }
  println("MoonBit Wasm host/guest: ok")
}

///|
async fn main {
  run_wasm_test() catch {
    _ => fail_wasm_test()
  }
}
