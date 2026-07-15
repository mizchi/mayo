///|
extern "js" fn fail_sync_test(message : String) -> Unit = "(message) => { console.error(`MoonBit JSON host/guest: failed: ${message}`); Deno.exit(1); }"

///|
fn json_error_message(error : @mayo_json.JsonError) -> String {
  match error {
    InvalidArgument(message) => "invalid argument: \{message}"
    CapacityExceeded(required, capacity) =>
      "capacity exceeded: \{required} > \{capacity}"
    GuestFailed(message) => "guest failed: \{message}"
    Transport(message) => "transport: \{message}"
    Busy => "busy"
  }
}

///|
async fn run_sync_test() -> Unit raise @mayo_json.JsonError {
  let wrong_contract : @mayo_json.JsonContract[
    @contract.SumRequest,
    @contract.SumResponse,
  ] = @mayo_json.json_contract("mayo.example.sum/v2")
  let mut mismatch_rejected = false
  ignore(
    @mayo_json.JsonGuest::create(
      wrong_contract,
      @mayo_json.json_guest_options("./json_guest.js", mailbox_bytes=65536),
    ),
  ) catch {
    _ => mismatch_rejected = true
  }
  if !mismatch_rejected {
    abort("mismatched guest contract was accepted")
  }
  let constrained_guest = @mayo_json.JsonGuest::create(
    @contract.contract(),
    @mayo_json.json_guest_options("./json_guest.js", mailbox_bytes=128),
  )
  defer constrained_guest.close()
  let mut capacity_rejected = false
  ignore(
    constrained_guest.call({
      name: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      values: [3, 5, 8],
      scale: 4,
    }),
  ) catch {
    _ => capacity_rejected = true
  }
  if !capacity_rejected {
    abort("oversized typed request was accepted")
  }
  let recovered = constrained_guest.call({
    name: "retry",
    values: [1],
    scale: 2,
  })
  if recovered.total != 2 {
    abort("JSON guest did not recover after capacity error")
  }
  let guest = @mayo_json.JsonGuest::create(
    @contract.contract(),
    @mayo_json.json_guest_options("./json_guest.js", mailbox_bytes=65536),
  )
  defer guest.close()
  let response = guest.call({ name: "MoonBit", values: [3, 5, 8], scale: 4 })
  if response.message != "hello MoonBit" ||
    response.total != 64 ||
    response.item_count != 3 {
    abort("unexpected JSON guest response")
  }
  println("MoonBit optional JSON host/guest: ok")
}

///|
async fn main {
  run_sync_test() catch {
    error => fail_sync_test(json_error_message(error))
  }
}
