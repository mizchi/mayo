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
