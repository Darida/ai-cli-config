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
// PATCH_SIZE_PX = 33 is calibrated against two real observations (see
// image-cost-estimate.test.ts), not a documented billing formula — both
// against the same 1024x1024 "1K"-tier pixel budget this estimate always
// uses for minResolution="1K":
//   - google/gemini-3-pro-image-preview: real billed cost implies ~820
//     output-image tokens for one image → P = sqrt(1024²/820) ≈ 35.76
//   - google/gemini-3.1-flash-lite-image: real billed cost implies
//     exactly 1120 output-image tokens (this one really was generated at
//     1024x1024, no tier approximation involved) → P = sqrt(1024²/1120)
//     ≈ 30.60
// No single patch size fits both real rates exactly, so PATCH_SIZE_PX is
// their geometric mean, sqrt(35.76 * 30.60) ≈ 33.08, rounded to 33 — this
// keeps both calibration tests within their 30% tolerance (~17% and ~14%
// off respectively) instead of fitting one observation exactly and
// missing the other by ~2x, which is what the previous single-point
// calibration (44) did once a second observation existed to check it
// against. This is the one knob to retune, as more real generation runs
// give more data points to calibrate against.
const PATCH_SIZE_PX = 33;

function estimateOutputImageTokens(totalPixels: number): number {
  return Math.round(totalPixels / (PATCH_SIZE_PX * PATCH_SIZE_PX));
}

// OpenRouter's live API (/images/models/.../endpoints) reports input image
// pricing lines under billable names "input_image" or "input_reference", with
// three units:
//   - unit: "image" (flat cost per reference image, e.g. x-ai/grok-imagine-image-quality: $0.01/image,
//     sourceful/riverflow-v2-pro: $0.20/input_reference)
//   - unit: "megapixel" (per-megapixel cost, e.g. black-forest-labs/flux.2-flex: $0.06/megapixel)
//   - unit: "token" (per-token cost, e.g. google/gemini-3-pro-image-preview: $0.000002/token)
function estimateInputImageCost(model: Model, requirements: ImageGenerationRequirements): number {
  if (!requirements.mockImage) return 0;

  const imageLine = model.pricing.find(
    (p) => (p.billable === "input_image" || p.billable === "input_reference") && p.unit !== "token",
  );
  const tokenLine = model.pricing.find(
    (p) => (p.billable === "input_image" || p.billable === "input_reference") && p.unit === "token",
  );

  if (imageLine) {
    if (imageLine.unit === "image") {
      return imageLine.cost_usd;
    }
    if (imageLine.unit === "megapixel") {
      const mp =
        requirements.mockImageWidth && requirements.mockImageHeight
          ? (requirements.mockImageWidth * requirements.mockImageHeight) / 1_000_000
          : tierMegapixels(requirements.minResolution);
      return imageLine.cost_usd * mp;
    }
  }

  if (tokenLine) {
    const totalPixels =
      requirements.mockImageWidth && requirements.mockImageHeight
        ? requirements.mockImageWidth * requirements.mockImageHeight
        : TIER_EDGE_PX[requirements.minResolution] ** 2;
    const tokens = estimateOutputImageTokens(totalPixels);
    return tokenLine.cost_usd * tokens;
  }

  return 0;
}

// requirements must already be adjusted (asset-adjuster.ts's adjust())
// against this exact model — minResolution here is treated as the value
// that will actually be requested, not a floor to double-check.
export function estimateCost(model: Model, requirements: ImageGenerationRequirements): CostEstimate | null {
  const promptTokens = estimateTokens(requirements.promptText);
  const inputTextLine = model.pricing.find((p) => p.billable === "input_text" && p.unit === "token");
  const inputTextCost = inputTextLine ? inputTextLine.cost_usd * promptTokens : 0;

  const inputImageCost = estimateInputImageCost(model, requirements);
  const inputCost = inputTextCost + inputImageCost;

  const outputLine = model.pricing.find((p) => p.billable === "output_image");
  if (!outputLine) return null;

  if (outputLine.unit === "image") {
    const wanted = requirements.minResolution.toLowerCase();
    const variantLine = model.pricing.find((p) => p.billable === "output_image" && p.unit === "image" && p.variant?.toLowerCase() === wanted);
    return { usd: inputCost + (variantLine ?? outputLine).cost_usd };
  }

  if (outputLine.unit === "megapixel") {
    return { usd: inputCost + outputLine.cost_usd * tierMegapixels(requirements.minResolution) };
  }

  if (outputLine.unit === "token") {
    const totalPixels = TIER_EDGE_PX[requirements.minResolution] ** 2;
    const tokens = estimateOutputImageTokens(totalPixels);
    return { usd: inputCost + outputLine.cost_usd * tokens };
  }

  return { usd: inputCost, note: `unrecognized output billing unit "${outputLine.unit}" — output cost omitted` };
}
