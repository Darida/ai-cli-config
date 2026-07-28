import type { ImageGenerationRequirements } from "./image-generation-requirements";
import type { Model } from "./model/types";

// Isolated, side-effect-free (no network/fs) on purpose — this is what
// list-image-models.ts's CLI calls, and what image-cost-estimate.test.ts
// (in this folder) checks against real recorded generations, without
// either of them needing to duplicate the estimation logic itself.

export interface CostEstimate {
  usd: number;
  // Set when part of the cost couldn't be computed from available data —
  // callers should treat these as excluded from a "fully estimated" list,
  // since sorting a partial number next to a complete one would mislead.
  note?: string;
}

// Rough industry-standard approximation (~4 chars/token for English text).
// This project has no tokenizer dependency, and this whole module is
// explicitly an *estimate*, not a billing-accurate calculation.
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

// "0.5K"/"1K"/"2K"/"4K" name a total-pixel-count budget, the same way
// Gemini's own docs name their tiers ("512px (0.5K)") — i.e. the tier is
// the edge length of the *square* baseline, and an aspect-ratio-preserving
// crop/resize to a non-square shape keeps that same total pixel count. So
// megapixels = tier^2, independent of the asset's actual aspect ratio.
const TIER_EDGE_PX: Record<ImageGenerationRequirements["minResolution"], number> = {
  "0.5K": 512,
  "1K": 1024,
  "2K": 2048,
  "4K": 4096,
};

export function tierMegapixels(resolution: ImageGenerationRequirements["minResolution"]): number {
  const edge = TIER_EDGE_PX[resolution];
  return (edge * edge) / 1_000_000;
}

// No per-provider tokens-per-image table is exposed by OpenRouter's API
// (and hardcoding vendor docs would go stale), so output-image tokens are
// estimated with one general formula instead: standard Vision Transformer
// patch tokenization, N = (H×W)/P².
//
// PATCH_SIZE_PX = 44 is calibrated against exactly one real observation
// (see image-cost-estimate.test.ts), not a documented billing formula: a
// real generate-asset.ts run against google/gemini-3-pro-image-preview
// produced a 1408x768 image billed at 560 output-image tokens (isolated
// from that request's usage breakdown — the raw response also included
// 258 reasoning/thinking tokens and a second generated image, both
// excluded here since they're not part of what this formula estimates).
// 1408*768/560 = ~43.9, rounded to a clean 44. The original guess of 16px
// (ViT-Base's typical *input*-image patch size) overestimated
// output-generation tokens by ~2.7x against that same data point —
// output-image token accounting isn't the same thing as input-image
// vision tokenization, even within one provider. This is the one knob to
// retune, as more real generation runs give more data points to
// calibrate against.
const PATCH_SIZE_PX = 44;

function estimateOutputImageTokens(totalPixels: number): number {
  return Math.round(totalPixels / (PATCH_SIZE_PX * PATCH_SIZE_PX));
}

// requirements must already be adjusted (asset-adjuster.ts's adjust())
// against this exact model — minResolution here is treated as the value
// that will actually be requested, not a floor to double-check.
export function estimateCost(model: Model, requirements: ImageGenerationRequirements): CostEstimate | null {
  const promptTokens = estimateTokens(requirements.promptText);
  const inputTextLine = model.pricing.find((p) => p.billable === "input_text" && p.unit === "token");
  const inputTextCost = inputTextLine ? inputTextLine.cost_usd * promptTokens : 0;

  // input_image/input_reference/input_font pricing lines exist for
  // reference-image inputs — generate-asset.ts never sends those, so they
  // never apply here.
  const outputLine = model.pricing.find((p) => p.billable === "output_image");
  if (!outputLine) return null;

  if (outputLine.unit === "image") {
    const wanted = requirements.minResolution.toLowerCase();
    const variantLine = model.pricing.find((p) => p.billable === "output_image" && p.unit === "image" && p.variant?.toLowerCase() === wanted);
    return { usd: inputTextCost + (variantLine ?? outputLine).cost_usd };
  }

  if (outputLine.unit === "megapixel") {
    return { usd: inputTextCost + outputLine.cost_usd * tierMegapixels(requirements.minResolution) };
  }

  if (outputLine.unit === "token") {
    const totalPixels = TIER_EDGE_PX[requirements.minResolution] ** 2;
    const tokens = estimateOutputImageTokens(totalPixels);
    return { usd: inputTextCost + outputLine.cost_usd * tokens };
  }

  return { usd: inputTextCost, note: `unrecognized output billing unit "${outputLine.unit}" — output cost omitted` };
}
