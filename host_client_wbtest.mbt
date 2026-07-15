///|
test "kernel contract keeps the versioned host guest protocol id" {
  let contract = kernel_contract("example/image-filter/v1")
  assert_eq(contract.id(), "example/image-filter/v1")
}

///|
test "kernel pool options carry an explicit contract" {
  let contract = kernel_contract("example/image-filter/v1")
  let options = kernel_pool_options(
    contract,
    "./worker.js",
    capacity=1024,
    worker_count=3,
  )
  assert_eq(options.protocol_id, "example/image-filter/v1")
  assert_eq(options.worker_count, 3)
  assert_eq(options.capacity, 1024)
  assert_false(options.use_wasm_memory)
}

///|
test "Wasm kernel options select shared WebAssembly memory" {
  let contract = kernel_contract("example/image-filter/v1")
  let options = wasm_kernel_pool_options(
    contract,
    "./mayo_wasm_kernel.js",
    "./kernel.wasm",
    capacity=2048,
    worker_count=2,
  )
  assert_eq(options.protocol_id, "example/image-filter/v1")
  assert_eq(options.worker_count, 2)
  assert_eq(options.capacity, 2048)
  assert_true(options.use_wasm_memory)
}

///|
test "Wasm capacity limit reserves runtime and control words" {
  assert_eq(wasm_capacity_limit(4), 7340032 - 64)
}

///|
test "kernel manifest protocol binds ordered ids and layout hashes" {
  let first = kernel_spec(id=1, layout_hash=101)
  let second = reducer_spec(id=2, layout_hash=202)
  let manifest = kernel_manifest("app/v1", [first, second])
  assert_eq(manifest.protocol_id_, "mayo.kernel/v4|6:app/v1|2|1:101:0|2:202:1")
  let call = reducer_call(manifest, second, argument=7)
  assert_eq(call.protocol_id_, manifest.protocol_id_)
  assert_eq(call.kernel_id_, 2)
  assert_eq(call.layout_hash_, 202)
  assert_eq(call.argument_, 7)
}

///|
test "auto grain uses initial parallelism and learned item cost" {
  assert_eq(choose_auto_grain(1024, 4, None), 32)
  assert_eq(choose_auto_grain(1024, 4, Some(0.001)), 100)
  assert_eq(choose_auto_grain(3, 8, None), 1)
  assert_eq(choose_auto_grain(0, 4, None), 1)
}

///|
test "arena reservation advances without overlap" {
  assert_eq(reserve_region(0, 4, 10), Some((0, 4)))
  assert_eq(reserve_region(4, 6, 10), Some((4, 10)))
  assert_eq(reserve_region(8, 3, 10), None)
}

///|
test "weighted partition preserves exact boundaries" {
  let weights = [1.0, 3.0]
  let first = partition_weighted(0, 100, 0, weights)
  let second = partition_weighted(0, 100, 1, weights)
  assert_eq((first.start, first.end), (0, 25))
  assert_eq((second.start, second.end), (25, 100))
  let equal = [1.0, 1.0, 1.0]
  let equal_first = partition_weighted(2, 15, 0, equal)
  let equal_last = partition_weighted(2, 15, 2, equal)
  assert_eq((equal_first.start, equal_first.end), (2, 6))
  assert_eq((equal_last.start, equal_last.end), (10, 15))
}
