///|
test "static partition covers an uneven range without gaps" {
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
