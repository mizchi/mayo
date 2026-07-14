///|
#owned(counter_handler, transform_handler, atomic_pool_handler)
extern "js" fn install_worker(
  counter_handler : (@mayo.SharedInts, Int) -> Int,
  transform_handler : (@mayo.SharedInts, Int, Int, Int) -> Unit,
  atomic_pool_handler : (@mayo.SharedInts, Int, Int) -> Unit,
) -> Unit =
  #|(counterHandler, transformHandler, atomicPoolHandler) => {
  #|  let sharedInts;
  #|  globalThis.onmessage = (event) => {
  #|    const message = event.data;
  #|    if (message.type === "init") {
  #|      sharedInts = new Int32Array(message.shared);
  #|      globalThis.postMessage({ type: "initialized", id: message.id });
  #|      return;
  #|    }
  #|    if (message.type === "atomic-init") {
  #|      sharedInts = new Int32Array(message.shared);
  #|      globalThis.postMessage({ type: "initialized", id: message.id });
  #|      atomicPoolHandler(sharedInts, message.slotBase, message.dataOffset);
  #|      return;
  #|    }
  #|    if (message.type === "counter") {
  #|      globalThis.postMessage({ type: "ready", id: message.id });
  #|      const startedAt = performance.now();
  #|      const observedCounter = counterHandler(sharedInts, message.iterations);
  #|      const executionMs = performance.now() - startedAt;
  #|      globalThis.postMessage({
  #|        type: "result",
  #|        id: message.id,
  #|        executionMs,
  #|        observedCounter,
  #|      });
  #|      return;
  #|    }
  #|    if (message.type === "transform") {
  #|      const startedAt = performance.now();
  #|      transformHandler(
  #|        sharedInts,
  #|        message.start,
  #|        message.end,
  #|        message.computeRounds,
  #|      );
  #|      globalThis.postMessage({
  #|        type: "transformed",
  #|        id: message.id,
  #|        batchId: message.batchId,
  #|        executionMs: performance.now() - startedAt,
  #|      });
  #|    }
  #|  };
  #|  globalThis.postMessage({ type: "online" });
  #|}

///|
fn main {
  install_worker(run_counter, run_transform, fn(
    shared,
    slot_base,
    data_offset,
  ) {
    @mayo.run_worker(shared, slot_base, data_offset, run_atomic_transform)
  })
}
