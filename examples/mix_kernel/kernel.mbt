///|
/// Shared manifest for the generated Host descriptors and Guest registry.
pub fn manifest() -> @mayo.KernelManifest {
  @mayo.kernel_manifest("mayo.example.i32-kernels/v1", [mix_spec(), add_spec()])
}

///|
fn mix_spec() -> @mayo.KernelSpec {
  @mayo.kernel_spec(id=1, layout_hash=0x4D495801)
}

///|
fn add_spec() -> @mayo.KernelSpec {
  @mayo.kernel_spec(id=2, layout_hash=0x41444401)
}

///|
/// Builds the typed Host descriptor for the prebuilt mix kernel.
pub fn mix(rounds~ : Int) -> @mayo.KernelCall {
  @mayo.kernel_call(manifest(), mix_spec(), argument=rounds)
}

///|
/// Builds the typed Host descriptor for the prebuilt add kernel.
pub fn add(delta~ : Int) -> @mayo.KernelCall {
  @mayo.kernel_call(manifest(), add_spec(), argument=delta)
}

///|
/// Builds a no-op call used to demonstrate scoped task submission.
pub fn noop() -> @mayo.KernelCall {
  mix(rounds=0)
}

///|
/// Binds the generated mix spec to its Guest implementation.
pub fn mix_entry(
  kernel : (@mayo.SharedSlice, Int, Int, Int) -> Unit,
) -> @mayo.KernelEntry {
  @mayo.kernel_entry(mix_spec(), kernel)
}

///|
/// Binds the generated add spec to its Guest implementation.
pub fn add_entry(
  kernel : (@mayo.SharedSlice, Int, Int, Int) -> Unit,
) -> @mayo.KernelEntry {
  @mayo.kernel_entry(add_spec(), kernel)
}
