///|
/// Runs the shared persistent Worker loop for one host-assigned slot.
fn run_dispatch_worker(
  shared : SharedInts,
  slot_base : Int,
  data_offset : Int,
  dispatch : (SharedSlice, Int, Int, Int, Int, Int) -> Int,
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
    let kernel_id = atomic_load(shared, slot_base + CONTROL_KERNEL_ID)
    let layout_hash = atomic_load(shared, slot_base + CONTROL_LAYOUT_HASH)
    let status = dispatch(values, start, end, kernel_id, layout_hash, argument)
    atomic_store(shared, slot_base + CONTROL_STATUS, status)
    atomic_store(shared, slot_base + CONTROL_DONE_EPOCH, seen_epoch)
    atomic_notify_one(shared, slot_base + CONTROL_DONE_EPOCH)
  }
}

///|
/// Runs a persistent Mayo Worker loop for one host-assigned raw range kernel.
pub fn run_worker(
  shared : SharedInts,
  slot_base : Int,
  data_offset : Int,
  kernel : (SharedSlice, Int, Int, Int) -> Unit,
) -> Unit {
  run_dispatch_worker(shared, slot_base, data_offset, fn(
    values,
    start,
    end,
    _kernel_id,
    _layout_hash,
    argument,
  ) {
    kernel(values, start, end, argument)
    KERNEL_STATUS_OK
  })
}

///|
fn run_kernel_worker(
  shared : SharedInts,
  slot_base : Int,
  data_offset : Int,
  entries : Array[KernelEntry],
) -> Unit {
  run_dispatch_worker(shared, slot_base, data_offset, fn(
    values,
    start,
    end,
    kernel_id,
    layout_hash,
    argument,
  ) {
    for entry in entries {
      if entry.spec_.id_ == kernel_id {
        if entry.spec_.layout_hash_ != layout_hash {
          return KERNEL_STATUS_LAYOUT_MISMATCH
        }
        (entry.kernel_)(values, start, end, argument)
        return KERNEL_STATUS_OK
      }
    }
    KERNEL_STATUS_UNKNOWN
  })
}
