import { describe, expect, it } from "vitest";
import { estimateCost } from "./image-cost-estimate";
import type { ImageGenerationRequirements } from "./image-generation-requirements";
import type { Model } from "./model/types";

// Calibration harness: each entry is one REAL generation we actually ran
// and recorded the true billed usage for — checks estimateCost() (the
// requirements → dollar-estimate pipeline used by every tool in this
// package, including resolution-floor handling) against reality, not just
// against itself. Add more entries here as more real generations get
// recorded. If one starts failing (or a new one fails from the start), the
// fix is tuning image-cost-estimate.ts's PATCH_SIZE_PX, not this file.
const COST_TOLERANCE = 0.3; // fail if our estimate is off by more than 30%

// Raw usage object exactly as OpenRouter reported it for one real request —
// kept verbatim, field names included, so nothing here is transcribed by
// hand into a different shape. Never read by the assertion itself (see
// expectedEstimatedCost below); this is documentation, and the source data
// for expectedEstimatedCost's derivation, in case that derivation turns out
// to be wrong and needs redoing later.
interface OpenRouterUsage {
  tokens_prompt: number;
  tokens_completion: number;
  native_tokens_prompt: number;
  native_tokens_completion: number;
  native_tokens_completion_images: number;
  native_tokens_reasoning: number | null;
  native_tokens_cached: number | null;
  num_media_prompt: number | null;
  num_input_audio_prompt: number | null;
  num_media_completion: number;
}

interface RealObservation {
  // The exact entity estimateCost() is called with — same shape every
  // library in this package accepts directly (no folder/file parsing
  // involved here).
  requirements: ImageGenerationRequirements;
  model: Model;

  // --- Documentation only, from here down. Never read by the assertion. ---
  apiUsage: OpenRouterUsage;
  realTotalCostUsd: number; // the actual dollar amount billed for the whole request, as reported

  // Manually computed once, NOT derived at test-run time — see each
  // entry's own comment for the exact arithmetic. Isolates the portion of
  // realTotalCostUsd attributable to a single image's output tokens only,
  // with duplicate-image and reasoning-token cost removed (neither of
  // those is something estimateCost() is meant to predict). This is the
  // only field the assertion actually reads.
  expectedEstimatedCost: number;
}

const GEMINI_3_PRO_IMAGE_PREVIEW_AI_STUDIO: Model = {
  modelId: "google/gemini-3-pro-image-preview",
  provider: "Google AI Studio",
  supported_parameters: {},
  pricing: [
    { billable: "input_image", unit: "token", cost_usd: 0.000002 },
    { billable: "output_image", unit: "token", cost_usd: 0.00006 },
  ],
};

const GEMINI_3_1_FLASH_LITE_IMAGE_AI_STUDIO: Model = {
  modelId: "google/gemini-3.1-flash-lite-image",
  provider: "Google AI Studio",
  supported_parameters: {},
  pricing: [{ billable: "output_image", unit: "token", cost_usd: 0.00003 }],
};

// Real declared endpoint data (OpenRouter's /images/models/.../endpoints,
// fetched 2026-07-29) — priced per-image, but with two separate
// output_image lines, one per resolution `variant` ($0.05 at "1k", $0.07
// at "2k"), not one flat price. This is the calibration case for
// asset-adjuster.ts's hasSingleFlatImagePrice()/pickResolutionTier()
// distinction: several output_image/unit:"image" lines means resolution
// really does change cost, so pickResolutionTier keeps the
// cheapest-that-clears-the-floor choice for this model rather than
// maxing out.
const GROK_IMAGINE_IMAGE_QUALITY_XAI: Model = {
  modelId: "x-ai/grok-imagine-image-quality",
  provider: "xAI",
  supported_parameters: {
    resolution: { type: "enum", values: ["1K", "2K"] },
    aspect_ratio: {
      type: "enum",
      values: ["1:1", "3:4", "4:3", "9:16", "16:9", "2:3", "3:2", "9:19.5", "19.5:9", "9:20", "20:9", "1:2", "2:1", "auto"],
    },
    n: { type: "range", min: 1, max: 1 },
    input_references: { type: "range", min: 0, max: 3 },
  },
  pricing: [
    { billable: "input_image", unit: "image", cost_usd: 0.01 },
    { billable: "output_image", unit: "image", cost_usd: 0.05, variant: "1k" },
    { billable: "output_image", unit: "image", cost_usd: 0.07, variant: "2k" },
  ],
};

const observations: RealObservation[] = [
  // ui-scene-frame via google/gemini-3-pro-image-preview (Google AI Studio), old malformed
  // chat-completions request — no aspect_ratio/resolution/background actually sent, model
  // defaulted to its own 1408x768 output. minResolution below isn't literally what was
  // requested (nothing was) — it's the "1K" tier whose 1024x1024 (~1.05MP) budget is the
  // closest match to the 1408x768 (~1.08MP) actually produced, under this codebase's own
  // square-edge total-pixel-budget convention (see TIER_EDGE_PX in image-cost-estimate.ts).
  {
    requirements: {
      destination: "ui-scene-frame.png",
      minResolution: "1K",
      background: "transparent",
      // Actual sent content: the base prompt (603 chars) plus the injected
      // chroma-key magenta-background clause (262 chars) — 865 chars
      // total. Content itself doesn't matter to estimateTokens, only
      // length, so a synthetic string of the same length stands in.
      promptText: "A".repeat(865),
    },
    model: GEMINI_3_PRO_IMAGE_PREVIEW_AI_STUDIO,
    apiUsage: {
      tokens_prompt: 220,
      tokens_completion: 337,
      native_tokens_prompt: 177,
      native_tokens_completion: 1548,
      native_tokens_completion_images: 1120,
      native_tokens_reasoning: 258,
      native_tokens_cached: 0,
      num_media_prompt: null,
      num_input_audio_prompt: null,
      num_media_completion: 2,
    },
    realTotalCostUsd: 0.136,
    // Derivation: native_tokens_completion (1548) = native_tokens_completion_images
    // (1120, split across num_media_completion=2 images → 560/image) +
    // native_tokens_reasoning (258) + 170 leftover text tokens (1548 - 1120
    // - 258 = 170 exactly). Everything in native_tokens_completion is
    // billed at the same real total realTotalCostUsd, so the effective
    // $/token rate for THIS request is realTotalCostUsd / native_tokens_completion
    // = 0.136 / 1548. Applying that same rate to one image's own 560
    // tokens (not the whole request's 1548) isolates the cost attributable
    // to a single image's output tokens only:
    //   0.136 * (560 / 1548) = 0.0492 (rounded to 4dp)
    expectedEstimatedCost: 0.0492,
  },
  // building-arena via google/gemini-3.1-flash-lite-image (Google AI Studio), real
  // generate-asset.ts run through the current OpenRouter Images API path —
  // resolution:"1K" requested (no aspect_ratio sent, spec has none), chroma-key cleanup
  // applied.
  {
    requirements: {
      destination: "building-arena.png",
      minResolution: "1K",
      background: "transparent",
      // Real base prompt (building-arena.prompt.txt, 323 chars) plus the
      // chroma-key clause (262 chars) — 585 chars total.
      promptText: "A".repeat(585),
    },
    model: GEMINI_3_1_FLASH_LITE_IMAGE_AI_STUDIO,
    apiUsage: {
      tokens_prompt: 116,
      tokens_completion: 1120,
      native_tokens_prompt: 116,
      native_tokens_completion: 1120,
      native_tokens_completion_images: 1120,
      native_tokens_reasoning: null,
      native_tokens_cached: null,
      num_media_prompt: 0,
      num_input_audio_prompt: null,
      num_media_completion: 1,
    },
    realTotalCostUsd: 0.0336,
    // Derivation: native_tokens_completion_images (1120) already equals
    // the whole of native_tokens_completion (1120) — no reasoning tokens
    // (null) and only one image (num_media_completion=1), so there's
    // nothing to dedupe or subtract. expectedEstimatedCost is
    // realTotalCostUsd unchanged.
    expectedEstimatedCost: 0.0336,
  },
  // village-background via x-ai/grok-imagine-image-quality (xAI), real
  // generate-asset.ts run through the current OpenRouter Images API path
  // — aspectRatio:"4:3", resolution:"2K" requested, background:"opaque"
  // (no chroma-key/transparency clause involved, so promptText is just
  // the base prompt, unmodified).
  {
    requirements: {
      destination: "village-background.png",
      aspectRatio: "4:3",
      minResolution: "2K",
      background: "opaque",
      // Real base prompt (village-background.prompt.txt, 1062 chars
      // after readImageGenerationRequirements' .trim()).
      promptText: "A".repeat(1062),
    },
    model: GROK_IMAGINE_IMAGE_QUALITY_XAI,
    apiUsage: {
      tokens_prompt: 266,
      tokens_completion: 4175,
      native_tokens_prompt: 266,
      native_tokens_completion: 4175,
      native_tokens_completion_images: 4175,
      native_tokens_reasoning: null,
      native_tokens_cached: null,
      num_media_prompt: 0,
      num_input_audio_prompt: null,
      num_media_completion: 1,
    },
    realTotalCostUsd: 0.07,
    // This model has no input_text/token pricing line at all and bills
    // output_image flatly per resolution variant — the $0.07 "2k"
    // variant line applies directly, no token-based derivation needed
    // (unlike the two Gemini entries above).
    expectedEstimatedCost: 0.07,
  },
];

describe("image cost estimate calibration", () => {
  observations.forEach((obs, i) => {
    it(`test_case_${i + 1}`, () => {
      const estimate = estimateCost(obs.model, obs.requirements);
      expect(estimate, "estimateCost() returned null (no output_image pricing line found on the test model)").not.toBeNull();

      const estimatedUsd = estimate!.usd;
      const error = Math.abs(estimatedUsd - obs.expectedEstimatedCost) / obs.expectedEstimatedCost;
      expect(
        error,
        `estimated $${estimatedUsd.toFixed(4)} vs expected $${obs.expectedEstimatedCost.toFixed(4)} (${(error * 100).toFixed(1)}% off)`,
      ).toBeLessThanOrEqual(COST_TOLERANCE);
    });
  });
});
