# mayo

[English](./README.md)

MayoはRayonに着想を得た、MoonBit向けの実験的なzero-copyデータ並列Worker poolです。

- MoonBit Hostと事前ビルドしたMoonBit/JSまたはMoonBit/Wasm kernel
- `SharedArrayBuffer`とAtomicsで同期する常駐Worker
- Deno、Web、Node.js、Bun
- static/dynamic scheduling、reduce、structured concurrency、recovery

共有するのはMoonBit heap objectではなく、明示的な`Int32` memoryです。dispatchで渡すのはkernel
descriptor、半開range、1つの`Int` argumentだけです。JSONはprimary APIに含めません。

## 最小のHost

HostとWorkerは同じdescriptor packageをimportします。descriptorはMoonBitで手書きするか、
[`mayo.kernel.json`](./examples/mix_kernel/mayo.kernel.json)から生成できます。

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
  let mapped = values.par_chunks(@kernels.scale(factor=3)) // grain自動調整
  let sum = values.par_reduce(
    @kernels.sum(),
    init=0,
    combine=fn(left, right) { left + right },
  )
  println("dispatch \{mapped.elapsed_ms} ms; sum \{sum.value}")
}
```

別途コンパイルするWorkerは、同じmanifestへ実装をbindします。

```moonbit
fn main {
  @mayo.serve_kernels(@kernels.manifest(), [
    @kernels.scale_entry(scale_range),
    @kernels.sum_entry(sum_range),
  ])
}
```

`just build-kernel`では[`mayo.build.json`](./mayo.build.json)に従い、descriptor生成から事前ビルド
artifact配置までを実行します。manifest ID、kernel ID、layout hash、kernel
kindが一致しなければ起動時に 拒否します。

## データ並列API

- `par_for`: throughputで重み付けしたstatic range
- `par_chunks`: dynamic work sharing。`grain`省略時は実測から自動調整
- `par_reduce`: Worker-local partialをWorker ID順に決定的にcombine
- `SharedArena`: 重複しないPOD layoutとWorker別scratch region。Guest kernelは
  `SharedSlice::worker_id`で自分のstable indexを取得
- `SharedRegion`: `par_map_in_place`、`par_for_each`、`par_zip`、`par_pipeline`
- `ThreadPool::scope`: `moonbitlang/async`を再利用したFIFO task
- `RecoveryPolicy::RestartWorkers`: shared dataを保ったまま失敗Workerを再生成

生成layoutは構造体をshared arena内の検査付きoffset/lengthとして表します。String、closure、通常の
Array、任意のobject graphは意図的にcontract外です。

## 対応runtime

| Runtime     | 状態 | local実行の要件                       |
| ----------- | ---- | ------------------------------------- |
| Deno        | 対応 | Worker/Wasm fileへの`--allow-read`    |
| Web         | 対応 | COOP/COEPによるcross-origin isolation |
| Node.js 24+ | 対応 | 組み込み`worker_threads` adapter      |
| Bun         | 対応 | shared Wasmを含むWeb Worker adapter   |

runtime glueはJavaScriptですが、Host client、descriptor、kernelはMoonBitです。browser testは
Chromium、Firefox、WebKitを、Node/Bun integration testはJS guestとshared Wasm
guestの両方を検証します。

## Exampleとbenchmark

```console
just example-image          # shared 640x360 grayscale + Sobel pipeline
just example-scope          # structured concurrency
just example-wasm           # MoonBit/JS Host + shared MoonBit/Wasm kernel
just serve-web              # cross-origin isolatedなbrowser example
just compare 4              # pthread、mmap process、Rust、Rayon、Mayo
just break-even 4           # workload別break-even matrix
just performance-regression # portableなCI性能budget
just release-check
```

開発machineでの常駐pool dispatchは通常数十µsです。常駐`mmap`
processは起動コストを償却するとpthreadに 近づきます。Mayoは1
dispatchあたりのmemory処理または計算量が十分な場合に有効です。詳細は
[benchmark notes](./docs/benchmarks.ja.md)を参照してください。

## Contract

- [Kernel ABI v4 日本語版](./docs/kernel-abi-v4.ja.md)
- [real-world image pipeline](./examples/image_pipeline/pipeline.mbt)
- [benchmark source](./bench)

optionalな[`json`](./json) compatibility packageはzero-copy APIとは分離しています。

着想元:
[Rust/Wasmでshared memoryとMutexを使う実験](https://zenn.dev/grainrigi/articles/b7c2320ef13c71)

## License

MIT
