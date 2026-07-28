import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type CostEstimate, type EndpointEntry, type ParamSpec, estimateCost, estimateTokens, tierMegapixels } from "./image-cost-estimate";
import { type ImageGenerationRequirements, readImageGenerationRequirements } from "./image-generation-requirements";
import { fetchEndpoints, fetchModelList } from "./openrouter-images-api";

// Standalone discovery tool, not used by generate-asset.ts itself — we
// have no "auto" model on OpenRouter's Images API (unlike chat
// completions), so this estimates a real dollar cost per candidate
// model/provider endpoint for one specific asset's actual spec + prompt,
// so a model can be picked deliberately instead of guessed. Run via
// `./list-image-models --assets-dir <path> <asset-id>` (e.g.
// building-arena). The estimation logic itself lives in
// image-cost-estimate.ts, which is also what image-cost-estimate.test.ts
// checks against real recorded generations — this file is just the CLI:
// fetch, run the estimate, print. See pick-image-model.ts for the
// filtered/automated-selection version of this same data.

// The caller's actual directory, not this process's real cwd — see
// bin/list-image-models's own comment for why the two differ (vite-node
// needs real cwd to be this package's own directory to resolve
// dependencies correctly) and how IMAGE_GEN_CALLER_CWD bridges that.
function callerCwd(): string {
  return process.env.IMAGE_GEN_CALLER_CWD ?? process.cwd();
}

// Prints how many of the given endpoints declare support for each
// parameter/value — a landscape overview to inform filtering criteria,
// not filtering itself (feature filtering elsewhere in this file is still
// deliberately disabled — see the note in main()).
function printFeatureSupport(endpoints: EndpointEntry[]): void {
  const enumTally = new Map<string, Map<string, number>>(); // paramName -> value -> endpoint count
  const otherTally = new Map<string, { count: number; sample: ParamSpec }>(); // paramName -> endpoints declaring it (range/boolean params)

  for (const endpoint of endpoints) {
    for (const [paramName, paramSpec] of Object.entries(endpoint.supported_parameters ?? {})) {
      if (paramSpec.type === "enum" && paramSpec.values) {
        const valueCounts = enumTally.get(paramName) ?? new Map<string, number>();
        for (const value of paramSpec.values) {
          valueCounts.set(value, (valueCounts.get(value) ?? 0) + 1);
        }
        enumTally.set(paramName, valueCounts);
      } else {
        const entry = otherTally.get(paramName) ?? { count: 0, sample: paramSpec };
        entry.count += 1;
        otherTally.set(paramName, entry);
      }
    }
  }

  console.log(`Feature support across ${endpoints.length} model/provider endpoints:\n`);
  for (const [paramName, valueCounts] of [...enumTally.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    console.log(`${paramName}:`);
    for (const [value, count] of [...valueCounts.entries()].sort((a, b) => b[1] - a[1])) {
      console.log(`  ${value} — ${count}`);
    }
  }
  for (const [paramName, { count, sample }] of [...otherTally.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const range = sample.type === "range" ? ` (range ${sample.min}-${sample.max})` : "";
    console.log(`${paramName}: ${count}${range}`);
  }
  console.log("");
}

export interface ModelCostRow {
  modelId: string;
  provider: string;
  estimate: CostEstimate;
}

export interface ModelCostListing {
  models: { id: string }[];
  endpoints: EndpointEntry[];
  complete: ModelCostRow[];
  partial: ModelCostRow[];
  // Endpoints with no output_image pricing line at all (e.g. the Krea
  // models, as of this writing) aren't free — OpenRouter just hasn't
  // published a price for them — so estimateCost() correctly returns null
  // rather than a $0 estimate. Tracked separately here so they're still
  // visible instead of silently vanishing from the output.
  missingPricing: { modelId: string; provider: string }[];
}

// Feature filtering (supportsBackground/supportsAspectRatio/
// supportsMinResolution in image-cost-estimate.ts) is deliberately not
// applied here — this is the unfiltered landscape view; see
// pick-image-model.ts for filtered automated selection.
export async function listModelCosts(requirements: ImageGenerationRequirements): Promise<ModelCostListing> {
  const models = await fetchModelList();
  const endpointLists = await Promise.all(models.map((model) => fetchEndpoints(model.id)));

  const rows: ModelCostRow[] = [];
  const missingPricing: { modelId: string; provider: string }[] = [];
  models.forEach((model, i) => {
    for (const endpoint of endpointLists[i]) {
      const estimate = estimateCost(endpoint, requirements);
      if (estimate) {
        rows.push({ modelId: model.id, provider: endpoint.provider_name, estimate });
      } else {
        missingPricing.push({ modelId: model.id, provider: endpoint.provider_name });
      }
    }
  });

  return {
    models,
    endpoints: endpointLists.flat(),
    complete: rows.filter((r) => !r.estimate.note).sort((a, b) => a.estimate.usd - b.estimate.usd),
    partial: rows.filter((r) => r.estimate.note),
    missingPricing,
  };
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
    throw new Error("Usage: list-image-models --assets-dir <path> <asset-id>  (e.g. building-arena)");
  }

  const resolvedAssetsDir = resolve(callerCwd(), assetsDir);
  const requirements = await readImageGenerationRequirements(resolvedAssetsDir, assetId);
  const promptTokens = estimateTokens(requirements.promptText);

  const { models, endpoints, complete, partial, missingPricing } = await listModelCosts(requirements);

  console.log(
    `Asset "${assetId}": aspectRatio=${requirements.aspectRatio ?? "(any)"}, minResolution=${requirements.minResolution} ` +
      `(~${tierMegapixels(requirements.minResolution).toFixed(2)}MP), background=${requirements.background}, ` +
      `prompt≈${promptTokens} tokens (estimated, ~4 chars/token).\n`,
  );
  console.log(
    `${complete.length + partial.length + missingPricing.length} model/provider endpoints across ${models.length} models (feature ` +
      `filtering — aspect ratio, background, resolution — is disabled for now, so this includes models that may ` +
      `not actually support this asset's spec).\n`,
  );

  printFeatureSupport(endpoints);

  console.log(`Fully estimated cost, cheapest first (${complete.length}):`);
  for (const r of complete) {
    console.log(`  $${r.estimate.usd.toFixed(4)}  ${r.modelId}  (${r.provider})`);
  }

  if (partial.length > 0) {
    console.log(`\nCost only partially computable (${partial.length}):`);
    for (const r of partial) {
      console.log(`  ~$${r.estimate.usd.toFixed(4)}+  ${r.modelId}  (${r.provider}) — ${r.estimate.note}`);
    }
  }

  if (missingPricing.length > 0) {
    console.log(`\nNo pricing data published at all — not free, just unpriced/unranked (${missingPricing.length}):`);
    for (const m of missingPricing) {
      console.log(`  ${m.modelId}  (${m.provider})`);
    }
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exitCode = 1;
  });
}
