export interface Summary {
  count: number;
  min: number;
  median: number;
  p95: number;
  max: number;
  mean: number;
}

function percentile(sorted: readonly number[], ratio: number): number {
  if (sorted.length === 1) return sorted[0];
  const position = (sorted.length - 1) * ratio;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  const weight = position - lower;
  return sorted[lower] * (1 - weight) + sorted[upper] * weight;
}

export function summarize(values: readonly number[]): Summary {
  if (values.length === 0) throw new Error("summarize requires at least one value");
  const sorted = values.toSorted((left, right) => left - right);
  const total = sorted.reduce((sum, value) => sum + value, 0);
  return {
    count: sorted.length,
    min: sorted[0],
    median: percentile(sorted, 0.5),
    p95: percentile(sorted, 0.95),
    max: sorted.at(-1)!,
    mean: total / sorted.length,
  };
}
