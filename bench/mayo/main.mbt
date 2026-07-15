///|
priv struct Config {
  workers : Int
  quick : Bool
  wasm : Bool
}

///|
priv struct ScenarioConfig {
  elements : Int
  compute_rounds : Int
  warmups : Int
  batches : Int
}

///|
priv struct Timing {
  median_ms : Double
  p95_ms : Double
}

///|
priv struct ScenarioReport {
  elements : Int
  compute_rounds : Int
  median_us : Double
  p95_us : Double
  gib_per_s : Double
  mops : Double
  checksum : Int
}

///|
extern "js" fn parse_config() -> Config =
  #| () => {
  #|   let workers = Math.min(4, navigator.hardwareConcurrency || 1);
  #|   let quick = false;
  #|   let wasm = false;
  #|   for (let index = 0; index < Deno.args.length; index += 1) {
  #|     switch (Deno.args[index]) {
  #|       case "--workers":
  #|         workers = Number(Deno.args[++index]);
  #|         break;
  #|       case "--quick":
  #|         quick = true;
  #|         break;
  #|       case "--wasm":
  #|         wasm = true;
  #|         break;
  #|       default:
  #|         throw new Error(`unknown argument: ${Deno.args[index]}`);
  #|     }
  #|   }
  #|   if (!Number.isSafeInteger(workers) || workers < 1) {
  #|     throw new Error("workers must be a positive integer");
  #|   }
  #|   return { workers: workers | 0, quick, wasm };
  #| }

///|
extern "js" fn initial_value(index : Int) -> Int = "(index) => (Math.imul(index, 2654435761) + 12345) | 0"

///|
extern "js" fn summarize_samples(samples : Array[Double]) -> Timing =
  #| (samples) => {
  #|   const sorted = [...samples].sort((left, right) => left - right);
  #|   const percentile = (fraction) => {
  #|     const position = (sorted.length - 1) * fraction;
  #|     const lower = Math.floor(position);
  #|     const upper = Math.ceil(position);
  #|     if (lower === upper) return sorted[lower];
  #|     return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
  #|   };
  #|   return { median_ms: percentile(0.5), p95_ms: percentile(0.95) };
  #| }

///|
extern "js" fn emit_report(
  backend : String,
  workers : Int,
  dispatch : ScenarioReport,
  memory : ScenarioReport,
  compute : ScenarioReport,
) -> Unit =
  #| (backend, workers, dispatch, memory, compute) => {
  #|   const scenario = (value) => ({
  #|     elements: value.elements,
  #|     compute_rounds: value.compute_rounds,
  #|     median_us: value.median_us,
  #|     p95_us: value.p95_us,
  #|     gib_per_s: value.gib_per_s,
  #|     mops: value.mops,
  #|     checksum: value.checksum >>> 0,
  #|   });
  #|   console.log(JSON.stringify({
  #|     backend,
  #|     workers,
  #|     dispatch: scenario(dispatch),
  #|     memory: scenario(memory),
  #|     compute: scenario(compute),
  #|   }));
  #| }

///|
fn initialize(values : @mayo_lib.SharedSlice, elements : Int) -> Unit {
  for index = 0; index < elements; index = index + 1 {
    values.store(index, initial_value(index))
  }
}

///|
fn checksum(values : @mayo_lib.SharedSlice, elements : Int) -> Int {
  let mut result = 0
  for index = 0; index < elements; index = index + 1 {
    result = result ^ values.load(index)
  }
  result
}

///|
fn measure(
  pool : @mayo_lib.Pool,
  values : @mayo_lib.SharedSlice,
  config : ScenarioConfig,
  wasm : Bool,
) -> ScenarioReport raise @mayo_lib.PoolError {
  initialize(values, config.elements)
  for warmup = 0; warmup < config.warmups; warmup = warmup + 1 {
    if wasm {
      ignore(pool.run(end=config.elements, argument=config.compute_rounds))
    } else {
      ignore(
        pool.run_kernel(
          @kernel.mix(rounds=config.compute_rounds),
          end=config.elements,
        ),
      )
    }
  }
  let samples : Array[Double] = []
  for batch = 0; batch < config.batches; batch = batch + 1 {
    let result = if wasm {
      pool.run(end=config.elements, argument=config.compute_rounds)
    } else {
      pool.run_kernel(
        @kernel.mix(rounds=config.compute_rounds),
        end=config.elements,
      )
    }
    samples.push(result.elapsed_ms)
  }
  let timing = summarize_samples(samples)
  let seconds = timing.median_ms / 1000.0
  let gib_per_s = if config.elements == 0 {
    0.0
  } else {
    config.elements.to_double() * 8.0 / seconds / 1073741824.0
  }
  let mops = if config.compute_rounds == 0 {
    0.0
  } else {
    config.elements.to_double() *
    config.compute_rounds.to_double() /
    seconds /
    1000000.0
  }
  {
    elements: config.elements,
    compute_rounds: config.compute_rounds,
    median_us: timing.median_ms * 1000.0,
    p95_us: timing.p95_ms * 1000.0,
    gib_per_s,
    mops,
    checksum: checksum(values, config.elements),
  }
}

///|
async fn run() -> Unit raise @mayo_lib.PoolError {
  let config = parse_config()
  let memory_elements = if config.quick { 262144 } else { 4194304 }
  let options = if config.wasm {
    @mayo_lib.wasm_kernel_pool_options(
      @mayo_lib.kernel_contract(@wasm_contract.contract_id()),
      "./mayo_wasm_kernel.js",
      "./wasm_guest.wasm",
      capacity=memory_elements,
      worker_count=config.workers,
    )
  } else {
    @mayo_lib.kernel_manifest_pool_options(
      @kernel.manifest(),
      "./mayo_worker.js",
      capacity=memory_elements,
      worker_count=config.workers,
    )
  }
  let pool = @mayo_lib.Pool::create(options)
  defer pool.close()
  let values = pool.values()
  let dispatch = measure(
    pool,
    values,
    {
      elements: 0,
      compute_rounds: 0,
      warmups: 20,
      batches: if config.quick {
        100
      } else {
        5000
      },
    },
    config.wasm,
  )
  let memory = measure(
    pool,
    values,
    {
      elements: memory_elements,
      compute_rounds: 1,
      warmups: 5,
      batches: if config.quick {
        3
      } else {
        25
      },
    },
    config.wasm,
  )
  let compute = measure(
    pool,
    values,
    {
      elements: if config.quick {
        16384
      } else {
        262144
      },
      compute_rounds: if config.quick {
        16
      } else {
        64
      },
      warmups: 3,
      batches: if config.quick {
        3
      } else {
        20
      },
    },
    config.wasm,
  )
  emit_report(
    if config.wasm {
      "mayo-wasm"
    } else {
      "mayo"
    },
    config.workers,
    dispatch,
    memory,
    compute,
  )
}

///|
extern "js" fn fail_benchmark(message : String) -> Unit = "(message) => { console.error(message); Deno.exit(1); }"

///|
fn pool_error_message(error : @mayo_lib.PoolError) -> String {
  match error {
    InvalidArgument(message) => "invalid argument: \{message}"
    WorkerFailed(message) => "worker failed: \{message}"
    Timeout(message) => "timeout: \{message}"
    Closed => "pool closed"
    Busy => "pool busy"
  }
}

///|
async fn main {
  run() catch {
    error => fail_benchmark(pool_error_message(error))
  }
}
