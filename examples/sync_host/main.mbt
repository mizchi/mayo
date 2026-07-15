///|
extern "js" fn fail_sync_test() -> Unit = "() => { console.error('MoonBit Sync host/guest: failed'); Deno.exit(1); }"

///|
async fn run_sync_test() -> Unit raise @mayo.SyncError {
  let wrong_contract : @mayo.SyncContract[
    @contract.SumRequest,
    @contract.SumResponse,
  ] = @mayo.sync_contract("mayo.example.sum/v2")
  let mut mismatch_rejected = false
  ignore(
    @mayo.SyncGuest::create(
      wrong_contract,
      @mayo.sync_guest_options("./sync_guest.js", mailbox_bytes=65536),
    ),
  ) catch {
    _ => mismatch_rejected = true
  }
  if !mismatch_rejected {
    abort("mismatched guest contract was accepted")
  }
  let constrained_guest = @mayo.SyncGuest::create(
    @contract.contract(),
    @mayo.sync_guest_options("./sync_guest.js", mailbox_bytes=128),
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
    abort("typed guest did not recover after capacity error")
  }
  let guest = @mayo.SyncGuest::create(
    @contract.contract(),
    @mayo.sync_guest_options("./sync_guest.js", mailbox_bytes=65536),
  )
  defer guest.close()
  let response = guest.call({ name: "MoonBit", values: [3, 5, 8], scale: 4 })
  if response.message != "hello MoonBit" ||
    response.total != 64 ||
    response.item_count != 3 {
    abort("unexpected typed guest response")
  }
  println("MoonBit Sync host/guest: ok")
}

///|
async fn main {
  run_sync_test() catch {
    _ => fail_sync_test()
  }
}
