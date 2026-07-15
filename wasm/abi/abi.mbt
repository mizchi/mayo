///|
const ABI_VERSION : Int = 1

///|
const ABI_CAPACITY : Int = 1048576

///|
const ABI_REQUEST_PTR : Int = 65536

///|
const ABI_RESPONSE_PTR : Int = 1114112

///|
extern "wasm" fn mem_load8(ptr : Int) -> Int =
  #|(func (param i32) (result i32) (i32.load8_u (local.get 0)))

///|
extern "wasm" fn mem_store8(ptr : Int, value : Int) -> Unit =
  #|(func (param i32 i32) (i32.store8 (local.get 0) (local.get 1)))

///|
fn read_utf8(ptr : Int, length : Int) -> String {
  let bytes : Array[Byte] = Array::new(capacity=length)
  for index = 0; index < length; index = index + 1 {
    bytes.push(mem_load8(ptr + index).to_byte())
  }
  @utf8.decode_lossy(Bytes::from_array(bytes[:])[:])
}

///|
fn write_utf8(ptr : Int, text : String) -> Int {
  let bytes = @utf8.encode(text)
  if bytes.length() > ABI_CAPACITY {
    return -bytes.length() - 2
  }
  for index = 0; index < bytes.length(); index = index + 1 {
    mem_store8(ptr + index, bytes[index].to_int())
  }
  bytes.length()
}

///|
/// Current Mayo Wasm guest ABI version.
pub fn abi_version() -> Int {
  ABI_VERSION
}

///|
/// Maximum encoded request or response size supported by ABI v1.
pub fn abi_capacity() -> Int {
  ABI_CAPACITY
}

///|
/// Linear-memory address where the JS glue writes request bytes.
pub fn request_ptr() -> Int {
  ABI_REQUEST_PTR
}

///|
/// Linear-memory address where the guest writes response bytes.
pub fn response_ptr() -> Int {
  ABI_RESPONSE_PTR
}

///|
/// Computes the signed 32-bit FNV-1a hash used to bind a Wasm artifact to its
/// versioned contract ID.
pub fn contract_hash(id : String) -> Int {
  let bytes = @utf8.encode(id)
  let mut hash = -2128831035
  for byte in bytes {
    hash = (hash ^ byte.to_int()) * 16777619
  }
  hash
}

///|
/// Decodes a typed JSON request, invokes a MoonBit handler, and encodes its
/// response. `-1` means the request did not match the contract. Values below
/// `-1` encode a response capacity error as `-(required + 2)`.
pub fn[Request : @json.FromJson, Response : ToJson] handle_sync(
  request_length : Int,
  handler : (Request) -> Response,
) -> Int {
  if request_length < 0 || request_length > ABI_CAPACITY {
    return -1
  }
  let request : Request = @json.from_json(
    @json.parse(read_utf8(ABI_REQUEST_PTR, request_length)),
  ) catch {
    _ => return -1
  }
  write_utf8(ABI_RESPONSE_PTR, handler(request).to_json().stringify())
}
