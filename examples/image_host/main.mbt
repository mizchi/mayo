///|
fn vertical_edge_source(width : Int, height : Int) -> Array[Int] {
  let black = @image.pack_rgb(red=0, green=0, blue=0)
  let white = @image.pack_rgb(red=255, green=255, blue=255)
  let split = width / 2
  Array::makei(width * height, index => {
    if index % width >= split {
      white
    } else {
      black
    }
  })
}

///|
fn verify_grayscale(
  layout : @image.ImageLayout,
  values : @mayo.SharedI32,
  source : Array[Int],
) -> Unit {
  for index = 0; index < layout.pixel_count(); index = index + 1 {
    if layout.scratch_pixel(values, index) !=
      @image.grayscale_pixel(source[index]) {
      abort("grayscale mismatch at pixel \{index}")
    }
  }
}

///|
fn verify_vertical_edges(
  layout : @image.ImageLayout,
  values : @mayo.SharedI32,
) -> Unit {
  let black = @image.pack_rgb(red=0, green=0, blue=0)
  let white = @image.pack_rgb(red=255, green=255, blue=255)
  let split = layout.width() / 2
  for index = 0; index < layout.pixel_count(); index = index + 1 {
    let x = index % layout.width()
    let y = index / layout.width()
    let expected = if y > 0 &&
      y < layout.height() - 1 &&
      (x == split - 1 || x == split) {
      white
    } else {
      black
    }
    if layout.source_pixel(values, index) != expected {
      abort("Sobel mismatch at (\{x}, \{y})")
    }
  }
}

///|
async fn main {
  // One 640x360 RGB frame occupies about 1.8 MiB across both Int32 planes.
  let layout = @image.image_layout(width=640, height=360)
  let threads = @mayo.ThreadPool::open(
    @image.manifest(),
    "./image_worker.js",
    capacity=layout.capacity(),
    workers=3,
  )
  defer threads.close()
  let values = threads.shared_i32()
  let source = vertical_edge_source(layout.width(), layout.height())
  layout.initialize(values, source)

  let grayscale = values.par_for(@image.grayscale(), end=layout.pixel_count())
  verify_grayscale(layout, values, source)

  let sobel = values.par_for(
    @image.detect_edges(threshold=64),
    end=layout.pixel_count(),
  )
  verify_vertical_edges(layout, values)

  println(
    "MoonBit Mayo image pipeline: \{layout.width()}x\{layout.height()} (\{layout.pixel_count()} pixels), grayscale \{grayscale.elapsed_ms} ms, Sobel \{sobel.elapsed_ms} ms",
  )
}
