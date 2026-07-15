///|
priv struct DispatchResult {
  status : Int
  result : Int
}

///|
/// Runs the shared persistent Worker loop for one host-assigned slot.
fn run_dispatch_worker(
  shared : SharedInts,
  slot_base : Int,
  data_offset : Int,
  dispatch : (SharedSlice, Int, Int, Int, Int, Int) -> DispatchResult,
) -> Unit {
  let worker_id = slot_base / CONTROL_SLOT_LENGTH
  let values = data_slice(shared, data_offset, worker_id)
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
    let grain = atomic_load(shared, slot_base + CONTROL_GRAIN)
    let worker_count = atomic_load(shared, CONTROL_WORKER_COUNT)
    let cancel_baseline = atomic_load(
      shared,
      slot_base + CONTROL_CANCEL_BASELINE,
    )
    let started_at = worker_performance_now()
    let outcome = if grain > 0 {
      let mut dynamic_status = KERNEL_STATUS_OK
      let mut dynamic_result = 0
      for offset = 0; offset < worker_count; offset = offset + 1 {
        let victim = (worker_id + offset) % worker_count
        let victim_base = victim * CONTROL_SLOT_LENGTH
        let victim_end = atomic_load(shared, victim_base + CONTROL_RANGE_END)
        while dynamic_status == KERNEL_STATUS_OK {
          if atomic_load(shared, CONTROL_CANCEL_SEQUENCE) != cancel_baseline {
            dynamic_status = KERNEL_STATUS_CANCELLED
            break
          }
          let chunk_start = atomic_claim_chunk(
            shared,
            victim_base + CONTROL_DYNAMIC_CURSOR,
            victim_end,
            grain,
          )
          if chunk_start >= victim_end {
            break
          }
          let chunk_end = if victim_end - chunk_start < grain {
            victim_end
          } else {
            chunk_start + grain
          }
          let chunk_outcome = dispatch(
            values, chunk_start, chunk_end, kernel_id, layout_hash, argument,
          )
          dynamic_status = chunk_outcome.status
          dynamic_result = chunk_outcome.result
          if dynamic_status == KERNEL_STATUS_OK &&
            atomic_load(shared, CONTROL_CANCEL_SEQUENCE) != cancel_baseline {
            dynamic_status = KERNEL_STATUS_CANCELLED
          }
        }
      }
      { status: dynamic_status, result: dynamic_result }
    } else {
      dispatch(values, start, end, kernel_id, layout_hash, argument)
    }
    let elapsed_us = ((worker_performance_now() - started_at) * 1000.0).to_int()
    atomic_store(
      shared,
      slot_base + CONTROL_ELAPSED_US,
      if elapsed_us < 1 {
        1
      } else {
        elapsed_us
      },
    )
    atomic_store(shared, slot_base + CONTROL_RESULT, outcome.result)
    atomic_store(shared, slot_base + CONTROL_STATUS, outcome.status)
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
    { status: KERNEL_STATUS_OK, result: 0 }
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
          return { status: KERNEL_STATUS_LAYOUT_MISMATCH, result: 0 }
        }
        let result = (entry.kernel_)(values, start, end, argument)
        return { status: KERNEL_STATUS_OK, result }
      }
    }
    { status: KERNEL_STATUS_UNKNOWN, result: 0 }
  })
}
