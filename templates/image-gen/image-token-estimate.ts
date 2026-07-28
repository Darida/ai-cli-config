// Isolated on purpose (only list-image-models.ts / image-cost-estimate.ts
// call this). OpenRouter's Images API exposes a real live $/token rate for
// every "output_image"/"token"-billed endpoint, but never the actual
// tokens-per-image a given provider bills — that conversion isn't
// documented per-provider here, so this applies one general,
// provider-agnostic estimate instead of per-vendor guesses: standard
// Vision Transformer patch tokenization, N = (H x W) / P^2.
//
// PATCH_SIZE_PX = 44 is calibrated against exactly one real observation
// (see image-cost-estimate.test.ts), not a documented billing
// formula: a real generate-asset.ts run against google/gemini-3-pro-
// image-preview produced a 1408x768 image billed at 560 output-image
// tokens (isolated from that request's usage breakdown — the raw
// response also included 258 reasoning/thinking tokens and a second
// generated image, both excluded here since they're not part of what
// this formula is meant to estimate). 1408*768/560 = ~43.9, rounded to a
// clean 44. The original guess of 16px (ViT-Base's typical *input*-image
// patch size) overestimated output-generation tokens by ~2.7x against
// that same data point — output-image token accounting isn't the same
// thing as input-image vision tokenization, even within one provider.
// This is the one knob to retune here, and only here, as more real
// generation runs give us more data points to calibrate against.
export const PATCH_SIZE_PX = 44;

export function estimateOutputImageTokens(totalPixels: number): number {
  return Math.round(totalPixels / (PATCH_SIZE_PX * PATCH_SIZE_PX));
}
