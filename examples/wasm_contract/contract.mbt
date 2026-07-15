///|
/// Stable ID shared by the JavaScript host and allocation-free Wasm kernel.
pub fn contract_id() -> String {
  "mayo.example.shared-mix/v1"
}

///|
/// Signed 32-bit FNV-1a hash of `contract_id`, generated ahead of time so the
/// Wasm startup path does not allocate.
pub fn contract_hash() -> Int {
  1178423911
}
