import { describe, expect, it } from "vitest";
import { estimateOutputImageTokens } from "./image-token-estimate";
import { type EndpointEntry, estimateTokens } from "./image-cost-estimate";

// Calibration harness: each entry is one REAL generation we actually ran
// and recorded the true billed cost for — checks the token-estimate
// formula against reality, not just against itself. Add more entries here
// as more real generations get recorded. If one starts failing (or a new
// one fails from the start), the fix is tuning image-token-estimate.ts's
// PATCH_SIZE_PX, not this file.
//
// Deliberately computed via estimateTokens/estimateOutputImageTokens
// directly, not the higher-level estimateCost(endpoint, AssetSpec, ...) —
// AssetSpec's resolution tiers (0.5K/1K/2K/4K) describe requests made
// through generate-asset.ts's *current*, fixed OpenRouter Images API path
// (real aspect_ratio/resolution/background params). This first
// observation predates that fix: it went through the old, malformed
// chat-completions path (no size/background params sent at all), so the
// model picked its own output size — raw pixel dimensions, not a tier.
const COST_TOLERANCE = 0.3; // fail if our estimate is off by more than 30%

interface RealObservation {
  description: string;
  promptLength: number; // char length of the exact text actually sent — content itself doesn't matter to estimateTokens, only length, so this isn't the literal prompt
  outputWidthPx: number;
  outputHeightPx: number;
  endpoint: EndpointEntry; // pricing snapshot as OpenRouter reported it when this observation was recorded
  realInputTokens: number; // as reported by the actual generation — informational; estimateTokens derives its own estimate from prompt length instead of trusting this number
  realOutputImageTokens: number; // isolated image-only tokens for ONE image — see the derivation note below; estimateOutputImageTokens is compared against this
  realCostUsd: number; // = realOutputImageTokens * the endpoint's real output rate — see derivation note
}

// $0.00006/token, not the $0.0012/token OpenRouter's public /images/models
// listing showed at the time — not independently re-verified against the
// corrected realCostUsd below (that $0.136 total covers 1548 output tokens:
// 1120 image + 258 reasoning + ~170 text, not just the 560 image tokens for
// one image), so treat this rate as approximate until confirmed.
const GEMINI_3_PRO_IMAGE_PREVIEW_AI_STUDIO: EndpointEntry = {
  provider_name: "Google AI Studio",
  supported_parameters: {},
  pricing: [
    { billable: "input_image", unit: "token", cost_usd: 0.000002 },
    { billable: "output_image", unit: "token", cost_usd: 0.00006 },
  ],
};

// Real per-request usage breakdown: native_tokens_prompt 116,
// native_tokens_completion 1120 = native_tokens_completion_images 1120
// (num_media_completion: 1 — a single image, so unlike the observation
// above, no reasoning-token or multi-image split to untangle; all 1120
// completion tokens are image tokens). Real cost $0.0336, so real rate =
// 0.0336 / 1120 = $0.00003/token exactly — half GEMINI_3_PRO_IMAGE_PREVIEW
// _AI_STUDIO's $0.00006/token, consistent with "flash-lite" being the
// cheaper tier of the two models.
const GEMINI_3_1_FLASH_LITE_IMAGE_AI_STUDIO: EndpointEntry = {
  provider_name: "Google AI Studio",
  supported_parameters: {},
  pricing: [{ billable: "output_image", unit: "token", cost_usd: 0.00003 }],
};

const observations: RealObservation[] = [
  {
    description:
      "ui-scene-frame via google/gemini-3-pro-image-preview (Google AI Studio), old malformed chat-completions " +
      "request — no aspect_ratio/resolution/background sent, model defaulted to its own 1408x768 output",
    // Actual sent content: the base prompt (603 chars) plus the injected
    // chroma-key magenta-background clause (262 chars) generate-asset.ts
    // appends for transparent-background assets — 865 chars total.
    promptLength: 865,
    outputWidthPx: 1408,
    outputHeightPx: 768,
    endpoint: GEMINI_3_PRO_IMAGE_PREVIEW_AI_STUDIO,
    realInputTokens: 177,
    // The raw usage breakdown for this request was: native_tokens_prompt
    // 177, native_tokens_completion 1548 = native_tokens_completion_images
    // 1120 (num_media_completion: 2, i.e. two images, so 560/image) +
    // native_tokens_reasoning 258 (thinking tokens, billed at the same
    // output rate but unrelated to image size) + ~170 text tokens. Only
    // the per-image 560 is what estimateOutputImageTokens is meant to
    // predict — reasoning/text overhead isn't resolution-dependent and
    // isn't modeled by this formula at all.
    realOutputImageTokens: 560,
    // Real billed cost for the whole request was $0.136 (it accidentally
    // produced 2 images) — this is that amount split evenly per image.
    realCostUsd: 0.068,
  },
  {
    description:
      "building-arena via google/gemini-3.1-flash-lite-image (Google AI Studio), real generate-asset.ts run " +
      "through the current OpenRouter Images API path — resolution:\"1K\" requested (no aspect_ratio sent, " +
      "spec has none), chroma-key cleanup applied. Real output file was deleted before its pixel dimensions " +
      "could be measured, so outputWidthPx/outputHeightPx below use this model's own OpenRouter listing, " +
      "which documents \"Outputs are generated at 1K resolution across 14 aspect ratios\" — 1024x1024, same " +
      "square-edge tier convention as the rest of this codebase.",
    // Real base prompt (building-arena.prompt.txt, 323 chars) plus the
    // chroma-key clause (262 chars) — 585 chars total.
    promptLength: 585,
    outputWidthPx: 1024,
    outputHeightPx: 1024,
    endpoint: GEMINI_3_1_FLASH_LITE_IMAGE_AI_STUDIO,
    realInputTokens: 116,
    realOutputImageTokens: 1120,
    realCostUsd: 0.0336, // real billed cost for this request, as reported
  },
];

describe("image cost estimate calibration", () => {
  for (const obs of observations) {
    it(`${obs.description}: estimate is within ${COST_TOLERANCE * 100}% of the real $${obs.realCostUsd.toFixed(4)}`, () => {
      const syntheticPrompt = "A".repeat(obs.promptLength);
      const promptTokens = estimateTokens(syntheticPrompt);
      const outputTokens = estimateOutputImageTokens(obs.outputWidthPx * obs.outputHeightPx);

      const inputLine = obs.endpoint.pricing.find((p) => p.billable === "input_text" && p.unit === "token");
      const outputLine = obs.endpoint.pricing.find((p) => p.billable === "output_image" && p.unit === "token");
      const estimatedUsd = (inputLine ? inputLine.cost_usd * promptTokens : 0) + (outputLine ? outputLine.cost_usd * outputTokens : 0);

      const error = Math.abs(estimatedUsd - obs.realCostUsd) / obs.realCostUsd;
      expect(
        error,
        `estimated $${estimatedUsd.toFixed(4)} (${promptTokens} input tokens est., ${outputTokens} output tokens est.) ` +
          `vs real $${obs.realCostUsd.toFixed(4)} (${(error * 100).toFixed(1)}% off, real usage was ${obs.realInputTokens} ` +
          `input / ${obs.realOutputImageTokens} output-image tokens)`,
      ).toBeLessThanOrEqual(COST_TOLERANCE);
    });
  }
});
