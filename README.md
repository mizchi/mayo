# mayo

MoonBit の JS backend で、事前ビルドした MoonBit kernel を常駐 Deno Worker として実行する、 実験的な
data-parallel worker pool です。host client と Worker の両方を MoonBit で記述し、 生成された
JavaScript を Deno で実行します。

データと task descriptor は `SharedArrayBuffer` で共有し、`Atomics.wait` / `notify` で同期します。
Rust Rayon のように、pool の生成コストを再利用しながら配列処理を並列 dispatch できる API を
目指しています。現在の scheduler は work stealing ではなく static chunk です。

> [!WARNING]
> 実験的な API です。MoonBit の通常 heap、closure、object は Worker 間で共有しません。
> 共有できるデータは `Pool::values()` が返す `SharedSlice` と、kernel へ渡す 1 個の `Int` です。

## 構成

```text
MoonBit host client                         MoonBit worker kernel
  Pool::create / run / close                  @mayo.start(kernel)
           │                                           │
           └──── MoonBit JS backendでコンパイル ───────┘
                              │
                         Deno runtime
                              │
                 SharedArrayBuffer (zero-copy)
                   ├─ worker 0 control slot
                   ├─ worker 1 control slot
                   └─ Int32 data region
```

各 Worker は常駐し、自分の control slot にある epoch が変わるまで sleep します。`Pool::run` は
`[start, end)` を重複しない chunk に分け、全 Worker の完了 epoch が揃うまで呼び出し元を
ブロックします。

Worker、`SharedArrayBuffer`、`Atomics`、`performance.now()` に触る最小限の runtime 境界だけが
JavaScript FFI です。pool の検証、range 分割、lifecycle、dispatch は MoonBit で実装しています。

## 使い方

### 1. MoonBit kernel

[`examples/mix_worker/main.mbt`](./examples/mix_worker/main.mbt) は、共有配列の各要素へ LCG 演算を
指定回数適用するサンプルです。

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

kernel の `start` と `end` は共有 slice の論理 index です。Worker ごとの範囲は重複しないため、
`SharedSlice::load` / `store` は意図的に非 atomic access にしています。

### 2. MoonBit host client

[`examples/host/main.mbt`](./examples/host/main.mbt) も MoonBit です。

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
  let result = pool.run(end=values.length(), argument=64)
  println("dispatch: \{result.elapsed_ms} ms")
}
```

host package は async runtime を import します。

```moonbit
import {
  "mizchi/mayo" @mayo,
  "moonbitlang/async",
}

supported_targets = "js"

pkgtype(kind: "executable")
```

このリポジトリでは次のコマンドで host と Worker をコンパイルし、同じ `dist/` に配置します。 Worker
URL は生成された host module の `import.meta.url` を基準に解決されます。

```console
just example
```

`Pool::create` だけが async です。`Pool::run` は Rayon に近い同期 API で、Deno main thread 上の
`Atomics.wait` を使います。実行時にはローカル Worker を読む `--allow-read` が必要です。

## 公開 API

### MoonBit host

- `pool_options(worker_url, capacity~, worker_count?=4, timeout_ms?=30000)`
- `Pool::create(options)`
- `Pool::values() -> SharedSlice`
- `Pool::run(start?=0, end~, argument?=0) -> RunResult`
- `Pool::worker_count()` / `Pool::capacity()`
- `Pool::close()`
- `PoolError::{InvalidArgument, WorkerFailed, Timeout, Closed, Busy}`

同じ pool では batch を順番に実行します。`start` / `end` は共有領域内で検証されます。

### MoonBit worker

- `@mayo.start(kernel)` — Mayo Worker protocol を install
- `@mayo.SharedSlice` — control 領域を隠した共有データ view
- `SharedSlice::length()` / `load(index)` / `store(index, value)` / `fill(value)`
- `@mayo.run_worker(...)` — 複合 Worker を構築する場合の低レベル entry point

## 現在の制約

- データ型は `Int32Array` のみ
- kernel は事前に Worker 用 JS へコンパイルする必要がある
- 1 batch で渡せる追加情報は 1 個の `Int`
- scheduling は static chunk。dynamic chunk と work stealing は未実装
- `run` 中の cancel、Worker crash recovery、panic 伝播は未実装
- MoonBit に Rust の `Send` / `Sync` 相当の型検査はない
- Deno 専用。browser main thread と Node.js は未対応

均一な配列処理には static chunk で十分ですが、task ごとの処理時間が不均一な場合や再帰的に task
が増える場合は work stealing が必要です。

## 開発

```console
just test          # MoonBit client/Worker・Deno・Rust・C の契約テスト
just check         # format・lint・型検査・テスト
just example       # MoonBit host API のサンプル
just compare 4     # pthread / mmap process / Rust / Rayon と比較
just bench         # Worker 起動と Mutex 競合の実験
```

主なファイルとディレクトリ:

```text
src/host_client.mbt                  MoonBit host API
src/host_runtime_js.mbt              Deno JavaScript FFI境界
src/atomics_js.mbt, mayo.mbt         共有メモリとWorker loop
src/protocol.mbt, start.mbt          control protocolとWorker entry
examples/host/                        MoonBit hostサンプル
examples/mix_worker/                  MoonBit kernelサンプル
tests/client/                         MoonBit同士の統合テスト
worker/, bench/                       比較測定用（公開APIではない）
native/                               C pthread/mmap・Rust std/Rayon比較版
```

## ベンチマーク

`just compare 4` は pool と共有領域を一度だけ作り、各 batch では範囲と演算回数だけを通知します。
データ本体の copy と pool 生成時間は含みません。Mayo backend の host client も MoonBit であり、
`bench/mayo/main.mbt` から生成した JS を Deno subprocess として実行します。

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

この実行では Mayo の dispatch p50 は pthread の 0.99 倍、compute throughput は 1.05 倍で、ほぼ同じ
帯域でした。一方、1 演算/要素の軽い loop では memory bandwidth が pthread の 25.4% です。MoonBit
生成 JS と V8 の typed array loop が native compiler の vectorized loop に及ばない差が現れます。CPU
の P/E core 割当、温度、電源状態、runtime version で結果は変わるため、手元の `just compare` を基準に
してください。全 backend は同じ transform 契約と checksum を検証します。

Worker 起動は通常 6 ms 前後で、事前ビルドした kernel のコード量より Deno Worker / V8 isolate の
生成が支配的です。Mayo はこの起動コストを常駐 pool で償却します。

## Roadmap

1. 複数引数と複数 shared slice を表現する POD descriptor
2. grain size を調整できる dynamic chunk counter
3. SAB 上の task ring と sleep/wake
4. Worker ごとの Chase–Lev deque による work stealing
5. error、cancel、Worker 終了時の task 回収
6. `par_for` / `par_chunks` 相当の高レベル API

着想元:
[Rust/Wasm で shared memory と Mutex を使う実験](https://zenn.dev/grainrigi/articles/b7c2320ef13c71)

## License

MIT
