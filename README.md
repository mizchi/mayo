# mayo

[日本語](./README.ja.md)

Mayo is an experimental zero-copy data-parallel Worker pool for MoonBit. The host is MoonBit
compiled to JavaScript. Ahead-of-time kernels can be MoonBit compiled to JavaScript or to the Wasm
linear-memory backend, and run in Deno or a cross-origin-isolated web page.

Persistent Workers sleep and wake through JavaScript Atomics. Bulk `Int32` data stays in shared
memory; each dispatch publishes only the POD descriptor `(start, end, argument)`. The long-term goal
is a Rayon-like MoonBit API. Scheduling currently uses static, non-overlapping ranges.

> [!WARNING]
> Mayo does not share MoonBit heap objects, closures, strings, or ordinary arrays. `KernelCall` is
> an opaque descriptor for an ahead-of-time kernel, not a transferable closure. Use offsets and
> lengths inside shared memory for variable-size data.

## Data path

```text
MoonBit/JS host
  ThreadPool::shared_i32() -> SharedI32
          │
          │ same SharedArrayBuffer / shared WebAssembly.Memory
          ▼
┌──────────────────────────────────────────────────────────┐
│ control slots │ POD descriptors │ application data      │
└──────────────────────────────────────────────────────────┘
          ▲                         ▲
          │ direct load/store       │ direct load/store
 MoonBit/JS Worker             MoonBit/Wasm Worker
```

There is no JSON, UTF-8 conversion, `postMessage` payload clone, or SAB-to-Wasm payload copy in this
path. The primary JavaScript facade uses a manifest-bound `mayo.kernel/v1` ABI. Raw custom contracts
and Wasm kernels retain an explicit versioned `KernelContract` handshake.

## ThreadPool facade

Define the manifest once in a descriptor package imported by both Host and Guest builds:

```moonbit
fn mix_spec() -> @mayo.KernelSpec {
  @mayo.kernel_spec(id=1, layout_hash=0x4D495801)
}

pub fn manifest() -> @mayo.KernelManifest {
  @mayo.kernel_manifest("my-app/i32-kernels/v1", [mix_spec()])
}

pub fn mix(rounds~ : Int) -> @mayo.KernelCall {
  @mayo.kernel_call(manifest(), mix_spec(), argument=rounds)
}

pub fn mix_entry(
  implementation : (@mayo.SharedSlice, Int, Int, Int) -> Unit,
) -> @mayo.KernelEntry {
  @mayo.kernel_entry(mix_spec(), implementation)
}
```

Compile the Worker implementation ahead of time and bind it to the generated entry:

```moonbit
// guest.mbt
fn kernel(values : @mayo.SharedSlice, start : Int, end : Int, rounds : Int) {
  for index = start; index < end; index = index + 1 {
    let mut value = values.load(index)
    for round = 0; round < rounds; round = round + 1 {
      value = mix(value)
    }
    values.store(index, value)
  }
}

fn main {
  @mayo.serve_kernels(
    @kernels.manifest(),
    [@kernels.mix_entry(kernel)],
  )
}
```

The host does not repeat a contract string or scheduler descriptor:

```moonbit
// host.mbt
async fn main {
  let threads = @mayo.ThreadPool::open(
    @kernels.manifest(),
    "./guest.js",
    capacity=1048576,
    workers=4,
  )
  defer threads.close()

  let values = threads.shared_i32()
  values.fill(1)

  let result = values.par_for(@kernels.mix(rounds=64))
  println("dispatch: \{result.elapsed_ms} ms")
}
```

`@kernels.mix` is a named Host wrapper returning a manifest-bound `KernelCall`. The package is
currently small and manual; it is also the intended output shape of a future descriptor generator.
One Worker artifact can register multiple kernel entries.

Multiple calls can use structured concurrency. Calls on one pool enter in FIFO order; each call
partitions its own range across every Worker:

```moonbit
let (first, second) = threads.scope(scope => {
  let first = scope.spawn(@kernels.mix(rounds=2))
  let second = scope.spawn(@kernels.mix(rounds=1))
  (first.join(), second.join())
})
```

`start` and `end` are logical indices into `SharedSlice`. Worker ranges do not overlap, so
`SharedSlice::load` and `store` deliberately use non-atomic element access. Atomics are used only
for the scheduler control slots.

For structured data, define a POD layout in a small contract package. For example, a descriptor may
store `(input_offset, input_length, output_offset, output_length)` while the arrays themselves
remain in the shared region. Mayo intentionally does not hide this layout behind serialization.

## Real-world example: image pipeline

The image example processes a 640x360 packed-RGB frame with two ahead-of-time kernels: integer
grayscale conversion followed by thresholded Sobel edge detection. Its shared layout is explicit:

| Region  |      Int32 words | Role                                    |
| ------- | ---------------: | --------------------------------------- |
| Header  |                8 | Magic, dimensions, offsets, pixel count |
| Source  | `width * height` | Input RGB, then final Sobel output      |
| Scratch | `width * height` | Grayscale intermediate                  |

The first dispatch writes `source -> scratch`. Completion of `par_for` is the barrier before the
second dispatch reads `scratch -> source`; neither the frame nor the intermediate result crosses a
Worker mailbox.

```moonbit
let layout = @image.image_layout(width=640, height=360)
let threads = @mayo.ThreadPool::open(
  @image.manifest(),
  "./image_worker.js",
  capacity=layout.capacity(),
  workers=3,
)
let values = threads.shared_i32()
layout.initialize(values, source_pixels)

ignore(values.par_for(@image.grayscale(), end=layout.pixel_count()))
ignore(values.par_for(
  @image.detect_edges(threshold=64),
  end=layout.pixel_count(),
))
```

The complete code is split into the shared
[`image_pipeline`](./examples/image_pipeline/pipeline.mbt) contract, the prebuilt
[`image_worker`](./examples/image_worker/main.mbt), and the MoonBit
[`image_host`](./examples/image_host/main.mbt). Run it with `just example-image`.

## Raw custom contracts

`Pool`, `kernel_contract`, `kernel_pool_options`, and `serve` remain available when an application
needs an explicit semantic/layout handshake. They are the compatibility and implementation layer
beneath `ThreadPool`.

The normative Host/Guest glue convention is documented in
[`docs/kernel-abi-v1.md`](./docs/kernel-abi-v1.md).

## Wasm kernel

Wasm kernels use the same pool and data layout. The generic JavaScript glue instantiates every
kernel with one imported shared `WebAssembly.Memory`; all Workers and the host access the same
bytes.

```moonbit
fn kernel(data_offset : Int, start : Int, end : Int, rounds : Int) {
  // Allocation-free POD computation.
  // Use @abi.load_i32(data_offset, index) and @abi.store_i32(...).
}

pub fn mayo_abi_version() -> Int { @abi.abi_version() }
pub fn mayo_contract_hash() -> Int { @contract.contract_hash() }
pub fn mayo_run(data_offset : Int, capacity : Int, start : Int, end : Int, argument : Int) -> Int {
  if !@abi.descriptor_is_valid(data_offset, capacity, start, end) { return -1 }
  kernel(data_offset, start, end, argument)
  0
}
```

The guest package imports bounded memory and exports the ABI v2 functions:

```moonbit
options(
  link: {
    "wasm": {
      "exports": ["mayo_abi_version", "mayo_contract_hash", "mayo_run"],
      "import-memory": { "module": "env", "name": "memory" },
      "memory-limits": { "min": 64, "max": 512 },
      "heap-start-address": 3145728,
    },
  },
)
```

MoonBit currently emits this import as non-shared. `just build-wasm` applies
[`wasm/patch_shared_memory.ts`](./wasm/patch_shared_memory.ts), which changes only the memory limits
flag and validates the resulting import. The host then uses:

```moonbit
let pool = @mayo.Pool::create(
  @mayo.wasm_kernel_pool_options(
    @mayo.kernel_contract(@contract.contract_id()),
    "./mayo_wasm_kernel.js",
    "./kernel.wasm",
    capacity=1048576,
    worker_count=4,
  ),
)
```

Wasm kernels on this path must be allocation-free and operate only on POD values through `load_i32`
/ `store_i32`. The exported contract hash must also be an ahead-of-time integer literal; computing
it from a String inside Wasm may allocate. Sharing a MoonBit runtime heap between independent Wasm
instances is not supported. See [`examples/wasm_guest`](./examples/wasm_guest) and
[`examples/wasm_host`](./examples/wasm_host).

## Browser and Deno

| Host runtime | Pool creation      | Dispatch           | Requirement                           |
| ------------ | ------------------ | ------------------ | ------------------------------------- |
| Web document | `ThreadPool::open` | `par_for` / `join` | Cross-origin isolation (COOP + COEP)  |
| Deno         | `ThreadPool::open` | `par_for` / `join` | `--allow-read` for local Worker files |
| Node.js      | Not supported      | —                  | Worker adapter is planned             |

Browsers require these headers for the document, Worker, Wasm, and other subresources:

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: same-origin
```

The Playwright suite verifies both JavaScript `SharedArrayBuffer` kernels and Wasm shared-memory
kernels in Chromium, Firefox, and WebKit.

## Primary API

- `kernel_spec(id~, layout_hash~) -> KernelSpec`
- `kernel_manifest(id, specs) -> KernelManifest`
- `kernel_call(manifest, spec, argument?=0) -> KernelCall`
- `kernel_entry(spec, implementation) -> KernelEntry`
- `serve_kernels(manifest, entries)`
- `ThreadPool::open(manifest, worker_url, capacity~, workers?=4, timeout_ms?=30000)`
- `ThreadPool::shared_i32() -> SharedI32`
- `SharedI32::par_for(kernel, start?=0, end?=length) -> RunResult`
- `ThreadPool::scope(body)` / `ThreadScope::spawn(kernel)` / `JoinHandle::join()`
- `ThreadPool::worker_count()` / `capacity()` / `close()`
- `SharedI32::length()` / `load()` / `store()` / `fill()`

## Raw API

- `kernel_manifest_pool_options(manifest, worker_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `kernel_contract(id) -> KernelContract`
- `kernel_pool_options(contract, worker_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `wasm_kernel_pool_options(contract, glue_url, wasm_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `Pool::create(options)`
- `Pool::values() -> SharedSlice`
- `Pool::run(start?=0, end~, argument?=0) -> RunResult` for blocking runtimes
- `Pool::run_async(start?=0, end~, argument?=0) -> RunResult` for browser documents; concurrent
  calls wait for the pool in FIFO order
- `Pool::run_kernel(kernel, start?=0, end~) -> RunResult` for manifest-bound blocking runtimes
- `Pool::worker_count()` / `Pool::capacity()` / `Pool::close()`
- `serve(contract, kernel)` for JavaScript Workers
- `SharedSlice::length()` / `load()` / `store()` / `fill()`

`ThreadPool` uses the manifest-bound `mayo.kernel/v1` ABI. `pool_options` and `start` retain the
built-in single-kernel `mayo.range/v1` compatibility ABI.

## Optional JSON compatibility package

`mizchi/mayo/json` is an explicit compatibility layer, not Mayo's primary API. `JsonGuest` supports
arbitrary MoonBit values implementing `ToJson` and `FromJson`, but every call performs JSON
stringify/parse, UTF-8 conversion, allocation, and mailbox copies. It supports JavaScript guests
only; there is no JSON Wasm ABI.

The package exports `JsonContract`, `json_contract`, `JsonGuest`, `json_guest_options`,
`serve_json`, and `JsonError`. See [`examples/sync_contract`](./examples/sync_contract).

## Current limitations

- The shared data region is currently an `Int32Array`.
- Descriptor packages are currently written manually; automatic generation is not implemented yet.
- A dispatch has one range and one additional `Int` argument.
- Scheduling uses static chunks; dynamic grains and work stealing are not implemented.
- Wasm kernels must not allocate or use shared MoonBit heap objects.
- Wasm shared memory is limited to 512 pages (32 MiB), including the MoonBit runtime image.
- Cancellation, Worker crash recovery, and kernel panic propagation are not implemented.
- MoonBit has no equivalent of Rust's `Send` / `Sync` checking for this boundary.
- Web pages must be cross-origin isolated.
- Node.js is not supported yet.

## Development

```console
just test          # MoonBit, Deno, browser, Rust, and C tests
just check         # formatting, linting, type checks, native checks, and tests
just test-web      # Chromium / Firefox / WebKit integration
just serve-web     # COOP/COEP web example server
just example       # MoonBit/JS Deno pool
just example-wasm  # MoonBit/JS host and shared-memory MoonBit/Wasm kernel
just example-json  # optional JSON compatibility example
just compare 4     # pthread / mmap process / Rust / Rayon comparison
```

## Benchmark

`just compare 4` creates each pool and shared region once. Timed batches publish only a range and
round count; Worker/process startup and data copying are excluded. `Mayo` is the MoonBit/JS kernel;
`Mayo Wasm` is the allocation-free shared `WebAssembly.Memory` kernel.

Median of five independent runs on 2026-07-15: Mac17,2, 32 GiB, 10 logical CPUs, darwin-aarch64,
Deno 2.6.4, MoonBit 0.1.20260713.

| backend         | dispatch p50 | dispatch p95 | memory bandwidth | compute throughput |
| --------------- | -----------: | -----------: | ---------------: | -----------------: |
| C pthread       |      9.00 µs |      20.0 µs |       77.2 GiB/s |        5.83 Gops/s |
| C mmap process  |      11.0 µs |      23.0 µs |       76.8 GiB/s |        8.25 Gops/s |
| Rust std pool   |      8.75 µs |      18.9 µs |       81.3 GiB/s |        9.56 Gops/s |
| Rust Rayon      |      13.7 µs |      29.5 µs |       71.8 GiB/s |        6.79 Gops/s |
| MoonBit message |      43.9 µs |      76.6 µs |       14.2 GiB/s |        6.40 Gops/s |
| Mayo JS         |      10.0 µs |      22.5 µs |       20.6 GiB/s |        8.55 Gops/s |
| Mayo Wasm       |      10.6 µs |      25.4 µs |       26.6 GiB/s |        6.54 Gops/s |

In these runs, Mayo JS dispatch p50 was 1.12× pthread and Mayo Wasm was 1.18×. Their memory cases
reached 26.7% and 34.5% of pthread bandwidth respectively. Mayo JS compute throughput was 1.47×
pthread; Mayo Wasm was 1.12×. Treat local `just compare` results as authoritative because core
assignment, temperature, power state, and runtime versions matter.

## Roadmap

1. Typed POD descriptors for multiple arguments and shared slices
2. Dynamic chunk counters with configurable grain size
3. A shared task ring and per-Worker Chase–Lev deques
4. Work stealing, cancellation, and task recovery
5. Higher-level `par_for` and `par_chunks` APIs
6. A Node.js Worker adapter

Inspired by
[an experiment using shared memory and mutexes with Rust/Wasm](https://zenn.dev/grainrigi/articles/b7c2320ef13c71).

## License

MIT
