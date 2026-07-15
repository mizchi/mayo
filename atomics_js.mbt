///|
/// Opaque control view backed by a host `SharedArrayBuffer`.
#external
pub type SharedInts

///|
#external
pub type SharedSlice

///|
extern "js" fn data_slice(
  shared : SharedInts,
  offset : Int,
  worker_id : Int,
) -> SharedSlice =
  #| (shared, offset, workerId) => {
  #|   const view = new Int32Array(
  #|     shared.buffer,
  #|     shared.byteOffset + offset * Int32Array.BYTES_PER_ELEMENT,
  #|     shared.length - offset,
  #|   );
  #|   Object.defineProperty(view, "__mayo_worker_id", { value: workerId });
  #|   return view;
  #| }

///|
/// Returns the stable pool-local Worker ID for a Guest kernel view.
/// Host-side views return `-1`.
#borrow(self)
pub extern "js" fn SharedSlice::worker_id(self : SharedSlice) -> Int = "(self) => self.__mayo_worker_id ?? -1"

///|
/// Returns the number of elements in this shared data view.
#borrow(self)
pub extern "js" fn SharedSlice::length(self : SharedSlice) -> Int = "(self) => self.length | 0"

///|
/// Returns the byte length of this shared data view.
#borrow(self)
pub extern "js" fn SharedSlice::byte_length(self : SharedSlice) -> Int = "(self) => self.byteLength | 0"

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
#borrow(left, right)
extern "js" fn shared_slice_same_buffer(
  left : SharedSlice,
  right : SharedSlice,
) -> Bool = "(left, right) => left.buffer === right.buffer"

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
/// Atomically claims `[current, min(current + grain, end))` without allowing
/// the shared cursor to wrap past the signed Int32 range.
#borrow(shared)
extern "js" fn atomic_claim_chunk(
  shared : SharedInts,
  index : Int,
  end : Int,
  grain : Int,
) -> Int =
  #| (shared, index, end, grain) => {
  #|   while (true) {
  #|     const current = Atomics.load(shared, index);
  #|     if (current >= end) return end;
  #|     const next = Math.min(current + grain, end);
  #|     if (Atomics.compareExchange(shared, index, current, next) === current) {
  #|       return current;
  #|     }
  #|   }
  #| }

///|
extern "js" fn worker_performance_now() -> Double = "() => performance.now()"

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
