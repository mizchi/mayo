///|
const IMAGE_MAGIC : Int = 0x4D41594F

///|
const HEADER_WORDS : Int = 8

///|
/// The POD layout shared by the MoonBit Host and every image Worker.
pub struct ImageLayout {
  priv width_ : Int
  priv height_ : Int
  priv pixel_count_ : Int
  priv source_offset_ : Int
  priv scratch_offset_ : Int
  priv capacity_ : Int
}

///|
fn checked_pixel_count(width : Int, height : Int) -> Int? {
  if width <= 0 || height <= 0 {
    return None
  }
  let max_pixels = (0x7FFFFFFF - HEADER_WORDS) / 2
  if width > max_pixels / height {
    None
  } else {
    Some(width * height)
  }
}

///|
/// Creates a double-buffered packed-RGB image layout.
pub fn image_layout(width~ : Int, height~ : Int) -> ImageLayout {
  let pixel_count = match checked_pixel_count(width, height) {
    Some(count) => count
    None => abort("image dimensions exceed the Int32 double-buffer layout")
  }
  let source_offset = HEADER_WORDS
  let scratch_offset = source_offset + pixel_count
  let capacity = scratch_offset + pixel_count
  {
    width_: width,
    height_: height,
    pixel_count_: pixel_count,
    source_offset_: source_offset,
    scratch_offset_: scratch_offset,
    capacity_: capacity,
  }
}

///|
pub fn ImageLayout::width(self : ImageLayout) -> Int {
  self.width_
}

///|
pub fn ImageLayout::height(self : ImageLayout) -> Int {
  self.height_
}

///|
pub fn ImageLayout::pixel_count(self : ImageLayout) -> Int {
  self.pixel_count_
}

///|
pub fn ImageLayout::source_offset(self : ImageLayout) -> Int {
  self.source_offset_
}

///|
pub fn ImageLayout::scratch_offset(self : ImageLayout) -> Int {
  self.scratch_offset_
}

///|
pub fn ImageLayout::capacity(self : ImageLayout) -> Int {
  self.capacity_
}

///|
pub fn ImageLayout::source_index(self : ImageLayout, index : Int) -> Int {
  self.source_offset_ + index
}

///|
pub fn ImageLayout::scratch_index(self : ImageLayout, index : Int) -> Int {
  self.scratch_offset_ + index
}

///|
fn clamp_channel(value : Int) -> Int {
  if value < 0 {
    0
  } else if value > 255 {
    255
  } else {
    value
  }
}

///|
/// Packs one RGB pixel as `0x00BBGGRR`, which remains a positive MoonBit Int.
pub fn pack_rgb(red~ : Int, green~ : Int, blue~ : Int) -> Int {
  clamp_channel(red) + (clamp_channel(green) << 8) + (clamp_channel(blue) << 16)
}

///|
pub fn red(pixel : Int) -> Int {
  pixel.land(0xFF)
}

///|
pub fn green(pixel : Int) -> Int {
  (pixel >> 8).land(0xFF)
}

///|
pub fn blue(pixel : Int) -> Int {
  (pixel >> 16).land(0xFF)
}

///|
/// Converts a packed RGB pixel using integer Rec.601 luma coefficients.
pub fn grayscale_pixel(pixel : Int) -> Int {
  let luminance = (
      77 * red(pixel) + 150 * green(pixel) + 29 * blue(pixel) + 128
    ) >>
    8
  pack_rgb(red=luminance, green=luminance, blue=luminance)
}

///|
fn abs_int(value : Int) -> Int {
  if value < 0 {
    -value
  } else {
    value
  }
}

///|
/// Computes one thresholded Sobel output from the eight neighboring pixels.
pub fn sobel_pixel(
  top_left : Int,
  top : Int,
  top_right : Int,
  left : Int,
  right : Int,
  bottom_left : Int,
  bottom : Int,
  bottom_right : Int,
  threshold~ : Int,
) -> Int {
  let gx = -red(top_left) +
    red(top_right) -
    2 * red(left) +
    2 * red(right) -
    red(bottom_left) +
    red(bottom_right)
  let gy = -red(top_left) -
    2 * red(top) -
    red(top_right) +
    red(bottom_left) +
    2 * red(bottom) +
    red(bottom_right)
  let magnitude = clamp_channel(abs_int(gx) + abs_int(gy))
  let output = if magnitude >= threshold { magnitude } else { 0 }
  pack_rgb(red=output, green=output, blue=output)
}

///|
fn grayscale_spec() -> @mayo.KernelSpec {
  @mayo.kernel_spec(id=1, layout_hash=0x47524159)
}

///|
fn sobel_spec() -> @mayo.KernelSpec {
  @mayo.kernel_spec(id=2, layout_hash=0x534F424C)
}

///|
/// The complete image pipeline contract shared by Host and Guest builds.
pub fn manifest() -> @mayo.KernelManifest {
  @mayo.kernel_manifest("mayo.example.image-pipeline/v1", [
    grayscale_spec(),
    sobel_spec(),
  ])
}

///|
pub fn grayscale() -> @mayo.KernelCall {
  @mayo.kernel_call(manifest(), grayscale_spec())
}

///|
pub fn detect_edges(threshold~ : Int) -> @mayo.KernelCall {
  if threshold < 0 || threshold > 255 {
    abort("Sobel threshold must be between 0 and 255")
  }
  @mayo.kernel_call(manifest(), sobel_spec(), argument=threshold)
}

///|
pub fn grayscale_entry(
  implementation : (@mayo.SharedSlice, Int, Int, Int) -> Unit,
) -> @mayo.KernelEntry {
  @mayo.kernel_entry(grayscale_spec(), implementation)
}

///|
pub fn sobel_entry(
  implementation : (@mayo.SharedSlice, Int, Int, Int) -> Unit,
) -> @mayo.KernelEntry {
  @mayo.kernel_entry(sobel_spec(), implementation)
}

///|
/// Writes an image header and source pixels into the Host shared buffer.
pub fn ImageLayout::initialize(
  self : ImageLayout,
  values : @mayo.SharedI32,
  pixels : Array[Int],
) -> Unit {
  if values.length() < self.capacity_ {
    abort("shared buffer is smaller than the image layout")
  }
  if pixels.length() != self.pixel_count_ {
    abort("source pixel count does not match the image layout")
  }
  values.store(0, IMAGE_MAGIC)
  values.store(1, self.width_)
  values.store(2, self.height_)
  values.store(3, self.source_offset_)
  values.store(4, self.scratch_offset_)
  values.store(5, self.pixel_count_)
  values.store(6, 0)
  values.store(7, 0)
  for index = 0; index < self.pixel_count_; index = index + 1 {
    values.store(self.source_index(index), pixels[index])
    values.store(self.scratch_index(index), 0)
  }
}

///|
pub fn ImageLayout::source_pixel(
  self : ImageLayout,
  values : @mayo.SharedI32,
  index : Int,
) -> Int {
  values.load(self.source_index(index))
}

///|
pub fn ImageLayout::scratch_pixel(
  self : ImageLayout,
  values : @mayo.SharedI32,
  index : Int,
) -> Int {
  values.load(self.scratch_index(index))
}

///|
/// Reads and validates the POD image header inside a Worker.
pub fn load_guest_layout(shared : @mayo.SharedSlice) -> ImageLayout {
  if shared.length() < HEADER_WORDS || shared.load(0) != IMAGE_MAGIC {
    abort("invalid shared image header")
  }
  let layout = image_layout(width=shared.load(1), height=shared.load(2))
  if shared.load(3) != layout.source_offset_ ||
    shared.load(4) != layout.scratch_offset_ ||
    shared.load(5) != layout.pixel_count_ ||
    shared.load(6) != 0 ||
    shared.load(7) != 0 ||
    shared.length() < layout.capacity_ {
    abort("shared image layout does not match its header")
  }
  layout
}
