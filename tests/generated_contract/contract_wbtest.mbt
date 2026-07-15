///|
test "generated POD layout assigns header and slice offsets" {
  let layout = image_layout(
    width=5,
    height=3,
    source_length=15,
    scratch_length=15,
  )
  assert_eq(layout.width(), 5)
  assert_eq(layout.height(), 3)
  assert_eq(layout.source_offset(), 6)
  assert_eq(layout.source_length(), 15)
  assert_eq(layout.scratch_offset(), 21)
  assert_eq(layout.scratch_length(), 15)
  assert_eq(layout.capacity(), 36)
  assert_eq(layout.source_index(14), 20)
  assert_eq(layout.scratch_index(14), 35)
}
