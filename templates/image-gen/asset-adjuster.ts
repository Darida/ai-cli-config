import type { ImageGenerationRequirements } from "./image-generation-requirements";
import type { Model } from "./model/types";

// Asking a model for a flat magenta background to key out in post
// (clean-image.ts) when it can't natively render transparency. Magenta
// (#FF00FF) is a color no real asset's palette should ever legitimately
// contain, so it's safe to key out without clipping real content. A
// full standalone sentence, not a comma-led fragment — every
// `.prompt.txt` already ends in its own terminal period, so this gets
// joined on with a blank line (see adjust() below), never concatenated
// straight onto existing punctuation.
const CHROMA_KEY_BACKGROUND_CLAUSE =
  "The entire area meant to end up transparent — including the background behind the subject and any fully enclosed hollow regions within it — must be rendered as flat solid magenta (#FF00FF) with no gradient or texture; magenta must not appear anywhere else in the image.";

// Reinforces the request/background="transparent" API parameter
// (clients/open-router.ts's generateImage()) with matching prompt text
// when a model natively supports transparency — providers vary in how
// reliably they honor an out-of-band parameter alone, and prompt text
// is the one channel every model actually attends to. Deliberately
// generic (no reference to any specific subject/asset) so it appends
// cleanly to any prompt, the same way CHROMA_KEY_BACKGROUND_CLAUSE does
// — a full standalone sentence, joined on with a blank line rather than
// assuming anything about how the prompt's own last sentence ends.
const TRANSPARENT_BACKGROUND_CLAUSE =
  "Render this on a fully transparent background — no background color, texture, gradient, or scenery of any kind; only the subject itself, with true alpha transparency everywhere else.";

// Dual-shape on purpose: OpenRouter/Gemini's declared resolution enums
// have been observed spelling the smallest tier "512" (bare pixel number)
// rather than "0.5K" — the other three tiers pass through identically to
// our own names. "0.5K" is kept here defensively even though it's never
// actually appeared in real data.
const RESOLUTION_RANK: Record<string, number> = { "512": 0, "0.5K": 0, "1K": 1, "2K": 2, "4K": 3 };
const RESOLUTION_TIERS = ["0.5K", "1K", "2K", "4K"] as const;

// Whether `model` can serve `spec` at all and, if so, a spec adjusted to
// what it actually supports: minResolution substituted for whichever
// tier pickResolutionTier below picks (cheapest qualifying tier, or the
// largest one for a per-image-billed model — see its own doc comment),
// and — whenever spec asks for a transparent background
// — promptText reinforced with matching text either way: the chroma-key
// clause (plus background downgraded to "opaque") when the model can't
// natively render transparency, so clean-image.ts's pixel-side cleanup
// can key it out after generation; or, when the model does support it
// natively, TRANSPARENT_BACKGROUND_CLAUSE instead, background left as
// "transparent" so generateImage() still passes the real API parameter
// too. Returns null when nothing here makes this model usable for this
// spec: unsupported aspect ratio, or no resolution tier meets the floor.
export function adjust(spec: ImageGenerationRequirements, model: Model): ImageGenerationRequirements | null {
  if (!supportsAspectRatio(model, spec.aspectRatio)) return null;

  const minResolution = pickResolutionTier(model, spec.minResolution);
  if (!minResolution) return null;

  const wantsTransparent = spec.background === "transparent";
  const nativelySupported = wantsTransparent && supportsBackground(model, "transparent");
  const needsChromaKey = wantsTransparent && !nativelySupported;

  let promptText = spec.promptText;
  if (needsChromaKey) promptText += "\n\n" + CHROMA_KEY_BACKGROUND_CLAUSE;
  else if (nativelySupported) promptText += "\n\n" + TRANSPARENT_BACKGROUND_CLAUSE;

  return {
    ...spec,
    minResolution,
    background: needsChromaKey ? "opaque" : spec.background,
    promptText,
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

function supportsBackground(model: Model, background: ImageGenerationRequirements["background"]): boolean {
  if (background === "opaque") return true; // every model renders an opaque background by default
  return model.supported_parameters?.background?.values?.includes("transparent") ?? false;
}

function supportsAspectRatio(model: Model, aspectRatio: ImageGenerationRequirements["aspectRatio"]): boolean {
  if (!aspectRatio) return true; // no requirement — every model qualifies
  return model.supported_parameters?.aspect_ratio?.values?.includes(aspectRatio) ?? false;
}

// True when this model has exactly one output_image/unit:"image"
// pricing line — a single flat price that really doesn't change with
// resolution (e.g. bytedance-seed/seedream-4.5's one $0.04 line). False
// both when there's no such line at all (billed per-megapixel/token
// instead, where resolution obviously does change cost) and when there
// are *several* such lines (a provider pricing different resolution
// `variant`s differently — e.g. x-ai/grok-imagine-image-quality: $0.05
// at variant "1k", $0.07 at variant "2k", a real recorded case — see
// image-cost-estimate.test.ts's calibration entry for it). Only the
// single-flat-line case gets the "resolution is free" treatment below.
function hasSingleFlatImagePrice(model: Model): boolean {
  return model.pricing.filter((p) => p.billable === "output_image" && p.unit === "image").length === 1;
}

// The resolution tier to request for this model, among the ones it
// actually declares support for at/above minResolution — or undefined
// if nothing qualifies. A model with no declared resolution parameter
// at all is assumed to output around its own native ~512px by default,
// so it only qualifies for 0.5K floors.
//
// For models with a single flat per-image price (hasSingleFlatImagePrice
// above), this picks the *largest* qualifying tier rather than the
// cheapest: resolution is genuinely free either way for these, so
// there's no cost reason to economize, and asking for more headroom
// guards against a per-model minimum-pixel floor OpenRouter's discovery
// API never exposes (a "2K" + a non-square aspect ratio can still fall
// under some models' own undeclared pixel floor — see the 2026-07-29
// seedream-4.5 failure this rule was added after: our "2K" request was
// rejected for computing to 2048x1536 at 4:3, under that model's
// undocumented 3,686,400px minimum). Every other model — including one
// priced per resolution `variant`, where a bigger tier genuinely costs
// more — keeps the original cheapest-that-clears-the-floor choice.
function pickResolutionTier(
  model: Model,
  minResolution: ImageGenerationRequirements["minResolution"],
): ImageGenerationRequirements["minResolution"] | undefined {
  const declared = model.supported_parameters?.resolution?.values;
  const floorRank = RESOLUTION_RANK[minResolution];
  if (!declared || declared.length === 0) {
    return floorRank <= RESOLUTION_RANK["512"] ? minResolution : undefined;
  }
  const qualifyingRanks = declared.map((v) => RESOLUTION_RANK[v]).filter((r): r is number => r !== undefined && r >= floorRank);
  if (qualifyingRanks.length === 0) return undefined;
  const rank = hasSingleFlatImagePrice(model) ? Math.max(...qualifyingRanks) : Math.min(...qualifyingRanks);
  return RESOLUTION_TIERS[rank];
}
