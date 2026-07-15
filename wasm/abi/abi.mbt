///|
const ABI_VERSION : Int = 2

///|
extern "wasm" fn mem_load32(ptr : Int) -> Int =
  #|(func (param i32) (result i32) (i32.load (local.get 0)))

///|
extern "wasm" fn mem_store32(ptr : Int, value : Int) -> Unit =
  #|(func (param i32 i32) (i32.store (local.get 0) (local.get 1)))

///|
/// Current Mayo allocation-free shared-kernel Wasm ABI version.
pub fn abi_version() -> Int {
  ABI_VERSION
}

///|
/// Validates the POD descriptor passed to `mayo_run` without allocating.
pub fn descriptor_is_valid(
  data_offset : Int,
  capacity : Int,
  start : Int,
  end : Int,
) -> Bool {
  data_offset >= 0 &&
  capacity >= 0 &&
  start >= 0 &&
  end >= start &&
  end <= capacity
}

///|
/// Loads one Int32 directly from imported shared WebAssembly memory.
/// The caller must validate the descriptor and index before calling.
pub fn load_i32(data_offset : Int, index : Int) -> Int {
  mem_load32((data_offset + index) * 4)
}

///|
/// Stores one Int32 directly in imported shared WebAssembly memory.
/// The caller must validate the descriptor and index before calling.
pub fn store_i32(data_offset : Int, index : Int, value : Int) -> Unit {
  mem_store32((data_offset + index) * 4, value)
}
