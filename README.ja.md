# mayo

[English](./README.md)

Mayo は MoonBit の JavaScript backend 向けに作られた、実験的な data-parallel Worker pool です。 host
client と Worker kernel の両方を MoonBit で記述し、事前に JavaScript へコンパイルして、
モダンブラウザまたは Deno で実行します。

データと task descriptor は `SharedArrayBuffer` で共有します。常駐 Worker を JavaScript Atomics で
sleep/wake することで、Worker の起動コストを複数 batch に償却します。Rust Rayon のような MoonBit API
を目標にしていますが、現在の scheduler は work stealing ではなく、重複しない static chunk です。

> [!WARNING]
> 実験的な API です。MoonBit の heap object、closure、通常 object は Worker 間で共有しません。
> 現在共有できるものは、`Int32Array` を背後に持つ `SharedSlice` と dispatch ごとの 1 個の `Int`
> です。

## 対応 runtime

| host runtime | pool 作成      | dispatch API                             | 必要条件                              |
| ------------ | -------------- | ---------------------------------------- | ------------------------------------- |
| Web document | `Pool::create` | `Pool::run_async`                        | cross-origin isolation（COOP + COEP） |
| Deno         | `Pool::create` | `Pool::run` 推奨。`run_async` も利用可能 | local Worker には `--allow-read`      |
| Node.js      | 未対応         | —                                        | Worker adapter を予定                 |

[`Atomics.wait`](https://tc39.es/ecma262/multipage/structured-data.html#sec-atomics.wait) は
blocking API であり、browser document の main thread では使えません。そのため Mayo は Web dispatch
に
[`Atomics.waitAsync`](https://tc39.es/ecma262/multipage/structured-data.html#sec-atomics.waitasync)
を使い、 runtime に存在しない場合は timer-based polling へ fallback します。Web document から同期
`Pool::run` を呼ぶと `PoolError::InvalidArgument` になり、 `run_async` を使うよう案内します。

## 構成

```text
MoonBit host client                         MoonBit Worker kernel
  Pool::create / run_async                    @mayo.start(kernel)
           │                                           │
           └──── MoonBit JS backendでコンパイル ───────┘
                              │
                    Browser または Deno
                              │
                 SharedArrayBuffer (zero-copy)
                   ├─ Worker 0 control slot
                   ├─ Worker 1 control slot
                   └─ Int32 data region
```

各 Worker は自分の control slot にある epoch が変わるまで sleep します。dispatch は `[start, end)`
を 重複しない範囲に分け、すべての Worker が期待する done epoch を公開した時点で完了します。

`Worker`、`SharedArrayBuffer`、Atomics、Promise、`performance.now()` に触る runtime 境界だけが
JavaScript FFI です。option validation、range 分割、lifecycle state、dispatch は MoonBit 実装です。

## 使い方

### 1. MoonBit Worker kernel

[`examples/mix_worker/main.mbt`](./examples/mix_worker/main.mbt) は、割り当てられた各要素へ LCG
演算を 適用します。

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

`start` と `end` は shared slice の論理 index です。Worker の範囲は重複しないため、
`SharedSlice::load` / `store` は意図的に非 atomic access です。

### 2. Web から使う

[`examples/web/main.mbt`](./examples/web/main.mbt) は MoonBit で書かれた browser client です。

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

document、Worker、subresource を
[cross-origin isolated](https://html.spec.whatwg.org/multipage/webappapis.html#cross-origin-isolated-capability)
な response として配信してください。同一 origin だけで構成する最小例では次の header を使います。

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: same-origin
```

この repository には動作する server と browser test が含まれます。

```console
pnpm install
pnpm exec playwright install chromium firefox webkit
just serve-web   # http://127.0.0.1:4173 を開く
just test-web    # Chromium・Firefox・WebKit統合テスト
```

Playwright test は Chromium・Firefox・WebKit で `crossOriginIsolated` を確認し、事前ビルドした
MoonBit Worker を 3 個起動して、`run_async` で 2 batch を実行し、epoch と shared buffer の全要素を
検証します。

### 3. Deno から使う

[`examples/host/main.mbt`](./examples/host/main.mbt) も同じ MoonBit API を使います。Deno main agent
は `Atomics.wait` で block できるため、最小 dispatch overhead には同期 `run` を使います。

```moonbit
let result = pool.run(end=values.length(), argument=64)
```

```console
just example
```

Worker URL は生成された host module の `import.meta.url` からの相対 URL です。local Worker file を
読むには Deno の `--allow-read` permission が必要です。

### host package 設定

Browser と Deno の host は `Pool::create` と `run_async` のために async runtime を import します。

```moonbit
import {
  "mizchi/mayo" @mayo,
  "moonbitlang/async",
}

supported_targets = "js"

pkgtype(kind: "executable")
```

## 公開 API

### Host

- `pool_options(worker_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `Pool::create(options)`
- `Pool::values() -> SharedSlice`
- `Pool::run(start?=0, end~, argument?=0) -> RunResult` — blocking Deno API
- `Pool::run_async(start?=0, end~, argument?=0) -> RunResult` — browser-safe API
- `Pool::worker_count()` / `Pool::capacity()`
- `Pool::close()`
- `PoolError::{InvalidArgument, WorkerFailed, Timeout, Closed, Busy}`

同じ pool で同時に実行できる batch は 1 個です。range は shared data region の範囲内か検証されます。

### Worker

- `@mayo.start(kernel)` — Mayo Worker protocol を install
- `@mayo.SharedSlice` — private control region を除いた shared data view
- `SharedSlice::length()` / `load(index)` / `store(index, value)` / `fill(value)`
- `@mayo.run_worker(...)` — 複合 Worker 用の低レベル entry point

## 現在の制約

- shared data は `Int32Array` のみ
- kernel は Worker module として事前コンパイルする必要がある
- 1 batch で渡せる追加引数は 1 個の `Int`
- scheduling は static chunk。dynamic chunk と work stealing は未実装
- 実行中の cancel、Worker crash recovery、kernel panic の伝播は未実装
- MoonBit に Rust の `Send` / `Sync` 相当の型検査はない
- Web page は cross-origin isolated である必要があり、third-party subresource も選択した embedder
  policy を満たす必要がある
- Node.js は未対応

均一な配列処理には static chunk で十分ですが、処理時間が不均一な task や再帰的に増える task には
dynamic scheduling と work stealing が必要です。

## 開発

```console
just test          # MoonBit・Deno・browser・Rust・C の契約テスト
just check         # format・lint・型検査・native check・test
just test-web      # Playwright Chromium・Firefox・WebKit統合テスト
just serve-web     # COOP/COEP 付き Web example server
just example       # Deno host example
just compare 4     # pthread / mmap process / Rust / Rayon 比較
just bench         # Worker 起動と Mutex 競合の実験
```

主な構成:

```text
host_client.mbt, host_runtime_js.mbt  MoonBit host APIとJavaScript境界
atomics_js.mbt, mayo.mbt              shared memoryとWorker loop
protocol.mbt, start.mbt               control protocolとWorker entry point
examples/web/                         MoonBit browser client
examples/host/                        MoonBit Deno client
examples/mix_worker/                  MoonBit kernel
tests/web/                            COOP/COEP serverとPlaywright test
tests/client/                         MoonBit同士のDeno統合テスト
worker/, bench/                       内部測定用
native/                               C pthread/mmap・Rust std/Rayon比較版
```

## ベンチマーク

`just compare 4` は pool と shared region を 1 度だけ作り、計測対象の batch では range
と演算回数だけを 通知します。Worker/process 起動と data copy は含みません。Mayo backend の host も
MoonBit であり、 `bench/mayo/main.mbt` をコンパイルして Deno で実行します。

2026-07-15、Mac17,2 / 32 GiB / 10 logical CPUs / darwin-aarch64、Deno 2.6.4、MoonBit 0.1.20260713 で
5 回独立実行した中央値です。

| backend         | dispatch p50 | dispatch p95 | memory bandwidth | compute throughput |
| --------------- | -----------: | -----------: | ---------------: | -----------------: |
| C pthread       |      10.0 µs |      20.0 µs |      102.8 GiB/s |        8.28 Gops/s |
| C mmap process  |      11.0 µs |      22.0 µs |      103.1 GiB/s |        8.32 Gops/s |
| Rust std pool   |      9.58 µs |      20.3 µs |       81.9 GiB/s |        9.73 Gops/s |
| Rust Rayon      |      17.5 µs |      80.4 µs |       82.1 GiB/s |        7.64 Gops/s |
| MoonBit message |      37.8 µs |      59.0 µs |       18.5 GiB/s |        8.54 Gops/s |
| Mayo            |      9.87 µs |      22.3 µs |       26.1 GiB/s |        8.69 Gops/s |

この実行では Mayo の dispatch p50 は pthread の 0.99 倍、compute throughput は 1.05 倍でした。 1
演算/要素の memory case は pthread bandwidth の 25.4% で、生成 JavaScript と V8 typed-array loop が
native の vectorized loop に及ばない差が現れます。core 割当、温度、電源状態、runtime version で
結果は変わるため、手元の `just compare` を基準にしてください。

## Roadmap

1. 複数引数と複数 shared slice の POD descriptor
2. grain size を指定できる dynamic chunk counter
3. shared memory 上の task ring と sleep/wake protocol
4. Worker ごとの Chase–Lev deque と work stealing
5. error propagation、cancel、task recovery
6. `par_for` / `par_chunks` 高レベル API
7. Node.js Worker adapter

着想元:
[Rust/Wasm で shared memory と Mutex を使う実験](https://zenn.dev/grainrigi/articles/b7c2320ef13c71)

## License

MIT
