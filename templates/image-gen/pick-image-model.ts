import { fileURLToPath } from "node:url";
import type { ImageGenerationRequirements } from "./image-generation-requirements";
import { readImageGenerationRequirements } from "./image-generation-requirements";
import { listModels } from "./list-image-models";

// Automated model selection for one asset spec, built on listModels()
// (list-image-models.ts) — the same fetch/adjust/cost work that tool
// prints for human review. selectImageModel() is the reusable core —
// generate-asset.ts calls it directly on the OpenRouter path (no
// auto-router exists on the Images API, so every request needs a concrete
// model chosen this way); main() below is just its CLI, for previewing a
// pick without spending on a real generation:
// `./pick-image-model --assets-dir <path> <asset-id>`.
//
// Selection algorithm, on top of what listModels() already filtered/
// priced:
//   1. Compute the true 30th-percentile price (not the mean) of the
//      cost-complete candidates, add a 10% margin, and drop everything
//      priced above that threshold — keeps a mid/cheap band and
//      deliberately excludes the expensive tail, while not being as
//      narrow as "only the single cheapest."
//   2. Pick uniformly at random from what's left, so repeated runs
//      explore across the cheap band instead of always hitting the same
//      provider.

export interface PickedModel {
  modelId: string;
  provider: string;
  usd: number;
}

export interface ModelSelection {
  picked: PickedModel;
  pool: PickedModel[]; // full candidate pool at/under the threshold, for auditability
  totalCandidates: number;
  priced: number;
  percentile30: number;
  threshold: number;
}

// Nearest-rank percentile over an already-ascending-sorted array — no
// interpolation, since we just need a real observed value to threshold
// against, not a statistically smoothed one.
function percentile(sortedAscending: number[], p: number): number {
  const index = Math.min(sortedAscending.length - 1, Math.floor(p * sortedAscending.length));
  return sortedAscending[index];
}

export async function selectImageModel(requirements: ImageGenerationRequirements): Promise<ModelSelection> {
  const { totalCandidates, complete } = await listModels(requirements);

  if (complete.length === 0) {
    throw new Error(`No priced candidate model/provider endpoints remain for requirements ${JSON.stringify(requirements)} after filtering — cannot pick.`);
  }

  const priced: PickedModel[] = complete.map((r) => ({ modelId: r.model.modelId, provider: r.model.provider, usd: r.estimate.usd }));
  const prices = priced.map((c) => c.usd); // already ascending — listModels() sorts complete by cost
  const percentile30 = percentile(prices, 0.3);
  const threshold = percentile30 * 1.1;
  const pool = priced.filter((c) => c.usd <= threshold);
  const picked = pool[Math.floor(Math.random() * pool.length)];

  return { picked, pool, totalCandidates, priced: priced.length, percentile30, threshold };
}

async function main() {
  const args = process.argv.slice(2);
  let assetsDir: string | undefined;
  const positional: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--assets-dir") {
      assetsDir = args[++i];
    } else {
      positional.push(args[i]);
    }
  }
  const assetId = positional[0];

  if (!assetsDir || !assetId) {
    throw new Error("Usage: pick-image-model --assets-dir <absolute-path> <asset-id>  (e.g. building-arena)");
  }

  const requirements = await readImageGenerationRequirements(assetsDir, assetId);
  const selection = await selectImageModel(requirements);
  const { picked, pool } = selection;

  console.log(
    `Asset "${assetId}": aspectRatio=${requirements.aspectRatio ?? "(any)"}, minResolution=${requirements.minResolution}, background=${requirements.background}.`,
  );
  console.log(`${selection.totalCandidates} model/provider endpoints considered, ${selection.priced} priced and supported.\n`);
  console.log(`30th percentile price: $${selection.percentile30.toFixed(4)}; threshold (+10%): $${selection.threshold.toFixed(4)}`);
  console.log(`Candidates at or under threshold: ${pool.length}\n`);

  console.log(`Picked: ${picked.modelId} (${picked.provider}) — $${picked.usd.toFixed(4)}`);

  console.log("\nFull candidate pool considered (sorted by price):");
  for (const c of pool) {
    console.log(`  ${c === picked ? "*" : " "} $${c.usd.toFixed(4)}  ${c.modelId}  (${c.provider})`);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exitCode = 1;
  });
}
