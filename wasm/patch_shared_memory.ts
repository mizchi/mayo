function readU32(bytes: Uint8Array, start: number): [number, number] {
  let value = 0;
  let shift = 0;
  let offset = start;
  while (offset < bytes.length) {
    const byte = bytes[offset++];
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return [value >>> 0, offset];
    shift += 7;
    if (shift > 35) throw new Error("invalid Wasm u32 encoding");
  }
  throw new Error("truncated Wasm u32 encoding");
}

function readName(bytes: Uint8Array, start: number): [string, number] {
  const [length, contents] = readU32(bytes, start);
  const end = contents + length;
  if (end > bytes.length) throw new Error("truncated Wasm name");
  return [new TextDecoder().decode(bytes.subarray(contents, end)), end];
}

/**
 * Marks MoonBit's imported `env.memory` as shared.
 *
 * MoonBit emits a bounded, non-shared memory import. Sharedness is one bit in
 * the Wasm limits flags, so changing `0x01` (min + max) to `0x03` preserves all
 * section offsets and does not rewrite executable code.
 */
export function patchSharedMemory(input: Uint8Array): Uint8Array {
  if (
    input.length < 8 ||
    input[0] !== 0x00 || input[1] !== 0x61 ||
    input[2] !== 0x73 || input[3] !== 0x6d
  ) {
    throw new Error("input is not a WebAssembly module");
  }
  const bytes = input.slice();
  let offset = 8;
  while (offset < bytes.length) {
    const sectionId = bytes[offset++];
    const [sectionLength, contents] = readU32(bytes, offset);
    const sectionEnd = contents + sectionLength;
    if (sectionEnd > bytes.length) throw new Error("truncated Wasm section");
    offset = contents;
    if (sectionId !== 2) {
      offset = sectionEnd;
      continue;
    }

    const [count, firstImport] = readU32(bytes, offset);
    offset = firstImport;
    for (let index = 0; index < count; index++) {
      const [moduleName, afterModule] = readName(bytes, offset);
      const [fieldName, afterField] = readName(bytes, afterModule);
      const kind = bytes[afterField];
      offset = afterField + 1;
      if (kind !== 2) {
        throw new Error(
          "shared-memory patch expects env.memory to be the only Wasm import",
        );
      }
      const flagsOffset = offset;
      const [flags, afterFlags] = readU32(bytes, flagsOffset);
      const [, afterMinimum] = readU32(bytes, afterFlags);
      const hasMaximum = (flags & 0x01) !== 0;
      offset = hasMaximum ? readU32(bytes, afterMinimum)[1] : afterMinimum;
      if (moduleName !== "env" || fieldName !== "memory") continue;
      if (!hasMaximum) {
        throw new Error("shared env.memory requires a declared maximum");
      }
      if (flags === 0x03) return bytes;
      if (flags !== 0x01 || afterFlags !== flagsOffset + 1) {
        throw new Error("unsupported env.memory limits flags");
      }
      bytes[flagsOffset] = 0x03;
      return bytes;
    }
    break;
  }
  throw new Error("Wasm module does not import env.memory");
}

if (import.meta.main) {
  const [inputPath, outputPath] = Deno.args;
  if (!inputPath || !outputPath) {
    throw new Error("usage: patch_shared_memory.ts INPUT.wasm OUTPUT.wasm");
  }
  const patched = patchSharedMemory(await Deno.readFile(inputPath));
  await Deno.writeFile(outputPath, patched);
}
