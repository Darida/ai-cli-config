import { fileURLToPath } from "node:url";
import { adjust } from "./asset-adjuster";
import { fetchModels } from "./clients/open-router";
import { type CostEstimate, estimateCost, estimateTokens, tierMegapixels } from "./image-cost-estimate";
import { type ImageGenerationRequirements, readImageGenerationRequirements } from "./image-generation-requirements";
import type { Model, ParamSpec } from "./model/types";

// Discovery tool — estimates a real dollar cost per candidate model/
// provider endpoint for one specific asset's actual spec + prompt, so a
// model can be picked deliberately instead of guessed. Run via
// `./list-image-models --assets-dir <path> <asset-id>` (e.g.
// building-arena). Also the shared core pick-image-model.ts's
// selectImageModel() builds on: listModels() below already does the
// fetch/adjust/cost work, selection just adds the percentile-cutoff +
// random pick on top.

export interface ModelCostRow {
  model: Model;
  adjusted: ImageGenerationRequirements;
  estimate: CostEstimate;
}

export interface ModelCostListing {
  totalCandidates: number;
  excludedUnsupported: number;
  complete: ModelCostRow[];
  partial: ModelCostRow[];
  // Endpoints with no output_image pricing line at all (e.g. the Krea
  // models, as of this writing) aren't free — OpenRouter just hasn't
  // published a price for them — so estimateCost() correctly returns null
  // rather than a $0 estimate. Tracked separately here so they're still
  // visible instead of silently vanishing from the output.
  missingPricing: Model[];
}

export async function listModels(requirements: ImageGenerationRequirements): Promise<ModelCostListing> {
  const candidates = await fetchModels();

  const rows: ModelCostRow[] = [];
  const missingPricing: Model[] = [];
  let excludedUnsupported = 0;

  for (const model of candidates) {
    const adjusted = adjust(requirements, model);
    if (!adjusted) {
      excludedUnsupported++;
      continue;
    }
    const estimate = estimateCost(model, adjusted);
    if (estimate) {
      rows.push({ model, adjusted, estimate });
    } else {
      missingPricing.push(model);
    }
  }

  return {
    totalCandidates: candidates.length,
    excludedUnsupported,
    complete: rows.filter((r) => !r.estimate.note).sort((a, b) => a.estimate.usd - b.estimate.usd),
    partial: rows.filter((r) => r.estimate.note),
    missingPricing,
  };
}

// Prints how many of the given models declare support for each
// parameter/value — a landscape overview to inform filtering criteria,
// across the unfiltered candidate set (before adjust() excludes any).
function printFeatureSupport(models: Model[]): void {
  const enumTally = new Map<string, Map<string, number>>(); // paramName -> value -> model count
  const otherTally = new Map<string, { count: number; sample: ParamSpec }>(); // paramName -> models declaring it (range/boolean params)

  for (const model of models) {
    for (const [paramName, paramSpec] of Object.entries(model.supported_parameters ?? {})) {
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

  console.log(`Feature support across ${models.length} model/provider endpoints:\n`);
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
    throw new Error("Usage: list-image-models --assets-dir <absolute-path> <asset-id>  (e.g. building-arena)");
  }

  const requirements = await readImageGenerationRequirements(assetsDir, assetId);
  const promptTokens = estimateTokens(requirements.promptText);

  const { totalCandidates, excludedUnsupported, complete, partial, missingPricing } = await listModels(requirements);

  console.log(
    `Asset "${assetId}": aspectRatio=${requirements.aspectRatio ?? "(any)"}, minResolution=${requirements.minResolution} ` +
      `(~${tierMegapixels(requirements.minResolution).toFixed(2)}MP), background=${requirements.background}, ` +
      `prompt≈${promptTokens} tokens (estimated, ~4 chars/token).\n`,
  );
  console.log(
    `${totalCandidates} model/provider endpoints considered, ${excludedUnsupported} excluded as unsupported ` +
      `(aspect ratio or resolution floor), ${complete.length + partial.length + missingPricing.length} remain.\n`,
  );

  printFeatureSupport([...complete, ...partial].map((r) => r.model).concat(missingPricing));

  console.log(`Fully estimated cost, cheapest first (${complete.length}):`);
  for (const r of complete) {
    console.log(`  $${r.estimate.usd.toFixed(4)}  ${r.model.modelId}  (${r.model.provider})`);
  }

  if (partial.length > 0) {
    console.log(`\nCost only partially computable (${partial.length}):`);
    for (const r of partial) {
      console.log(`  ~$${r.estimate.usd.toFixed(4)}+  ${r.model.modelId}  (${r.model.provider}) — ${r.estimate.note}`);
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
