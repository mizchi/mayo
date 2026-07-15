///|
/// Opaque control view backed by a host `SharedArrayBuffer`.
#external
pub type SharedInts

///|
#external
pub type SharedSlice

///|
extern "js" fn data_slice(shared : SharedInts, offset : Int) -> SharedSlice = "(shared, offset) => new Int32Array(shared.buffer, shared.byteOffset + offset * Int32Array.BYTES_PER_ELEMENT, shared.length - offset)"

///|
/// Returns the number of elements in this shared data view.
#borrow(self)
pub extern "js" fn SharedSlice::length(self : SharedSlice) -> Int = "(self) => self.length | 0"

///|
/// Returns the byte length of this shared data view.
#borrow(self)
pub extern "js" fn SharedSlice::byte_length(self : SharedSlice) -> Int = "(self) => self.byteLength | 0"

///|
/// Writes a UTF-8 string at a byte offset. Returns the encoded byte length, or
/// `-(required + 1)` when the destination is too small.
#borrow(self)
extern "js" fn SharedSlice::write_utf8(
  self : SharedSlice,
  byte_offset : Int,
  text : String,
) -> Int =
  #| (self, byteOffset, text) => {
  #|   const bytes = new TextEncoder().encode(text);
  #|   const capacity = self.byteLength - byteOffset;
  #|   if (bytes.byteLength > capacity) return -(bytes.byteLength + 1);
  #|   new Uint8Array(
  #|     self.buffer,
  #|     self.byteOffset + byteOffset,
  #|     bytes.byteLength,
  #|   ).set(bytes);
  #|   return bytes.byteLength | 0;
  #| }

///|
/// Reads a UTF-8 string from this shared data view.
#borrow(self)
extern "js" fn SharedSlice::read_utf8(
  self : SharedSlice,
  byte_offset : Int,
  byte_length : Int,
) -> String =
  #| (self, byteOffset, byteLength) => new TextDecoder().decode(
  #|   new Uint8Array(
  #|     self.buffer,
  #|     self.byteOffset + byteOffset,
  #|     byteLength,
  #|   ).slice(),
  #| )

///|
/// Loads one value. Dispatched worker ranges never overlap, so this access is
/// deliberately non-atomic.
#borrow(self)
pub extern "js" fn SharedSlice::load(self : SharedSlice, index : Int) -> Int = "(self, index) => self[index] | 0"

///|
/// Stores one value. Dispatched worker ranges never overlap, so this access is
/// deliberately non-atomic.
#borrow(self)
pub extern "js" fn SharedSlice::store(
  self : SharedSlice,
  index : Int,
  value : Int,
) -> Unit = "(self, index, value) => { self[index] = value; }"

///|
/// Fills the complete shared data view with one signed 32-bit value.
#borrow(self)
pub extern "js" fn SharedSlice::fill(self : SharedSlice, value : Int) -> Unit = "(self, value) => { self.fill(value); }"

///|
#borrow(shared)
extern "js" fn atomic_load(shared : SharedInts, index : Int) -> Int = "(shared, index) => Atomics.load(shared, index)"

///|
#borrow(shared)
extern "js" fn atomic_store(
  shared : SharedInts,
  index : Int,
  value : Int,
) -> Unit = "(shared, index, value) => { Atomics.store(shared, index, value); }"

///|
#borrow(shared)
extern "js" fn atomic_wait(
  shared : SharedInts,
  index : Int,
  expected : Int,
) -> Unit = "(shared, index, expected) => { Atomics.wait(shared, index, expected); }"

///|
#borrow(shared)
extern "js" fn atomic_notify_one(shared : SharedInts, index : Int) -> Unit = "(shared, index) => { Atomics.notify(shared, index, 1); }"
