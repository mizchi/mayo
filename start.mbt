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
  #|    const shared = new Int32Array(message.shared);
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
  install_atomic_worker(RANGE_PROTOCOL_ID, fn(shared, slot_base, data_offset) {
    run_worker(shared, slot_base, data_offset, kernel)
  })
}
