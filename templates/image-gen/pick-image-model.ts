import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  type AssetSpec,
  type EndpointEntry,
  estimateCost,
  estimateTokens,
  supportsAspectRatio,
  supportsBackground,
  supportsMinResolution,
} from "./image-cost-estimate";
import { fetchEndpoints, fetchModelList } from "./openrouter-images-api";

// Automated model selection for one asset spec, built on the same data
// list-image-models.ts prints for human review. selectImageModel() is the
// reusable core — generate-asset.ts calls it directly on the OpenRouter
// path (no auto-router exists on the Images API, so every request needs a
// concrete model chosen this way); main() below is just its CLI, for
// previewing a pick without spending on a real generation:
// `./pick-image-model --assets-dir <path> <asset-id>`.
//
// Selection algorithm:
//   1. Filter to endpoints that support the asset's aspectRatio (if any)
//      and declare enough resolution to meet its minResolution floor.
//   2. Drop endpoints with no computable price.
//   3. Sort what's left by estimated price, ascending.
//   4. Compute the true 30th-percentile price (not the mean) of that
//      sorted list, add a 10% margin, and drop everything priced above
//      that threshold — this keeps a mid/cheap band and deliberately
//      excludes the expensive tail, while not being as narrow as "only
//      the single cheapest."
//   5. Pick uniformly at random from what's left, so repeated runs
//      explore across the cheap band instead of always hitting the same
//      provider.
//
// Background is NOT a filter criterion — every candidate is assumed
// usable regardless of transparency support. Whether the picked model
// natively supports transparent backgrounds is exposed via its
// `endpoint.supported_parameters` so the caller (generate-asset.ts) can
// decide whether to skip or run chroma-key cleanup; it never removes a
// model from consideration.

export interface PickedModel {
  modelId: string;
  provider: string;
  usd: number;
  endpoint: EndpointEntry;
}

export interface ModelSelection {
  picked: PickedModel;
  pool: PickedModel[]; // full candidate pool at/under the threshold, for auditability
  modelCount: number;
  totalEndpoints: number;
  afterAspectFilter: number;
  afterResolutionFilter: number;
  afterPricingFilter: number;
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

export async function selectImageModel(spec: AssetSpec, promptTokens: number): Promise<ModelSelection> {
  const models = await fetchModelList();
  const endpointLists = await Promise.all(models.map((model) => fetchEndpoints(model.id)));

  const allEndpoints: { modelId: string; endpoint: EndpointEntry }[] = [];
  models.forEach((model, i) => {
    for (const endpoint of endpointLists[i]) {
      allEndpoints.push({ modelId: model.id, endpoint });
    }
  });

  const aspectFiltered = allEndpoints.filter(({ endpoint }) => supportsAspectRatio(endpoint.supported_parameters, spec.aspectRatio));
  const resolutionFiltered = aspectFiltered.filter(({ endpoint }) => supportsMinResolution(endpoint.supported_parameters, spec.minResolution));

  const priced: PickedModel[] = [];
  for (const { modelId, endpoint } of resolutionFiltered) {
    const estimate = estimateCost(endpoint, spec, promptTokens);
    if (estimate && !estimate.note) {
      priced.push({ modelId, provider: endpoint.provider_name, usd: estimate.usd, endpoint });
    }
  }

  if (priced.length === 0) {
    throw new Error(`No priced candidate model/provider endpoints remain for spec ${JSON.stringify(spec)} after filtering — cannot pick.`);
  }

  priced.sort((a, b) => a.usd - b.usd);
  const prices = priced.map((c) => c.usd);
  const percentile30 = percentile(prices, 0.3);
  const threshold = percentile30 * 1.1;
  const pool = priced.filter((c) => c.usd <= threshold);
  const picked = pool[Math.floor(Math.random() * pool.length)];

  return {
    picked,
    pool,
    modelCount: models.length,
    totalEndpoints: allEndpoints.length,
    afterAspectFilter: aspectFiltered.length,
    afterResolutionFilter: resolutionFiltered.length,
    afterPricingFilter: priced.length,
    percentile30,
    threshold,
  };
}

async function readSpec(assetsDir: string, assetId: string): Promise<AssetSpec> {
  return JSON.parse(await readFile(resolve(assetsDir, `${assetId}.json`), "utf8")) as AssetSpec;
}

async function readPromptText(assetsDir: string, assetId: string): Promise<string> {
  return (await readFile(resolve(assetsDir, `${assetId}.prompt.txt`), "utf8")).trim();
}

// The caller's actual directory, not this process's real cwd — see
// bin/pick-image-model's own comment for why the two differ (vite-node
// needs real cwd to be this package's own directory to resolve
// dependencies correctly) and how IMAGE_GEN_CALLER_CWD bridges that.
function callerCwd(): string {
  return process.env.IMAGE_GEN_CALLER_CWD ?? process.cwd();
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
    throw new Error("Usage: pick-image-model --assets-dir <path> <asset-id>  (e.g. building-arena)");
  }

  const resolvedAssetsDir = resolve(callerCwd(), assetsDir);
  const spec = await readSpec(resolvedAssetsDir, assetId);
  const promptText = await readPromptText(resolvedAssetsDir, assetId);
  const promptTokens = estimateTokens(promptText);

  const selection = await selectImageModel(spec, promptTokens);
  const { picked, pool } = selection;
  const transparentSupported = supportsBackground(picked.endpoint.supported_parameters, "transparent");

  console.log(`Asset "${assetId}": aspectRatio=${spec.aspectRatio ?? "(any)"}, minResolution=${spec.minResolution}, background=${spec.background}.`);
  console.log(`${selection.totalEndpoints} model/provider endpoints across ${selection.modelCount} models.\n`);
  console.log(`After aspect ratio filter: ${selection.afterAspectFilter}`);
  console.log(`After minResolution filter: ${selection.afterResolutionFilter}`);
  console.log(`After dropping unpriced/partial estimates: ${selection.afterPricingFilter}`);
  console.log(`30th percentile price: $${selection.percentile30.toFixed(4)}; threshold (+10%): $${selection.threshold.toFixed(4)}`);
  console.log(`Candidates at or under threshold: ${pool.length}\n`);

  console.log(`Picked: ${picked.modelId} (${picked.provider}) — $${picked.usd.toFixed(4)}`);
  console.log(`Native transparent background support: ${transparentSupported ? "yes — skip chroma-key cleanup" : "no — chroma-key cleanup needed"}`);

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
