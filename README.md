# mayo

[日本語](./README.ja.md)

Mayo is an experimental zero-copy data-parallel Worker pool for MoonBit, inspired by Rayon.

- MoonBit Host and prebuilt MoonBit/JS or MoonBit/Wasm kernels
- persistent Workers coordinated through `SharedArrayBuffer` and Atomics
- Deno, browsers, Node.js, and Bun
- static and dynamic scheduling, reduction, structured concurrency, and recovery

Mayo shares explicit `Int32` memory, not MoonBit heap objects. A dispatch transfers only a kernel
descriptor, a half-open range, and one `Int` argument. JSON is not part of the primary API.

## Minimal Host

Host and Worker builds import the same descriptor package. Descriptors may be written in MoonBit or
generated from [`mayo.kernel.json`](./examples/mix_kernel/mayo.kernel.json).

```moonbit
async fn main {
  let threads = @mayo.ThreadPool::open(
    @kernels.manifest(),
    "./worker.js",
    capacity=1_000_000,
    workers=4,
  )
  defer threads.close()

  let values = threads.shared_i32()
  values.fill(2)
  let mapped = values.par_chunks(@kernels.scale(factor=3)) // auto grain
  let sum = values.par_reduce(
    @kernels.sum(),
    init=0,
    combine=fn(left, right) { left + right },
  )
  println("dispatch \{mapped.elapsed_ms} ms; sum \{sum.value}")
}
```

The separately compiled Worker binds implementations to the same manifest:

```moonbit
fn main {
  @mayo.serve_kernels(@kernels.manifest(), [
    @kernels.scale_entry(scale_range),
    @kernels.sum_entry(sum_range),
  ])
}
```

`just build-kernel` demonstrates descriptor generation and ahead-of-time artifact placement through
[`mayo.build.json`](./mayo.build.json). Startup rejects mismatched manifest IDs, kernel IDs, layout
hashes, or kernel kinds.

## Data-parallel API

- `par_for`: weighted static ranges
- `par_chunks`: dynamic work sharing; omit `grain` to learn it automatically
- `par_reduce`: Worker-local partials, combined deterministically by Worker ID
- `SharedArena`: non-overlapping POD layouts and per-Worker scratch regions; Guest kernels obtain
  their stable index with `SharedSlice::worker_id`
- `SharedRegion`: `par_map_in_place`, `par_for_each`, `par_zip`, and `par_pipeline`
- `ThreadPool::scope`: FIFO tasks backed by `moonbitlang/async`
- `RecoveryPolicy::RestartWorkers`: replace failed Workers while retaining shared data

Generated layouts encode structures as checked offsets and lengths inside the shared arena. Strings,
closures, ordinary arrays, and arbitrary object graphs are intentionally outside the contract.

## Runtimes

| Runtime     | Status    | Local requirement                         |
| ----------- | --------- | ----------------------------------------- |
| Deno        | Supported | `--allow-read` for Worker/Wasm files      |
| Web         | Supported | COOP/COEP cross-origin isolation          |
| Node.js 24+ | Supported | built-in `worker_threads` adapter         |
| Bun         | Supported | Web Worker adapter, including shared Wasm |

The runtime glue is JavaScript; the Host client, descriptors, and kernels are MoonBit. Browser tests
cover Chromium, Firefox, and WebKit. Node and Bun integration tests cover both JS and shared Wasm
guests.

## Examples and benchmarks

```console
just example-image          # shared 640x360 grayscale + Sobel pipeline
just example-scope          # structured concurrency
just example-wasm           # MoonBit/JS Host + shared MoonBit/Wasm kernel
just serve-web              # cross-origin-isolated browser example
just compare 4              # pthread, mmap process, Rust, Rayon, Mayo
just break-even 4           # workload break-even matrix
just performance-regression # portable CI performance budget
just release-check
```

Warm dispatch is typically tens of microseconds on the measured development machine. Persistent
`mmap` processes approach pthread latency once startup is amortized; Mayo becomes useful when each
dispatch contains enough memory or compute work. See the [benchmark notes](./docs/benchmarks.md).

## Contract

- [Kernel ABI v4](./docs/kernel-abi-v4.md)
- [Real-world image pipeline](./examples/image_pipeline/pipeline.mbt)
- [Benchmark sources](./bench)

The optional [`json`](./json) compatibility package is separate from the zero-copy API.

Inspired by
[an experiment using shared memory and mutexes with Rust/Wasm](https://zenn.dev/grainrigi/articles/b7c2320ef13c71).

## License

MIT
