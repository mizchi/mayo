# Break-even benchmark

`just break-even 4` measures warm persistent pools over the same in-place LCG transform. Startup is
excluded. No backend copies the application buffer for a dispatch: pthreads and Rust share their
process memory, the process backend uses `mmap(MAP_SHARED)`, and Mayo uses shared JavaScript or Wasm
memory.

Sample result from 2026-07-16 on an Apple M5, Deno 2.6.4, MoonBit 0.1.20260713, Rust 1.96.0, and
Clang 21.1.7:

|  Elements | Rounds | C pthread | mmap process | Rust Rayon |  Mayo JS | Mayo Wasm |
| --------: | -----: | --------: | -----------: | ---------: | -------: | --------: |
|         0 |      0 |   18.5 µs |      19.0 µs |    15.5 µs |  21.8 µs |   16.8 µs |
|     4,096 |     64 |  108.5 µs |     122.5 µs |   100.3 µs |  89.8 µs |   76.4 µs |
|    65,536 |      1 |   35.0 µs |      34.0 µs |    30.3 µs |  70.7 µs |   49.1 µs |
|    65,536 |     16 |  257.5 µs |     273.0 µs |   225.3 µs | 128.8 µs |  137.5 µs |
| 1,048,576 |      1 |  269.0 µs |     246.5 µs |   204.5 µs | 674.8 µs |  368.4 µs |
| 1,048,576 |     64 |  20.32 ms |     28.38 ms |   25.11 ms | 11.62 ms |   7.63 ms |

In this run, Mayo JS first beat the single-agent Deno baseline at 262,144 LCG operations, by 1.35x.
For a one-round memory-oriented pass over one million values, native pools remained faster. The
process pool was close to pthreads once both were persistent, which supports treating process
startup as amortized while retaining synchronization and cache effects.

Absolute cross-language rankings depend on JIT warmup, compiler optimization, CPU, grain, and kernel
shape. The useful result is the scale: warm Mayo dispatch is tens of microseconds, so small kernels
lose to serial work while medium or compute-heavy kernels can amortize it. Use
`just break-even-json 4` to capture the complete matrix on the target machine.

## CI regression gate

`just performance-regression 4` runs the quick comparison and writes `dist/performance-report.json`.
The gate checks both generous absolute dispatch limits and Mayo's in-run ratios against C pthread
memory throughput and Rust Rayon compute throughput. This is meant to catch order-of-magnitude
regressions without treating shared CI hardware as a stable benchmark machine. The policy is
versioned in [`performance_budget.json`](../bench/performance_budget.json).
