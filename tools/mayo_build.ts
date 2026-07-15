import { type DescriptorSchema, generateMoonBit } from "./mayo_gen.ts";

export type BuildTarget = "js" | "wasm";

export interface ArtifactConfig {
  package: string;
  target: BuildTarget;
  output: string;
}

export interface BuildConfig {
  version: 1;
  schema?: string;
  descriptor?: string;
  artifacts: ArtifactConfig[];
}

export interface ArtifactPlan extends ArtifactConfig {
  source: string;
}

export interface BuildPlan {
  schema?: string;
  descriptor?: string;
  artifacts: ArtifactPlan[];
}

function repositoryPath(value: unknown, label: string): string {
  if (
    typeof value !== "string" || value.length === 0 || value.startsWith("/") ||
    /^[A-Za-z]:[\\/]/.test(value) || value.split(/[\\/]/).includes("..")
  ) {
    throw new Error(`${label} must be a repository-relative path`);
  }
  return value.replaceAll("\\", "/");
}

export function parseBuildConfig(input: unknown): BuildConfig {
  if (typeof input !== "object" || input === null) {
    throw new Error("build config must be an object");
  }
  const raw = input as Record<string, unknown>;
  if (raw.version !== 1) throw new Error("build config version must be 1");
  const hasSchema = raw.schema !== undefined;
  const hasDescriptor = raw.descriptor !== undefined;
  if (hasSchema !== hasDescriptor) {
    throw new Error("schema and descriptor must be configured together");
  }
  if (!Array.isArray(raw.artifacts) || raw.artifacts.length === 0) {
    throw new Error("build config must contain at least one artifact");
  }
  const artifacts = raw.artifacts.map((inputArtifact) => {
    if (typeof inputArtifact !== "object" || inputArtifact === null) {
      throw new Error("artifact must be an object");
    }
    const artifact = inputArtifact as Record<string, unknown>;
    if (artifact.target !== "js" && artifact.target !== "wasm") {
      throw new Error("artifact target must be js or wasm");
    }
    const target: BuildTarget = artifact.target;
    return {
      package: repositoryPath(artifact.package, "artifact package"),
      target,
      output: repositoryPath(artifact.output, "artifact output"),
    };
  });
  return {
    version: 1,
    schema: hasSchema ? repositoryPath(raw.schema, "schema") : undefined,
    descriptor: hasDescriptor ? repositoryPath(raw.descriptor, "descriptor") : undefined,
    artifacts,
  };
}

export function buildPlan(config: BuildConfig): BuildPlan {
  return {
    schema: config.schema,
    descriptor: config.descriptor,
    artifacts: config.artifacts.map((artifact) => {
      const packageName = artifact.package.split("/").at(-1)!;
      const extension = artifact.target === "js" ? "js" : "wasm";
      return {
        ...artifact,
        source:
          `_build/${artifact.target}/release/build/${artifact.package}/${packageName}.${extension}`,
      };
    }),
  };
}

function normalized(source: string): string {
  return source
    .replace(/\b([a-z][a-z0-9_]*)~(?=\s*[,\)])/g, "$1=$1")
    .replace(/\s+/g, "")
    .replace(/,([}\]\)])/g, "$1");
}

async function run(command: string, args: string[]): Promise<void> {
  const status = await new Deno.Command(command, {
    args,
    stdin: "null",
    stdout: "inherit",
    stderr: "inherit",
  }).output();
  if (!status.success) throw new Error(`${command} ${args.join(" ")} failed`);
}

function parentDirectory(path: string): string {
  const separator = path.lastIndexOf("/");
  return separator < 0 ? "." : path.slice(0, separator);
}

async function execute(configPath: string, check: boolean): Promise<void> {
  const config = parseBuildConfig(JSON.parse(await Deno.readTextFile(configPath)));
  const plan = buildPlan(config);
  if (plan.schema !== undefined && plan.descriptor !== undefined) {
    const schema = JSON.parse(await Deno.readTextFile(plan.schema)) as DescriptorSchema;
    const generated = generateMoonBit(schema);
    if (check) {
      const current = await Deno.readTextFile(plan.descriptor);
      if (normalized(current) !== normalized(generated)) {
        throw new Error(`${plan.descriptor} is stale`);
      }
    } else {
      await Deno.writeTextFile(plan.descriptor, generated);
      await run("moon", ["fmt"]);
    }
  }
  if (check) return;
  for (const artifact of plan.artifacts) {
    await run("moon", [
      "build",
      artifact.package,
      "--target",
      artifact.target,
      "--release",
    ]);
    await Deno.mkdir(parentDirectory(artifact.output), { recursive: true });
    await Deno.copyFile(artifact.source, artifact.output);
    console.log(`${artifact.target}: ${artifact.output}`);
  }
}

async function main(): Promise<void> {
  const [configPath = "mayo.build.json", mode] = Deno.args;
  if (mode !== undefined && mode !== "--check") {
    throw new Error("usage: mayo_build.ts [CONFIG.json] [--check]");
  }
  await execute(configPath, mode === "--check");
}

if (import.meta.main) await main();
