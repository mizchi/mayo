///|
fn grayscale_range(
  shared : @mayo.SharedSlice,
  start : Int,
  end : Int,
  _argument : Int,
) -> Unit {
  let layout = @image.load_guest_layout(shared)
  for index = start; index < end; index = index + 1 {
    let source = shared.load(layout.source_index(index))
    shared.store(layout.scratch_index(index), @image.grayscale_pixel(source))
  }
}

///|
fn scratch_at(
  shared : @mayo.SharedSlice,
  layout : @image.ImageLayout,
  x : Int,
  y : Int,
) -> Int {
  shared.load(layout.scratch_index(y * layout.width() + x))
}

///|
fn sobel_range(
  shared : @mayo.SharedSlice,
  start : Int,
  end : Int,
  threshold : Int,
) -> Unit {
  let layout = @image.load_guest_layout(shared)
  for index = start; index < end; index = index + 1 {
    let x = index % layout.width()
    let y = index / layout.width()
    let output = if x == 0 ||
      y == 0 ||
      x == layout.width() - 1 ||
      y == layout.height() - 1 {
      0
    } else {
      @image.sobel_pixel(
        scratch_at(shared, layout, x - 1, y - 1),
        scratch_at(shared, layout, x, y - 1),
        scratch_at(shared, layout, x + 1, y - 1),
        scratch_at(shared, layout, x - 1, y),
        scratch_at(shared, layout, x + 1, y),
        scratch_at(shared, layout, x - 1, y + 1),
        scratch_at(shared, layout, x, y + 1),
        scratch_at(shared, layout, x + 1, y + 1),
        threshold~,
      )
    }
    shared.store(layout.source_index(index), output)
  }
}

///|
fn main {
  @mayo.serve_kernels(@image.manifest(), [
    @image.grayscale_entry(grayscale_range),
    @image.sobel_entry(sobel_range),
  ])
}
