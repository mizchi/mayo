///|
#owned(worker_handler)
extern "js" fn install_atomic_worker(
  protocol_id : String,
  worker_handler : (SharedInts, Int, Int) -> Unit,
) -> Unit =
  #|(protocolId, workerHandler) => {
  #|  globalThis.onmessage = (event) => {
  #|    const message = event.data;
  #|    if (message.type !== "atomic-init") return;
  #|    const shared = new Int32Array(
  #|      message.shared,
  #|      message.controlOffset * Int32Array.BYTES_PER_ELEMENT,
  #|    );
  #|    globalThis.postMessage({ type: "initialized", id: message.id });
  #|    workerHandler(shared, message.slotBase, message.dataOffset);
  #|  };
  #|  globalThis.postMessage({ type: "online", protocol: protocolId });
  #|}

///|
/// Installs a kernel as a Mayo-compatible Web Worker entry point.
///
/// The host partitions every dispatched range into non-overlapping chunks.
/// Compile the executable containing this call before creating a host `Pool`.
pub fn start(kernel : (SharedSlice, Int, Int, Int) -> Unit) -> Unit {
  serve(kernel_contract(RANGE_PROTOCOL_ID), kernel)
}

///|
/// Installs a JavaScript kernel using an explicit versioned shared-memory
/// contract. Host and guest are compiled separately and must use the same ID.
pub fn serve(
  contract : KernelContract,
  kernel : (SharedSlice, Int, Int, Int) -> Unit,
) -> Unit {
  install_atomic_worker(contract.id_, fn(shared, slot_base, data_offset) {
    run_worker(shared, slot_base, data_offset, kernel)
  })
}

///|
fn validate_kernel_entries(
  manifest : KernelManifest,
  entries : Array[KernelEntry],
) -> Unit {
  if entries.length() != manifest.kernels_.length() {
    abort("kernel entries do not match manifest length")
  }
  for index = 0; index < entries.length(); index = index + 1 {
    let expected = manifest.kernels_[index]
    let actual = entries[index].spec_
    if actual.id_ != expected.id_ ||
      actual.layout_hash_ != expected.layout_hash_ {
      abort("kernel entries do not match manifest order or layout")
    }
  }
}

///|
/// Installs a manifest-bound, multi-kernel JavaScript Worker entry point.
/// Host descriptors and Guest entries must be created from the same manifest.
pub fn serve_kernels(
  manifest : KernelManifest,
  entries : Array[KernelEntry],
) -> Unit {
  let copied = entries.copy()
  validate_kernel_entries(manifest, copied)
  install_atomic_worker(manifest.protocol_id_, fn(
    shared,
    slot_base,
    data_offset,
  ) {
    run_kernel_worker(shared, slot_base, data_offset, copied)
  })
}
