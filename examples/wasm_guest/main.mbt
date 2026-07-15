///|
fn handle(request : @contract.WasmSumRequest) -> @contract.WasmSumResponse {
  let mut total = 0
  for value in request.values {
    total = total + value * request.scale
  }
  {
    message: "hello \{request.name} from Wasm",
    total,
    item_count: request.values.length(),
  }
}

///|
pub fn mayo_abi_version() -> Int {
  @abi.abi_version()
}

///|
pub fn mayo_abi_capacity() -> Int {
  @abi.abi_capacity()
}

///|
pub fn mayo_contract_hash() -> Int {
  @abi.contract_hash(@contract.contract_id())
}

///|
pub fn mayo_request_ptr() -> Int {
  @abi.request_ptr()
}

///|
pub fn mayo_response_ptr() -> Int {
  @abi.response_ptr()
}

///|
/// Reads request JSON from the ABI request buffer and writes response JSON to
/// the ABI response buffer. `-1` means the request did not match the contract.
pub fn mayo_handle(request_length : Int) -> Int {
  @abi.handle_sync(request_length, handle)
}

///|
fn main {

}
