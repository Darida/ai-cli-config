import type { AssetSpec, ImageGenerationRequirements } from "./image-generation-requirements";
import { estimateOutputImageTokens } from "./image-token-estimate";

// Isolated, side-effect-free (no network/fs) on purpose — this is what
// list-image-models.ts's CLI calls, and what image-cost-estimate.test.ts
// (in this folder) checks against real recorded generations, without
// either of them needing to duplicate the estimation logic itself.
export type { AssetSpec };

export interface ParamSpec {
  type: string;
  values?: string[];
  min?: number;
  max?: number;
}

export interface PricingLine {
  billable: string;
  unit: string;
  cost_usd: number;
  variant?: string;
}

export interface EndpointEntry {
  provider_name: string;
  supported_parameters?: Record<string, ParamSpec>;
  pricing: PricingLine[];
}

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
export const TIER_EDGE_PX: Record<AssetSpec["minResolution"], number> = {
  "0.5K": 512,
  "1K": 1024,
  "2K": 2048,
  "4K": 4096,
};

export function tierMegapixels(resolution: AssetSpec["minResolution"]): number {
  const edge = TIER_EDGE_PX[resolution];
  return (edge * edge) / 1_000_000;
}

export function supportsBackground(params: Record<string, ParamSpec> | undefined, background: AssetSpec["background"]): boolean {
  if (background === "opaque") return true; // every model renders an opaque background by default
  return params?.background?.values?.includes("transparent") ?? false;
}

export function supportsAspectRatio(params: Record<string, ParamSpec> | undefined, aspectRatio: AssetSpec["aspectRatio"]): boolean {
  if (!aspectRatio) return true; // asset has no aspect ratio requirement — every model qualifies
  return params?.aspect_ratio?.values?.includes(aspectRatio) ?? false;
}

// Model resolution enums mix API shapes ("512" from OpenRouter/Gemini vs
// our own "0.5K") — rank both onto one scale so they compare directly.
const RESOLUTION_RANK: Record<string, number> = { "512": 0, "0.5K": 0, "1K": 1, "2K": 2, "4K": 3 };

// minResolution is a *floor*, not an exact request (more is always fine) —
// so a model qualifies if the highest tier it declares is at least that
// floor. A model with no declared `resolution` parameter at all is
// assumed to output around its own native ~512px by default (unknown, but
// conservatively small) — it only qualifies for assets that only need
// that much, never anything asking for more.
export function supportsMinResolution(params: Record<string, ParamSpec> | undefined, minResolution: AssetSpec["minResolution"]): boolean {
  const declaredValues = params?.resolution?.values;
  if (!declaredValues || declaredValues.length === 0) {
    return RESOLUTION_RANK[minResolution] <= RESOLUTION_RANK["512"];
  }
  const maxDeclaredRank = Math.max(...declaredValues.map((v) => RESOLUTION_RANK[v] ?? -1));
  return maxDeclaredRank >= RESOLUTION_RANK[minResolution];
}

// A model that passes supportsMinResolution() is only guaranteed to have
// *some* declared value at or above the floor — not that the specific
// value a caller might otherwise hardcode (e.g. our own "0.5K"/"512" API
// shape) is actually one of its declared values. Callers building a real
// request must pick a resolution value from the model's own enum, not
// assume it accepts ours verbatim. Returns the cheapest (lowest-ranked)
// declared value that still meets the floor, or undefined when the model
// declares no `resolution` parameter at all (nothing to pick — omit the
// field from the request rather than sending an unsupported one).
export function pickResolutionValue(params: Record<string, ParamSpec> | undefined, minResolution: AssetSpec["minResolution"]): string | undefined {
  const declaredValues = params?.resolution?.values;
  if (!declaredValues || declaredValues.length === 0) return undefined;
  const floorRank = RESOLUTION_RANK[minResolution];
  const qualifying = declaredValues.filter((v) => (RESOLUTION_RANK[v] ?? -1) >= floorRank);
  qualifying.sort((a, b) => RESOLUTION_RANK[a] - RESOLUTION_RANK[b]);
  return qualifying[0];
}

export function estimateCost(endpoint: EndpointEntry, requirements: ImageGenerationRequirements): CostEstimate | null {
  const promptTokens = estimateTokens(requirements.promptText);
  const inputTextLine = endpoint.pricing.find((p) => p.billable === "input_text" && p.unit === "token");
  const inputTextCost = inputTextLine ? inputTextLine.cost_usd * promptTokens : 0;

  // input_image/input_reference/input_font pricing lines exist for
  // reference-image inputs — generate-asset.ts never sends those, so they
  // never apply here.
  const outputLine = endpoint.pricing.find((p) => p.billable === "output_image");
  if (!outputLine) return null;

  if (outputLine.unit === "image") {
    const wanted = requirements.minResolution.toLowerCase();
    const variantLine = endpoint.pricing.find(
      (p) => p.billable === "output_image" && p.unit === "image" && p.variant?.toLowerCase() === wanted,
    );
    return { usd: inputTextCost + (variantLine ?? outputLine).cost_usd };
  }

  if (outputLine.unit === "megapixel") {
    // Always our own spec's resolution, regardless of whether the model
    // declares a matching `resolution` parameter — we're estimating what
    // we'd request, not gating on what the model claims to support (that's
    // feature filtering's job, deliberately disabled elsewhere right now).
    return { usd: inputTextCost + outputLine.cost_usd * tierMegapixels(requirements.minResolution) };
  }

  if (outputLine.unit === "token") {
    // No per-provider tokens-per-image table (none is exposed by this API,
    // and we deliberately don't hardcode vendor docs that would go stale)
    // — see image-token-estimate.ts for the one general formula applied
    // uniformly here, regardless of which provider this endpoint is.
    const totalPixels = TIER_EDGE_PX[requirements.minResolution] ** 2;
    const tokens = estimateOutputImageTokens(totalPixels);
    return { usd: inputTextCost + outputLine.cost_usd * tokens };
  }

  return { usd: inputTextCost, note: `unrecognized output billing unit "${outputLine.unit}" — output cost omitted` };
}
