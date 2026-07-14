///|
/// Runs the persistent Mayo Worker loop for one host-assigned slot.
///
/// The kernel receives logical indices into `SharedSlice` and one signed
/// 32-bit, kernel-specific argument.
pub fn run_worker(
  shared : SharedInts,
  slot_base : Int,
  data_offset : Int,
  kernel : (SharedSlice, Int, Int, Int) -> Unit,
) -> Unit {
  let values = data_slice(shared, data_offset)
  let mut seen_epoch = atomic_load(shared, slot_base + CONTROL_EPOCH)
  atomic_store(shared, slot_base + CONTROL_DONE_EPOCH, -1)
  atomic_notify_one(shared, slot_base + CONTROL_DONE_EPOCH)
  while true {
    while atomic_load(shared, slot_base + CONTROL_EPOCH) == seen_epoch {
      atomic_wait(shared, slot_base + CONTROL_EPOCH, seen_epoch)
    }
    seen_epoch = atomic_load(shared, slot_base + CONTROL_EPOCH)
    if atomic_load(shared, slot_base + CONTROL_STOP) != 0 {
      return
    }
    let start = atomic_load(shared, slot_base + CONTROL_RANGE_START)
    let end = atomic_load(shared, slot_base + CONTROL_RANGE_END)
    let argument = atomic_load(shared, slot_base + CONTROL_ARGUMENT)
    kernel(values, start, end, argument)
    atomic_store(shared, slot_base + CONTROL_DONE_EPOCH, seen_epoch)
    atomic_notify_one(shared, slot_base + CONTROL_DONE_EPOCH)
  }
}
