///|
test "static partition covers an uneven range without gaps or overlaps" {
  let first = partition_range(2, 15, 0, 3)
  let second = partition_range(2, 15, 1, 3)
  let third = partition_range(2, 15, 2, 3)
  assert_eq((first.start, first.end), (2, 7))
  assert_eq((second.start, second.end), (7, 11))
  assert_eq((third.start, third.end), (11, 15))
}

///|
test "static partition emits empty tails when workers exceed elements" {
  let first = partition_range(0, 2, 0, 4)
  let second = partition_range(0, 2, 1, 4)
  let third = partition_range(0, 2, 2, 4)
  let fourth = partition_range(0, 2, 3, 4)
  assert_eq((first.start, first.end), (0, 1))
  assert_eq((second.start, second.end), (1, 2))
  assert_eq((third.start, third.end), (2, 2))
  assert_eq((fourth.start, fourth.end), (2, 2))
}

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
