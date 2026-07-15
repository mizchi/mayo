# Break-even benchmark

`just break-even 4`は、同じin-place LCG変換を常駐poolで測定します。Worker起動は除外します。
dispatch時にapplication bufferはcopyしません。pthreadとRustはprocess memory、process backendは
`mmap(MAP_SHARED)`、MayoはJavaScriptまたはWasmのshared memoryを使います。

2026-07-16、Apple M5、Deno 2.6.4、MoonBit 0.1.20260713、Rust 1.96.0、Clang 21.1.7での測定例です。

|  Elements | Rounds | C pthread | mmap process | Rust Rayon |  Mayo JS | Mayo Wasm |
| --------: | -----: | --------: | -----------: | ---------: | -------: | --------: |
|         0 |      0 |   18.5 µs |      19.0 µs |    15.5 µs |  21.8 µs |   16.8 µs |
|     4,096 |     64 |  108.5 µs |     122.5 µs |   100.3 µs |  89.8 µs |   76.4 µs |
|    65,536 |      1 |   35.0 µs |      34.0 µs |    30.3 µs |  70.7 µs |   49.1 µs |
|    65,536 |     16 |  257.5 µs |     273.0 µs |   225.3 µs | 128.8 µs |  137.5 µs |
| 1,048,576 |      1 |  269.0 µs |     246.5 µs |   204.5 µs | 674.8 µs |  368.4 µs |
| 1,048,576 |     64 |  20.32 ms |     28.38 ms |   25.11 ms | 11.62 ms |   7.63 ms |

この測定では、Mayo JSがsingle-agent Deno baselineを初めて上回ったのは262,144 LCG operationで、
speedupは1.35倍でした。1,048,576要素を1 roundだけ処理するmemory寄りの条件ではnative poolが高速です。
一方、常駐させたmmap process poolはpthreadに近く、process起動コストは償却できても同期とcacheの影響は
残る、という結果です。

言語をまたぐ絶対順位はJIT warmup、compiler最適化、CPU、grain、kernel形状に依存します。重要なのは
scaleです。常駐Mayoのdispatchは数十µsなので、小さいkernelではserialに負け、中程度以上または
compute-heavyなkernelで償却できます。対象machineの完全なmatrixは `just break-even-json 4`
で取得できます。

## CI regression gate

`just performance-regression 4`はquick比較を実行し、`dist/performance-report.json`を生成します。
十分に緩いdispatch絶対上限と、同じ実行内のC pthread memory throughputおよびRust Rayon compute
throughputに対するMayoの比率を検査します。shared CI hardwareを固定benchmark machineとして扱わず、
桁単位の性能退行を検知するためのgateです。policyは
[`performance_budget.json`](../bench/performance_budget.json)でversion管理します。
