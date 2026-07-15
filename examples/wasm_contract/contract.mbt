///|
/// Request type compiled into both the JavaScript host and Wasm guest.
pub(all) struct WasmSumRequest {
  name : String
  values : Array[Int]
  scale : Int
} derive(Eq, Debug, ToJson, FromJson)

///|
/// Response type compiled into both the JavaScript host and Wasm guest.
pub(all) struct WasmSumResponse {
  message : String
  total : Int
  item_count : Int
} derive(Eq, Debug, ToJson, FromJson)

///|
/// Stable ID used by the JS glue and the MoonBit host handshake.
pub fn contract_id() -> String {
  "mayo.example.wasm-sum/v1"
}
