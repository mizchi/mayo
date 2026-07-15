///|
test "image layout reserves a header and two non-overlapping pixel planes" {
  let layout = image_layout(width=5, height=3)
  assert_eq(layout.width(), 5)
  assert_eq(layout.height(), 3)
  assert_eq(layout.pixel_count(), 15)
  assert_eq(layout.source_offset(), 8)
  assert_eq(layout.scratch_offset(), 23)
  assert_eq(layout.capacity(), 38)
  assert_eq(layout.source_index(14), 22)
  assert_eq(layout.scratch_index(14), 37)
}

///|
test "image layout rejects dimensions whose two planes exceed Int32" {
  assert_eq(checked_pixel_count(65536, 65537), None)
}

///|
test "packed RGB pixels round-trip and grayscale uses integer luma" {
  let pixel = pack_rgb(red=12, green=34, blue=56)
  assert_eq(red(pixel), 12)
  assert_eq(green(pixel), 34)
  assert_eq(blue(pixel), 56)
  assert_eq(grayscale_pixel(pack_rgb(red=255, green=255, blue=255)), 0xFFFFFF)
  assert_eq(
    grayscale_pixel(pack_rgb(red=255, green=0, blue=0)),
    pack_rgb(red=77, green=77, blue=77),
  )
}

///|
test "Sobel detects a vertical edge and suppresses a flat neighborhood" {
  let black = pack_rgb(red=0, green=0, blue=0)
  let white = pack_rgb(red=255, green=255, blue=255)
  let edge = sobel_pixel(
    black,
    black,
    white,
    black,
    white,
    black,
    black,
    white,
    threshold=64,
  )
  assert_eq(edge, white)
  assert_eq(
    sobel_pixel(
      white,
      white,
      white,
      white,
      white,
      white,
      white,
      white,
      threshold=64,
    ),
    black,
  )
}
