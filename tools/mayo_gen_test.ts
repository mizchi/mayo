import assert from "node:assert/strict";
import { type DescriptorSchema, generateMoonBit } from "./mayo_gen.ts";

const imageSchema: DescriptorSchema = {
  version: 1,
  manifest: "example/image/v1",
  layouts: [
    {
      name: "Image",
      fields: [
        { name: "width", type: "i32" },
        { name: "height", type: "i32" },
        { name: "source", type: "slice_i32" },
        { name: "scratch", type: "slice_i32" },
      ],
    },
  ],
  kernels: [
    { name: "grayscale", id: 1, layout: "Image" },
    {
      name: "detect_edges",
      id: 2,
      layout: "Image",
      argument: "threshold",
    },
    { name: "sum_pixels", id: 3, layout: "Image", kind: "reduce" },
  ],
};

Deno.test("generator emits typed Host, Guest, and POD layout surfaces", () => {
  const generated = generateMoonBit(imageSchema);
  assert.match(generated, /pub struct ImageLayout/);
  assert.match(
    generated,
    /pub fn image_layout\([\s\S]*width~ : Int[\s\S]*source_length~ : Int/,
  );
  assert.match(generated, /pub fn ImageLayout::write_header/);
  assert.match(generated, /pub fn load_image_layout/);
  assert.match(generated, /pub fn image_layout_at\([\s\S]*base~ : Int/);
  assert.match(generated, /pub fn allocate_image_layout\(/);
  assert.match(generated, /arena\.allocate\(length=shape\.capacity\(\)\)/);
  assert.match(generated, /pub fn grayscale\(\) -> @mayo\.KernelCall/);
  assert.match(
    generated,
    /pub fn detect_edges\(threshold~ : Int\) -> @mayo\.KernelCall/,
  );
  assert.match(generated, /pub fn detect_edges_entry/);
  assert.match(generated, /pub fn sum_pixels\(\) -> @mayo\.ReducerCall/);
  assert.match(
    generated,
    /pub fn sum_pixels_entry\([\s\S]*\) -> @mayo\.KernelEntry/,
  );
  assert.match(generated, /@mayo\.reducer_spec\(id=3,/);
  assert.doesNotMatch(generated, /layout_hash=0/);
  assert.equal(generateMoonBit(imageSchema), generated);
});

Deno.test("generated layout hash changes when the POD contract changes", () => {
  const first = generateMoonBit(imageSchema);
  const changed = structuredClone(imageSchema);
  changed.layouts![0].fields[0].name = "columns";
  const second = generateMoonBit(changed);
  const hashPattern = /fn grayscale_spec[\s\S]*?layout_hash=(-?\d+)/;
  assert.notEqual(first.match(hashPattern)?.[1], second.match(hashPattern)?.[1]);
});

Deno.test("generator rejects duplicate kernel IDs and unknown layouts", () => {
  assert.throws(
    () =>
      generateMoonBit({
        version: 1,
        manifest: "example/invalid/v1",
        kernels: [
          { name: "first", id: 1 },
          { name: "second", id: 1 },
        ],
      }),
    /kernel IDs must be unique/,
  );
  assert.throws(
    () =>
      generateMoonBit({
        version: 1,
        manifest: "example/invalid/v1",
        kernels: [{ name: "run", id: 1, layout: "Missing" }],
      }),
    /unknown layout Missing/,
  );
});
