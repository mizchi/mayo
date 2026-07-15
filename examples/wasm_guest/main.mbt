///|
fn mix(value : Int) -> Int {
  value * 1664525 + 1013904223
}

///|
fn mix_range(data_offset : Int, start : Int, end : Int, rounds : Int) -> Unit {
  for index = start; index < end; index = index + 1 {
    let mut value = @abi.load_i32(data_offset, index)
    for round = 0; round < rounds; round = round + 1 {
      value = mix(value)
    }
    @abi.store_i32(data_offset, index, value)
  }
}

///|
pub fn mayo_abi_version() -> Int {
  @abi.abi_version()
}

///|
pub fn mayo_contract_hash() -> Int {
  @contract.contract_hash()
}

///|
/// Executes directly against imported shared WebAssembly memory.
pub fn mayo_run(
  data_offset : Int,
  capacity : Int,
  start : Int,
  end : Int,
  argument : Int,
) -> Int {
  if !@abi.descriptor_is_valid(data_offset, capacity, start, end) {
    return -1
  }
  mix_range(data_offset, start, end, argument)
  0
}

///|
fn main {

}
