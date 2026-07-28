import type { ImageGenerationRequirements } from "./image-generation-requirements";
import type { Model } from "./model/types";

// Asking a model for a flat magenta background to key out in post
// (clean-image.ts) when it can't natively render transparency. Magenta
// (#FF00FF) is a color no real asset's palette should ever legitimately
// contain, so it's safe to key out without clipping real content.
const CHROMA_KEY_BACKGROUND_CLAUSE =
  ", the entire area meant to end up transparent — including the background behind the subject and any fully enclosed hollow regions within it — rendered as flat solid magenta (#FF00FF) with no gradient or texture; magenta must not appear anywhere else in the image";

// Dual-shape on purpose: OpenRouter/Gemini's declared resolution enums
// have been observed spelling the smallest tier "512" (bare pixel number)
// rather than "0.5K" — the other three tiers pass through identically to
// our own names. "0.5K" is kept here defensively even though it's never
// actually appeared in real data.
const RESOLUTION_RANK: Record<string, number> = { "512": 0, "0.5K": 0, "1K": 1, "2K": 2, "4K": 3 };
const RESOLUTION_TIERS = ["0.5K", "1K", "2K", "4K"] as const;

// These are exported for independent unit testing only — every real
// caller in this package goes through adjust() below, never these
// directly.

export function supportsBackground(model: Model, background: ImageGenerationRequirements["background"]): boolean {
  if (background === "opaque") return true; // every model renders an opaque background by default
  return model.supported_parameters?.background?.values?.includes("transparent") ?? false;
}

export function supportsAspectRatio(model: Model, aspectRatio: ImageGenerationRequirements["aspectRatio"]): boolean {
  if (!aspectRatio) return true; // no requirement — every model qualifies
  return model.supported_parameters?.aspect_ratio?.values?.includes(aspectRatio) ?? false;
}

// The cheapest of our own tier names that's still at/above minResolution
// and that this model actually declares support for — or undefined if
// nothing qualifies. A model with no declared resolution parameter at all
// is assumed to output around its own native ~512px by default, so it
// only qualifies for 0.5K floors.
export function pickResolutionTier(
  model: Model,
  minResolution: ImageGenerationRequirements["minResolution"],
): ImageGenerationRequirements["minResolution"] | undefined {
  const declared = model.supported_parameters?.resolution?.values;
  const floorRank = RESOLUTION_RANK[minResolution];
  if (!declared || declared.length === 0) {
    return floorRank <= RESOLUTION_RANK["512"] ? minResolution : undefined;
  }
  const qualifyingRanks = declared.map((v) => RESOLUTION_RANK[v]).filter((r): r is number => r !== undefined && r >= floorRank);
  return qualifyingRanks.length === 0 ? undefined : RESOLUTION_TIERS[Math.min(...qualifyingRanks)];
}

// Whether `model` can serve `spec` at all and, if so, a spec adjusted to
// what it actually supports: minResolution substituted for the cheapest
// qualifying tier, and — when the model can't natively render
// transparency — background switched to "opaque" with the chroma-key
// clause appended to promptText (clean-image.ts does the pixel-side half
// of that workaround after generation). Returns null when nothing here
// makes this model usable for this spec: unsupported aspect ratio, or no
// resolution tier meets the floor.
export function adjust(spec: ImageGenerationRequirements, model: Model): ImageGenerationRequirements | null {
  if (!supportsAspectRatio(model, spec.aspectRatio)) return null;

  const minResolution = pickResolutionTier(model, spec.minResolution);
  if (!minResolution) return null;

  const needsChromaKey = spec.background === "transparent" && !supportsBackground(model, "transparent");
  return {
    ...spec,
    minResolution,
    background: needsChromaKey ? "opaque" : spec.background,
    promptText: needsChromaKey ? spec.promptText + CHROMA_KEY_BACKGROUND_CLAUSE : spec.promptText,
  };
}

// Compares an adjust() input/output pair to tell whether a fallback
// workaround was applied — currently only the chroma-key path (background
// downgraded from "transparent"), but the diff-based approach generalizes
// to any future field adjust() might override rather than needing a
// bespoke flag per workaround.
export function shouldCleanupImage(original: ImageGenerationRequirements, adjusted: ImageGenerationRequirements): boolean {
  return original.background === "transparent" && adjusted.background !== "transparent";
}
