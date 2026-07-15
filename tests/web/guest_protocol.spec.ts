import { expect, test } from "@playwright/test";

test("optional JSON guest completes one raw dispatch", async ({ page }) => {
  await page.goto("/");
  const state = await page.evaluate(async () => {
    const worker = new Worker(new URL("./json_guest.js", location.href), { type: "module" });
    await new Promise<void>((resolve, reject) => {
      worker.addEventListener("message", (event) => {
        if (event.data?.type === "online") resolve();
      });
      worker.addEventListener("error", (event) => reject(event.error ?? new Error(event.message)));
    });
    const dataOffset = 16;
    const buffer = new SharedArrayBuffer((dataOffset + 1024) * 4);
    const shared = new Int32Array(buffer);
    await new Promise<void>((resolve, reject) => {
      worker.addEventListener("message", (event) => {
        if (event.data?.type === "initialized") resolve();
      });
      worker.addEventListener("error", (event) => reject(event.error ?? new Error(event.message)));
      worker.postMessage({ type: "atomic-init", id: 0, shared: buffer, slotBase: 0, dataOffset });
    });
    const readyDeadline = performance.now() + 5_000;
    while (Atomics.load(shared, 1) !== -1) {
      if (performance.now() >= readyDeadline) throw new Error("JSON guest ready timed out");
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    const request = new TextEncoder().encode(
      JSON.stringify({ name: "Raw", values: [3, 5, 8], scale: 4 }),
    );
    new Uint8Array(buffer, (dataOffset + 4) * 4, request.length).set(request);
    shared[dataOffset] = request.length;
    Atomics.store(shared, 2, 0);
    Atomics.store(shared, 3, 0);
    Atomics.store(shared, 4, 0);
    Atomics.store(shared, 5, 0);
    Atomics.store(shared, 0, 1);
    Atomics.notify(shared, 0, 1);
    const deadline = performance.now() + 5_000;
    while (Atomics.load(shared, 1) !== 1) {
      if (performance.now() >= deadline) throw new Error("JSON guest dispatch timed out");
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    const responseLength = shared[dataOffset + 1];
    const response = new TextDecoder().decode(
      new Uint8Array(buffer, (dataOffset + 4) * 4, responseLength).slice(),
    );
    const result = {
      done: Atomics.load(shared, 1),
      status: shared[dataOffset + 2],
      response,
    };
    worker.terminate();
    return result;
  });
  expect(state).toEqual({
    done: 1,
    status: 1,
    response: '{"message":"hello Raw","total":64,"item_count":3}',
  });
});
