# mayo

[日本語](./README.ja.md)

Mayo is an experimental data-parallel Worker pool for MoonBit. The host client is written in MoonBit
and compiled to JavaScript; guest handlers can be compiled ahead of time to either JavaScript or
WebAssembly and run in a modern web browser or Deno.

Data and task descriptors are shared through `SharedArrayBuffer`. Persistent Workers sleep and wake
through JavaScript Atomics, so Worker startup is amortized across many batches. The long-term goal
is a Rayon-like MoonBit API; the current scheduler uses static, non-overlapping chunks rather than
work stealing.

> [!WARNING]
> Mayo is experimental. MoonBit heap objects, closures, and ordinary objects are not directly shared
> across Workers. The typed API serializes values into a UTF-8 JSON mailbox in shared memory; the
> low-level API exposes an `Int32Array`-backed `SharedSlice` for zero-copy numeric data.

## Runtime support

| Host runtime | Pool creation     | Dispatch API                             | Requirement                           |
| ------------ | ----------------- | ---------------------------------------- | ------------------------------------- |
| Web document | `Pool::create`    | `Pool::run_async`                        | Cross-origin isolation (COOP + COEP)  |
| Deno         | `Pool::create`    | `Pool::run` (recommended) or `run_async` | `--allow-read` for local Worker files |
| Node.js      | Not supported yet | —                                        | A Worker adapter is planned           |

[`Atomics.wait`](https://tc39.es/ecma262/multipage/structured-data.html#sec-atomics.wait) blocks and
is not permitted on a browser document main thread. Mayo therefore uses
[`Atomics.waitAsync`](https://tc39.es/ecma262/multipage/structured-data.html#sec-atomics.waitasync)
for browser dispatch and falls back to timer-based asynchronous polling when the runtime does not
expose it. Calling synchronous `Pool::run` from a web document raises `PoolError::InvalidArgument`
with a message directing the caller to `run_async`.

## Architecture

```text
MoonBit host client                         MoonBit Worker kernel
  Pool::create / run_async                    @mayo.start(kernel)
           │                                           │
           └──── compile with MoonBit JS backend ──────┘
                              │
                    Browser or Deno runtime
                              │
                 SharedArrayBuffer (zero-copy)
                   ├─ Worker 0 control slot
                   ├─ Worker 1 control slot
                   └─ Int32 data region
```

Each Worker sleeps until the epoch in its control slot changes. A dispatch partitions `[start, end)`
into non-overlapping ranges and completes when every Worker publishes the expected done epoch.

Only the runtime boundary that touches `Worker`, `SharedArrayBuffer`, Atomics, promises, and
`performance.now()` is JavaScript FFI. Option validation, range partitioning, lifecycle state, and
dispatch are implemented in MoonBit.

## Typed host/guest contract

The recommended boundary compiles a host and guest as two separate MoonBit executables. Both import
a small contract package containing the request type, response type, and a stable versioned ID.

```text
contract.mbt                    imported at compile time
  Request / Response                    │
  "my-app/task/v1"              ┌───────┴───────┐
                                │               │
host.mbt -> host.js        guest.mbt -> guest.js
  SyncGuest::call             serve_sync
         └──── SharedArrayBuffer JSON mailbox ────┘
```

Define the shared contract with MoonBit's standard JSON traits:

```moonbit
pub(all) struct SumRequest {
  name : String
  values : Array[Int]
  scale : Int
} derive(ToJson, FromJson)

pub(all) struct SumResponse {
  message : String
  total : Int
} derive(ToJson, FromJson)

pub fn contract() -> @mayo.SyncContract[SumRequest, SumResponse] {
  @mayo.sync_contract("my-app/sum/v1")
}
```

Compile the guest with its typed handler:

```moonbit
fn handle(request : @contract.SumRequest) -> @contract.SumResponse {
  // Compute a response from the decoded value.
}

fn main {
  @mayo.serve_sync(@contract.contract(), handle)
}
```

The MoonBit host starts the prebuilt guest and checks its contract ID during the Worker handshake:

```moonbit
async fn main {
  let guest = @mayo.SyncGuest::create(
    @contract.contract(),
    @mayo.sync_guest_options("./guest.js", mailbox_bytes=65536),
  )
  defer guest.close()

  // Deno: blocking Atomics.wait
  let response = guest.call({ name: "MoonBit", values: [3, 5, 8], scale: 4 })

  // Browser document: use the non-blocking form instead.
  // let response = guest.call_async(request)
}
```

See [`examples/sync_contract`](./examples/sync_contract),
[`examples/sync_guest`](./examples/sync_guest), and [`examples/sync_host`](./examples/sync_host).
`just build-worker` produces separate `dist/sync_host.js` and `dist/sync_guest.js` files;
`deno run --allow-read dist/sync_host.js` runs the end-to-end example.

Any nested MoonBit value implementing `ToJson` and `FromJson` can cross this boundary, including
derived structs, enums, arrays, maps, strings, and optional values. It is copied into and out of the
mailbox, not made into a concurrently shared heap object. Requests larger than `mailbox_bytes` raise
`SyncError::CapacityExceeded`. A mismatched version ID rejects `SyncGuest::create` before dispatch.
Change the ID whenever the request or response schema changes incompatibly.

## MoonBit/Wasm guest

The host API stays the same when the guest handler is compiled with MoonBit's `wasm` linear-memory
backend. Worker construction, Atomics, and Wasm instantiation live in the generic
[`wasm/guest_runtime.js`](./wasm/guest_runtime.js) glue; JSON decoding, the typed handler, and JSON
encoding execute inside Wasm.

```text
MoonBit/JS host
  SyncGuest::call / call_async
            │ SharedArrayBuffer mailbox
generic JS Worker glue
            │ copy UTF-8 bytes
MoonBit/Wasm guest
  FromJson -> handler -> ToJson
```

The contract package must support both targets and must not import the JS-only Mayo host package. It
contains the derived request/response types and one stable `contract_id()` string. The Wasm guest
imports that package and [`mizchi/mayo/wasm/abi`](./wasm/abi/abi.mbt):

```moonbit
fn handle(request : @contract.WasmSumRequest) -> @contract.WasmSumResponse {
  // Runs inside Wasm.
}

pub fn mayo_abi_version() -> Int { @abi.abi_version() }
pub fn mayo_abi_capacity() -> Int { @abi.abi_capacity() }
pub fn mayo_contract_hash() -> Int {
  @abi.contract_hash(@contract.contract_id())
}
pub fn mayo_request_ptr() -> Int { @abi.request_ptr() }
pub fn mayo_response_ptr() -> Int { @abi.response_ptr() }
pub fn mayo_handle(length : Int) -> Int {
  @abi.handle_sync(length, handle)
}
```

Export these six functions and linear memory in the guest package's Wasm link options. See
[`examples/wasm_guest/moon.pkg`](./examples/wasm_guest/moon.pkg) for the complete configuration.
MoonBit's official documentation describes the Wasm `exports`, `export-memory-name`, memory limits,
and heap start options in its
[package configuration reference](https://docs.moonbitlang.com/en/latest/toolchain/moon/package.html#wasm-backend-link-options).

The MoonBit/JS host selects the generic glue and the `.wasm` artifact:

```moonbit
let guest = @mayo.SyncGuest::create(
  contract,
  @mayo.wasm_sync_guest_options(
    "./mayo_wasm_guest.js",
    "./guest.wasm",
    mailbox_bytes=65536,
  ),
)
let response = guest.call(request)       // Deno
// let response = guest.call_async(request) // Web document
```

`just build-wasm` produces and stages the generic glue and Wasm artifact. `just example-wasm` runs
the separately compiled Deno host/Wasm guest example. The ABI validates both its version and an
FNV-1a hash of the contract ID before the Worker becomes available. ABI v1 accepts a maximum 1 MiB
encoded request or response.

## Low-level zero-copy range API

### 1. Write a MoonBit Worker kernel

[`examples/mix_worker/main.mbt`](./examples/mix_worker/main.mbt) applies an LCG transform to every
element in the assigned range:

```moonbit
fn kernel(
  values : @mayo.SharedSlice,
  start : Int,
  end : Int,
  rounds : Int,
) -> Unit {
  for index = start; index < end; index = index + 1 {
    let mut value = values.load(index)
    for round = 0; round < rounds; round = round + 1 {
      value = mix(value)
    }
    values.store(index, value)
  }
}

fn main {
  @mayo.start(kernel)
}
```

`start` and `end` are logical indices into the shared slice. Worker ranges never overlap, so
`SharedSlice::load` and `store` intentionally use non-atomic element access.

### 2. Use Mayo in a web document

[`examples/web/main.mbt`](./examples/web/main.mbt) is a MoonBit browser client:

```moonbit
async fn main {
  let pool = @mayo.Pool::create(
    @mayo.pool_options(
      "./mayo_worker.js",
      capacity=1048576,
      worker_count=4,
    ),
  )
  defer {
    pool.close()
  }

  let values = pool.values()
  values.fill(1)
  let result = pool.run_async(end=values.length(), argument=64)
  println("dispatch: \{result.elapsed_ms} ms")
}
```

Serve the document and every Worker/subresource with
[cross-origin isolation](https://html.spec.whatwg.org/multipage/webappapis.html#cross-origin-isolated-capability)
enabled. A minimal same-origin configuration uses these response headers:

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: same-origin
```

The repository includes a working server and a browser test:

```console
pnpm install
pnpm exec playwright install chromium firefox webkit
just serve-web   # open http://127.0.0.1:4173
just test-web    # Chromium, Firefox, and WebKit integration
```

The Playwright tests run on Chromium, Firefox, and WebKit. They verify `crossOriginIsolated`, the
zero-copy range pool, the raw typed protocol, and MoonBit `SyncGuest::call_async` round trips to
separately compiled JavaScript and Wasm guests.

### 3. Use Mayo in Deno

[`examples/host/main.mbt`](./examples/host/main.mbt) uses the same MoonBit API. Deno permits
`Atomics.wait` on its main agent, so synchronous `run` gives the lowest dispatch overhead:

```moonbit
let result = pool.run(end=values.length(), argument=64)
```

Build and run the Deno example with:

```console
just example
```

The Worker URL is resolved relative to the generated host module's `import.meta.url`. Local Worker
files require Deno's `--allow-read` permission.

### Host package configuration

Browser and Deno clients both import MoonBit's async runtime because `Pool::create` and `run_async`
are async:

```moonbit
import {
  "mizchi/mayo" @mayo,
  "moonbitlang/async",
}

supported_targets = "js"

pkgtype(kind: "executable")
```

## Public API

### Typed host/guest

- `sync_contract[Request, Response](id) -> SyncContract[Request, Response]`
- `sync_guest_options(worker_url, mailbox_bytes?=1048576, timeout_ms?=30000)`
- `wasm_sync_guest_options(glue_url, wasm_url, mailbox_bytes?=1048576, timeout_ms?=30000)`
- `SyncGuest::create(contract, options)` — starts one persistent guest and checks the contract ID
- `SyncGuest::call(request) -> Response` — blocking Deno API
- `SyncGuest::call_async(request) -> Response` — browser-safe API
- `SyncGuest::mailbox_bytes()` / `SyncGuest::close()`
- `serve_sync(contract, handler)` — installs the typed guest entry point
- `SyncError::{InvalidArgument, CapacityExceeded, GuestFailed, Transport, Busy}`

Host requests require `ToJson`; host responses require `FromJson`. The guest applies the inverse
bounds. These compile-time bounds and the runtime contract ID form the boundary contract.

The Wasm guest package uses `@abi.handle_sync` plus `abi_version`, `abi_capacity`, `contract_hash`,
`request_ptr`, and `response_ptr` to implement the six ABI v1 exports expected by the generic glue.

### Host

- `pool_options(worker_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `Pool::create(options)`
- `Pool::values() -> SharedSlice`
- `Pool::run(start?=0, end~, argument?=0) -> RunResult` — blocking Deno API
- `Pool::run_async(start?=0, end~, argument?=0) -> RunResult` — browser-safe API
- `Pool::worker_count()` / `Pool::capacity()`
- `Pool::close()`
- `PoolError::{InvalidArgument, WorkerFailed, Timeout, Closed, Busy}`

Only one batch may run on a pool at a time. Ranges are validated against the shared data region.

### Worker

- `@mayo.start(kernel)` — installs the Mayo Worker protocol
- `@mayo.SharedSlice` — shared data view without the private control region
- `SharedSlice::length()` / `load(index)` / `store(index, value)` / `fill(value)`
- `@mayo.run_worker(...)` — low-level entry point for composite Workers

## Current limitations

- The typed API copies JSON/UTF-8; it does not provide zero-copy sharing for MoonBit heap objects.
- Wasm guests add another copy between the shared mailbox and Wasm linear memory.
- Wasm guest ABI v1 supports the linear-memory `wasm` backend and a 1 MiB mailbox; `wasm-gc` is not
  supported yet.
- The low-level zero-copy data region is limited to an `Int32Array`.
- Kernels must be compiled ahead of time as Worker modules.
- A batch carries one additional `Int` argument.
- Scheduling uses static chunks; dynamic chunks and work stealing are not implemented.
- In-flight cancellation, Worker crash recovery, and kernel panic propagation are not implemented.
- MoonBit has no equivalent of Rust's `Send` / `Sync` checking for this boundary.
- Web pages must be cross-origin isolated; third-party subresources must also satisfy the selected
  embedder policy.
- Node.js is not supported yet.

Static chunks work well for uniform array processing. Uneven or recursively generated tasks will
need dynamic scheduling and eventually work stealing.

## Development

```console
just test          # MoonBit, Deno, browser, Rust, and C contract tests
just check         # formatting, linting, type checks, native checks, and tests
just test-web      # Playwright Chromium / Firefox / WebKit integration
just serve-web     # COOP/COEP web example server
just example       # Deno host example
just example-sync  # separately compiled typed Deno host/guest
just example-wasm  # MoonBit/JS host and MoonBit/Wasm guest
just compare 4     # pthread / mmap process / Rust / Rayon comparison
just bench         # Worker startup and contended-mutex experiments
```

Repository layout:

```text
host_client.mbt, host_runtime_js.mbt  MoonBit host API and JavaScript boundary
atomics_js.mbt, mayo.mbt              shared memory and Worker loop
protocol.mbt, start.mbt               control protocol and Worker entry point
sync_contract.mbt                     typed contract, mailbox, host, and guest API
wasm/abi/, wasm/guest_runtime.js       MoonBit/Wasm ABI and generic JS glue
examples/sync_contract/               request/response contract package
examples/sync_host/, sync_guest/      separately compiled typed executables
examples/wasm_contract/               shared JS/Wasm request and response types
examples/wasm_host/, wasm_guest/      separately compiled JS host and Wasm guest
examples/web/                         MoonBit browser client
examples/host/                        MoonBit Deno client
examples/mix_worker/                  MoonBit kernel
tests/web/                            COOP/COEP server and Playwright test
tests/client/                         MoonBit-to-MoonBit Deno integration test
worker/, bench/                       internal measurements
native/                               C pthread/mmap and Rust std/Rayon baselines
```

## Benchmark

`just compare 4` creates each pool and shared region once. Timed batches only publish a range and
round count; Worker/process startup and data copying are excluded. Mayo's benchmark host is also
MoonBit, compiled from `bench/mayo/main.mbt` and executed by Deno.

Median of five independent runs on 2026-07-15: Mac17,2, 32 GiB, 10 logical CPUs, darwin-aarch64,
Deno 2.6.4, MoonBit 0.1.20260713.

| backend         | dispatch p50 | dispatch p95 | memory bandwidth | compute throughput |
| --------------- | -----------: | -----------: | ---------------: | -----------------: |
| C pthread       |      10.0 µs |      20.0 µs |      102.8 GiB/s |        8.28 Gops/s |
| C mmap process  |      11.0 µs |      22.0 µs |      103.1 GiB/s |        8.32 Gops/s |
| Rust std pool   |      9.58 µs |      20.3 µs |       81.9 GiB/s |        9.73 Gops/s |
| Rust Rayon      |      17.5 µs |      80.4 µs |       82.1 GiB/s |        7.64 Gops/s |
| MoonBit message |      37.8 µs |      59.0 µs |       18.5 GiB/s |        8.54 Gops/s |
| Mayo            |      9.87 µs |      22.3 µs |       26.1 GiB/s |        8.69 Gops/s |

In this run, Mayo's dispatch p50 was 0.99× pthread and compute throughput was 1.05× pthread. The
single-operation memory case reached 25.4% of pthread bandwidth, where generated JavaScript and V8's
typed-array loop trail native vectorized loops. Treat local `just compare` results as authoritative;
core assignment, temperature, power state, and runtime versions materially affect these numbers.

## Roadmap

1. POD descriptors for multiple arguments and shared slices
2. Dynamic chunk counters with configurable grain size
3. A task ring and sleep/wake protocol in shared memory
4. Per-Worker Chase–Lev deques and work stealing
5. Error propagation, cancellation, and task recovery
6. Higher-level `par_for` and `par_chunks` APIs
7. A Node.js Worker adapter

Inspired by
[an experiment using shared memory and mutexes with Rust/Wasm](https://zenn.dev/grainrigi/articles/b7c2320ef13c71).

## License

MIT
