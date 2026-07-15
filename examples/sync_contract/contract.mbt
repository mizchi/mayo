///|
/// Request type compiled into both the host and guest bundles.
pub(all) struct SumRequest {
  name : String
  values : Array[Int]
  scale : Int
} derive(Eq, Debug, ToJson, FromJson)

///|
/// Response type compiled into both the host and guest bundles.
pub(all) struct SumResponse {
  message : String
  total : Int
  item_count : Int
} derive(Eq, Debug, ToJson, FromJson)

///|
/// The ID is checked when the Worker starts, before shared memory is used.
pub fn contract() -> @mayo_json.JsonContract[SumRequest, SumResponse] {
  @mayo_json.json_contract("mayo.example.sum/v1")
}
