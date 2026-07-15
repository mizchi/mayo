export type PodFieldType = "i32" | "slice_i32";

export interface PodFieldSchema {
  name: string;
  type: PodFieldType;
}

export interface PodLayoutSchema {
  name: string;
  fields: PodFieldSchema[];
}

export interface KernelSchema {
  name: string;
  id: number;
  kind?: "map" | "reduce";
  layout?: string;
  argument?: string;
}

export interface DescriptorSchema {
  version: 1;
  manifest: string;
  layouts?: PodLayoutSchema[];
  kernels: KernelSchema[];
}

const moonKeywords = new Set([
  "as",
  "async",
  "break",
  "catch",
  "const",
  "continue",
  "derive",
  "else",
  "enum",
  "fn",
  "for",
  "guard",
  "if",
  "impl",
  "in",
  "let",
  "loop",
  "match",
  "priv",
  "pub",
  "raise",
  "return",
  "struct",
  "test",
  "trait",
  "try",
  "type",
  "while",
  "with",
]);

function assertSnakeName(name: string, description: string): void {
  if (!/^[a-z][a-z0-9_]*$/.test(name) || moonKeywords.has(name)) {
    throw new Error(`${description} must be a non-keyword snake_case MoonBit identifier`);
  }
}

function assertTypeName(name: string): void {
  if (!/^[A-Z][A-Za-z0-9]*$/.test(name)) {
    throw new Error("layout name must be a PascalCase MoonBit identifier");
  }
}

function snakeCase(name: string): string {
  return name.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
}

function fnv1a32(value: string): number {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(value)) {
    hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  }
  const signed = hash | 0;
  return signed === 0 ? 1 : signed;
}

function validateSchema(schema: DescriptorSchema): {
  layouts: PodLayoutSchema[];
  kernels: KernelSchema[];
} {
  if (schema.version !== 1) {
    throw new Error("descriptor schema version must be 1");
  }
  if (!/^[\x21-\x7e]+$/.test(schema.manifest)) {
    throw new Error("manifest must be non-empty printable ASCII without spaces");
  }
  const layouts = schema.layouts ?? [];
  const layoutNames = new Set<string>();
  for (const layout of layouts) {
    assertTypeName(layout.name);
    if (layoutNames.has(layout.name)) {
      throw new Error(`duplicate layout name ${layout.name}`);
    }
    layoutNames.add(layout.name);
    if (layout.fields.length === 0) {
      throw new Error(`layout ${layout.name} must contain at least one field`);
    }
    const fieldNames = new Set<string>();
    for (const field of layout.fields) {
      assertSnakeName(field.name, "field name");
      if (fieldNames.has(field.name)) {
        throw new Error(`duplicate field ${field.name} in layout ${layout.name}`);
      }
      fieldNames.add(field.name);
      if (field.type !== "i32" && field.type !== "slice_i32") {
        throw new Error(`unsupported field type ${String(field.type)}`);
      }
    }
  }
  if (!Array.isArray(schema.kernels) || schema.kernels.length === 0) {
    throw new Error("descriptor must contain at least one kernel");
  }
  const kernelNames = new Set<string>();
  const kernelIds = new Set<number>();
  for (const kernel of schema.kernels) {
    assertSnakeName(kernel.name, "kernel name");
    if (kernel.argument !== undefined) {
      assertSnakeName(kernel.argument, "kernel argument");
    }
    if (kernel.kind !== undefined && kernel.kind !== "map" && kernel.kind !== "reduce") {
      throw new Error(`unsupported kernel kind ${String(kernel.kind)}`);
    }
    if (!Number.isSafeInteger(kernel.id) || kernel.id <= 0 || kernel.id > 0x7fffffff) {
      throw new Error("kernel ID must be a positive Int32");
    }
    if (kernelNames.has(kernel.name)) {
      throw new Error(`duplicate kernel name ${kernel.name}`);
    }
    if (kernelIds.has(kernel.id)) {
      throw new Error("kernel IDs must be unique");
    }
    kernelNames.add(kernel.name);
    kernelIds.add(kernel.id);
    if (kernel.layout !== undefined && !layoutNames.has(kernel.layout)) {
      throw new Error(`kernel ${kernel.name} references unknown layout ${kernel.layout}`);
    }
  }
  return { layouts, kernels: [...schema.kernels].sort((left, right) => left.id - right.id) };
}

function canonicalKernel(
  schema: DescriptorSchema,
  kernel: KernelSchema,
  layouts: PodLayoutSchema[],
): string {
  const layout = layouts.find((candidate) => candidate.name === kernel.layout);
  const layoutShape = layout === undefined
    ? "none"
    : `${layout.name}{${layout.fields.map((field) => `${field.name}:${field.type}`).join(",")}}`;
  return [
    "mayo.descriptor/v1",
    schema.manifest,
    kernel.name,
    `kind:${kernel.kind ?? "map"}`,
    kernel.argument === undefined ? "argument:none" : `argument:${kernel.argument}:i32`,
    `layout:${layoutShape}`,
  ].join("|");
}

function headerSlots(layout: PodLayoutSchema): Map<string, number[]> {
  const result = new Map<string, number[]>();
  let slot = 0;
  for (const field of layout.fields) {
    if (field.type === "i32") {
      result.set(field.name, [slot++]);
    } else {
      result.set(field.name, [slot++, slot++]);
    }
  }
  return result;
}

function renderLayout(layout: PodLayoutSchema): string {
  const functionName = snakeCase(layout.name);
  const slots = headerSlots(layout);
  const headerWords = [...slots.values()].reduce(
    (count, fieldSlots) => count + fieldSlots.length,
    0,
  );
  const fields = layout.fields.flatMap((field) =>
    field.type === "i32"
      ? [`  priv ${field.name}_ : Int`]
      : [`  priv ${field.name}_offset_ : Int`, `  priv ${field.name}_length_ : Int`]
  );
  fields.unshift("  priv base_ : Int");
  fields.push("  priv capacity_ : Int");

  const parameters = layout.fields.map((field) =>
    field.type === "i32" ? `  ${field.name}~ : Int,` : `  ${field.name}_length~ : Int,`
  );
  const forwardedParameters = layout.fields.map((field) =>
    field.type === "i32"
      ? `    ${field.name}=${field.name},`
      : `    ${field.name}_length=${field.name}_length,`
  );
  const lengthChecks = layout.fields
    .filter((field) => field.type === "slice_i32")
    .map((field) =>
      `  if ${field.name}_length < 0 {\n    abort("${field.name} length must not be negative")\n  }`
    );
  const offsetLines: string[] = [];
  let previous = `base + ${headerWords}`;
  for (const field of layout.fields) {
    if (field.type !== "slice_i32") continue;
    offsetLines.push(`  let ${field.name}_offset = ${previous}`);
    offsetLines.push(`  let after_${field.name} = ${field.name}_offset + ${field.name}_length`);
    offsetLines.push(
      `  if after_${field.name} < ${field.name}_offset {\n    abort("${layout.name} layout exceeds Int32 capacity")\n  }`,
    );
    previous = `after_${field.name}`;
  }
  const initializers = layout.fields.map((field) =>
    field.type === "i32"
      ? `    ${field.name}_: ${field.name},`
      : `    ${field.name}_offset_: ${field.name}_offset,\n    ${field.name}_length_: ${field.name}_length,`
  );
  initializers.unshift("    base_: base,");
  initializers.push(`    capacity_: ${previous} - base,`);

  const getters = layout.fields.flatMap((field) => {
    if (field.type === "i32") {
      return [
        `///|\npub fn ${layout.name}Layout::${field.name}(self : ${layout.name}Layout) -> Int {\n  self.${field.name}_\n}`,
      ];
    }
    return [
      `///|\npub fn ${layout.name}Layout::${field.name}_offset(self : ${layout.name}Layout) -> Int {\n  self.${field.name}_offset_\n}`,
      `///|\npub fn ${layout.name}Layout::${field.name}_length(self : ${layout.name}Layout) -> Int {\n  self.${field.name}_length_\n}`,
      `///|\npub fn ${layout.name}Layout::${field.name}_index(self : ${layout.name}Layout, index : Int) -> Int {\n  if index < 0 || index >= self.${field.name}_length_ {\n    abort("${field.name} index is outside the shared slice")\n  }\n  self.${field.name}_offset_ + index\n}`,
    ];
  });
  getters.unshift(
    `///|\npub fn ${layout.name}Layout::base(self : ${layout.name}Layout) -> Int {\n  self.base_\n}`,
  );
  getters.push(
    `///|\npub fn ${layout.name}Layout::capacity(self : ${layout.name}Layout) -> Int {\n  self.capacity_\n}`,
  );

  const stores = layout.fields.flatMap((field) => {
    const fieldSlots = slots.get(field.name)!;
    return field.type === "i32"
      ? [`  values.store(self.base_ + ${fieldSlots[0]}, self.${field.name}_)`]
      : [
        `  values.store(self.base_ + ${fieldSlots[0]}, self.${field.name}_offset_)`,
        `  values.store(self.base_ + ${fieldSlots[1]}, self.${field.name}_length_)`,
      ];
  });
  const loadArguments = layout.fields.map((field) => {
    const fieldSlots = slots.get(field.name)!;
    return field.type === "i32"
      ? `    ${field.name}=shared.load(base + ${fieldSlots[0]}),`
      : `    ${field.name}_length=shared.load(base + ${fieldSlots[1]}),`;
  });
  const validations = layout.fields
    .filter((field) => field.type === "slice_i32")
    .map((field) => {
      const fieldSlots = slots.get(field.name)!;
      return `shared.load(base + ${fieldSlots[0]}) != layout.${field.name}_offset_`;
    });
  validations.push("shared.length() < layout.base_ + layout.capacity_");

  return `///|\n/// Generated POD layout shared by Host and Guest builds.\npub struct ${layout.name}Layout {\n${
    fields.join("\n")
  }\n}\n\n///|\npub fn ${functionName}_layout(\n${
    parameters.join("\n")
  }\n) -> ${layout.name}Layout {\n  ${functionName}_layout_at(\n    base=0,\n${
    forwardedParameters.join("\n")
  }\n  )\n}\n\n///|\npub fn ${functionName}_layout_at(\n  base~ : Int,\n${
    parameters.join("\n")
  }\n) -> ${layout.name}Layout {\n  if base < 0 {\n    abort("${layout.name} base must not be negative")\n  }\n${
    lengthChecks.join("\n")
  }\n${offsetLines.join("\n")}\n  {\n${initializers.join("\n")}\n  }\n}\n\n${
    getters.join("\n\n")
  }\n\n///|\npub fn allocate_${functionName}_layout(\n  arena : @mayo.SharedArena,\n${
    parameters.join("\n")
  }\n) -> ${layout.name}Layout raise @mayo.PoolError {\n  let shape = ${functionName}_layout(\n${
    forwardedParameters.join("\n")
  }\n  )\n  let region = arena.allocate(length=shape.capacity())\n  let layout = ${functionName}_layout_at(\n    base=region.offset(),\n${
    forwardedParameters.join("\n")
  }\n  )\n  layout.write_header(arena.shared_i32())\n  layout\n}\n\n///|\npub fn ${layout.name}Layout::write_header(\n  self : ${layout.name}Layout,\n  values : @mayo.SharedI32,\n) -> Unit {\n  if values.length() < self.base_ + self.capacity_ {\n    abort("shared buffer is smaller than the ${layout.name} layout")\n  }\n${
    stores.join("\n")
  }\n}\n\n///|\npub fn load_${functionName}_layout(\n  shared : @mayo.SharedSlice,\n  base? : Int = 0,\n) -> ${layout.name}Layout {\n  if base < 0 || shared.length() < base + ${headerWords} {\n    abort("shared buffer is smaller than the ${layout.name} header")\n  }\n  let layout = ${functionName}_layout_at(\n    base~,\n${
    loadArguments.join("\n")
  }\n  )\n  if ${
    validations.join(" ||\n    ")
  } {\n    abort("shared ${layout.name} header does not match its POD layout")\n  }\n  layout\n}`;
}

function renderKernel(
  schema: DescriptorSchema,
  kernel: KernelSchema,
  layouts: PodLayoutSchema[],
): string {
  const hash = fnv1a32(canonicalKernel(schema, kernel, layouts));
  const callParameters = kernel.argument === undefined ? "" : `${kernel.argument}~ : Int`;
  const callArgument = kernel.argument === undefined ? "" : `, argument=${kernel.argument}`;
  const reducer = kernel.kind === "reduce";
  const specConstructor = reducer ? "reducer_spec" : "kernel_spec";
  const callType = reducer ? "ReducerCall" : "KernelCall";
  const callConstructor = reducer ? "reducer_call" : "kernel_call";
  const resultType = reducer ? "Int" : "Unit";
  const entryConstructor = reducer ? "reducer_entry" : "kernel_entry";
  return `///|\nfn ${kernel.name}_spec() -> @mayo.KernelSpec {\n  @mayo.${specConstructor}(id=${kernel.id}, layout_hash=${hash})\n}\n\n///|\npub fn ${kernel.name}(${callParameters}) -> @mayo.${callType} {\n  @mayo.${callConstructor}(manifest(), ${kernel.name}_spec()${callArgument})\n}\n\n///|\npub fn ${kernel.name}_entry(\n  implementation : (@mayo.SharedSlice, Int, Int, Int) -> ${resultType},\n) -> @mayo.KernelEntry {\n  @mayo.${entryConstructor}(${kernel.name}_spec(), implementation)\n}`;
}

export function generateMoonBit(schema: DescriptorSchema): string {
  const { layouts, kernels } = validateSchema(schema);
  const renderedLayouts = layouts.map(renderLayout);
  const renderedKernels = kernels.map((kernel) => renderKernel(schema, kernel, layouts));
  const specs = kernels.map((kernel) => `    ${kernel.name}_spec(),`).join("\n");
  const manifest =
    `///|\n/// Generated Host/Guest kernel manifest.\npub fn manifest() -> @mayo.KernelManifest {\n  @mayo.kernel_manifest("${schema.manifest}", [\n${specs}\n  ])\n}`;
  return `// Generated by tools/mayo_gen.ts. DO NOT EDIT.\n\n${
    [
      ...renderedLayouts,
      ...renderedKernels,
      manifest,
    ].join("\n\n")
  }\n`;
}

async function main(): Promise<void> {
  const [schemaPath, outputPath, mode] = Deno.args;
  if (
    schemaPath === undefined || outputPath === undefined ||
    (mode !== undefined && mode !== "--check")
  ) {
    throw new Error("usage: mayo_gen.ts SCHEMA.json OUTPUT.mbt [--check]");
  }
  const schema = JSON.parse(await Deno.readTextFile(schemaPath)) as DescriptorSchema;
  const generated = generateMoonBit(schema);
  if (mode === "--check") {
    const current = await Deno.readTextFile(outputPath);
    const normalize = (source: string) =>
      source
        .replace(/\b([a-z][a-z0-9_]*)~(?=\s*[,\)])/g, "$1=$1")
        .replace(/\s+/g, "")
        .replace(/,([}\]\)])/g, "$1");
    if (normalize(current) !== normalize(generated)) {
      throw new Error(`${outputPath} is stale; regenerate it from ${schemaPath}`);
    }
    return;
  }
  await Deno.writeTextFile(outputPath, generated);
}

if (import.meta.main) await main();
