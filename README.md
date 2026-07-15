# mayo

[日本語](./README.ja.md)

Mayo is an experimental zero-copy data-parallel Worker pool for MoonBit. The host is MoonBit
compiled to JavaScript. Ahead-of-time kernels can be MoonBit compiled to JavaScript or to the Wasm
linear-memory backend, and run in Deno or a cross-origin-isolated web page.

Persistent Workers sleep and wake through JavaScript Atomics. Bulk `Int32` data stays in shared
memory; each dispatch publishes only the POD descriptor `(start, end, argument)`. The long-term goal
is a Rayon-like MoonBit API. Scheduling currently uses static, non-overlapping ranges.

> [!WARNING]
> Mayo does not share MoonBit heap objects, closures, strings, or ordinary arrays. A contract
> defines the application-specific layout of the shared `Int32` region. Use offsets and lengths as
> descriptors for variable-size data.

## Data path

```text
MoonBit/JS host
  Pool::values() -> SharedSlice
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
path. Host and guest bundles are compiled separately and bound by a versioned ASCII `KernelContract`
ID.

## JavaScript kernel

Define the same contract ID in host and guest code. Change it whenever the shared layout or kernel
semantics changes incompatibly.

```moonbit
// guest.mbt
let contract = @mayo.kernel_contract("my-app/mix-i32/v1")

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
  @mayo.serve(contract, kernel)
}
```

The MoonBit host starts the prebuilt kernel and owns the shared region:

```moonbit
// host.mbt
async fn main {
  let contract = @mayo.kernel_contract("my-app/mix-i32/v1")
  let pool = @mayo.Pool::create(
    @mayo.kernel_pool_options(
      contract,
      "./guest.js",
      capacity=1048576,
      worker_count=4,
    ),
  )
  defer pool.close()

  let values = pool.values()
  values.fill(1)

  // Deno permits blocking Atomics.wait on its main agent.
  let result = pool.run(end=values.length(), argument=64)

  // Browser document main threads use the asynchronous form.
  // let result = pool.run_async(end=values.length(), argument=64)
  println("dispatch: \{result.elapsed_ms} ms")
}
```

`start` and `end` are logical indices into `SharedSlice`. Worker ranges do not overlap, so
`SharedSlice::load` and `store` deliberately use non-atomic element access. Atomics are used only
for the scheduler control slots.

For structured data, define a POD layout in a small contract package. For example, a descriptor may
store `(input_offset, input_length, output_offset, output_length)` while the arrays themselves
remain in the shared region. Mayo intentionally does not hide this layout behind serialization.

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

| Host runtime | Pool creation  | Dispatch                         | Requirement                           |
| ------------ | -------------- | -------------------------------- | ------------------------------------- |
| Web document | `Pool::create` | `Pool::run_async`                | Cross-origin isolation (COOP + COEP)  |
| Deno         | `Pool::create` | `Pool::run` or `Pool::run_async` | `--allow-read` for local Worker files |
| Node.js      | Not supported  | —                                | Worker adapter is planned             |

Browsers require these headers for the document, Worker, Wasm, and other subresources:

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: same-origin
```

The Playwright suite verifies both JavaScript `SharedArrayBuffer` kernels and Wasm shared-memory
kernels in Chromium, Firefox, and WebKit.

## Public API

- `kernel_contract(id) -> KernelContract`
- `kernel_pool_options(contract, worker_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `wasm_kernel_pool_options(contract, glue_url, wasm_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `Pool::create(options)`
- `Pool::values() -> SharedSlice`
- `Pool::run(start?=0, end~, argument?=0) -> RunResult` for blocking runtimes
- `Pool::run_async(start?=0, end~, argument?=0) -> RunResult` for browser documents; concurrent
  calls wait for the pool in FIFO order
- `Pool::worker_count()` / `Pool::capacity()` / `Pool::close()`
- `serve(contract, kernel)` for JavaScript Workers
- `SharedSlice::length()` / `load()` / `store()` / `fill()`

`pool_options` and `start` remain shortcuts using the built-in `mayo.range/v1` contract.

## Optional JSON compatibility package

`mizchi/mayo/json` is an explicit compatibility layer, not Mayo's primary API. `JsonGuest` supports
arbitrary MoonBit values implementing `ToJson` and `FromJson`, but every call performs JSON
stringify/parse, UTF-8 conversion, allocation, and mailbox copies. It supports JavaScript guests
only; there is no JSON Wasm ABI.

The package exports `JsonContract`, `json_contract`, `JsonGuest`, `json_guest_options`,
`serve_json`, and `JsonError`. See [`examples/sync_contract`](./examples/sync_contract).

## Current limitations

- The shared data region is currently an `Int32Array`.
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
