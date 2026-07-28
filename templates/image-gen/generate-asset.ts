import { mkdir, writeFile } from "node:fs/promises";
import { dirname, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { cleanImage } from "./clean-image";
import { pickResolutionValue, supportsBackground } from "./image-cost-estimate";
import { type ImageGenerationRequirements, readImageGenerationRequirements } from "./image-generation-requirements";
import { fetchEndpoints } from "./openrouter-images-api";
import { selectImageModel } from "./pick-image-model";

// OpenRouter's dedicated, provider-normalized Images API (not the general
// chat-completions endpoint) — this is what actually exposes resolution/
// aspect_ratio/background as request fields. No auto-router exists on this
// API (unlike chat-completions' "openrouter/auto"), so
// resolveOpenRouterModel() below picks a concrete model per request.
const OPENROUTER_IMAGES_URL = "https://openrouter.ai/api/v1/images";

// Chroma-key cleanup itself lives in clean-image.ts (both as a library
// function this file calls, and as its own standalone script — `./clean-
// image <asset-id>` — for re-tuning its constants against an already-
// cached raw without spending on a fresh generation). This file only owns
// the *prompt-side* half of the workaround: asking the model for a flat
// magenta background to key out, via CHROMA_KEY_BACKGROUND_CLAUSE below.
// OpenRouter's Images API supports a real `background: "transparent"`
// request field, but only some of its underlying models declare it —
// resolveOpenRouterModel() checks the specific model picked for this run
// and only falls back to the clause below when that model doesn't
// support it.
const CHROMA_KEY_BACKGROUND_CLAUSE =
  ", the entire area meant to end up transparent — including the background behind the subject and any fully enclosed hollow regions within it — rendered as flat solid magenta (#FF00FF) with no gradient or texture; magenta must not appear anywhere else in the image";

// The caller's actual directory, not this process's real cwd. The bin/*
// shims `cd` into this package's own directory before running (vite-node
// needs that to resolve its own dependencies correctly — see bin/
// generate-asset's own comment), capturing where the caller really was
// into IMAGE_GEN_CALLER_CWD first. Falls back to process.cwd() so running
// this file directly (bypassing the shim, e.g. via `npm run` from within
// this package) still does something sensible.
function callerCwd(): string {
  return process.env.IMAGE_GEN_CALLER_CWD ?? process.cwd();
}

function buildPromptText(promptText: string, needsChromaKey: boolean): string {
  return needsChromaKey ? promptText + CHROMA_KEY_BACKGROUND_CLAUSE : promptText;
}

function outputFormat(destination: string): "png" | "jpeg" {
  const ext = extname(destination);
  if (ext === ".png") return "png";
  if (ext === ".jpg" || ext === ".jpeg") return "jpeg";
  throw new Error(`Unsupported destination extension for output format: ${ext}`);
}

// Runs selectImageModel()'s filter/price/percentile pick (see
// pick-image-model.ts), then re-fetches that specific model's endpoints
// directly (rather than trusting the bulk-list data selectImageModel
// already had) to check transparent-background support and pick a real
// resolution value right at the point they're used.
async function resolveOpenRouterModel(
  requirements: ImageGenerationRequirements,
): Promise<{ modelId: string; provider: string; needsChromaKey: boolean; resolutionValue: string | undefined }> {
  const { picked, pool } = await selectImageModel(requirements);

  const endpoints = await fetchEndpoints(picked.modelId);
  const matchingEndpoint = endpoints.find((e) => e.provider_name === picked.provider) ?? picked.endpoint;
  const supportsTransparent = supportsBackground(matchingEndpoint.supported_parameters, "transparent");
  const needsChromaKey = requirements.background === "transparent" && !supportsTransparent;
  // supportsMinResolution() (already applied by selectImageModel) only
  // guarantees *some* declared value meets the floor — never assume our
  // own "0.5K"/"512" shape is literally one of this model's declared
  // values. Pick the cheapest one that actually is; undefined (field
  // omitted from the request) when the model declares no resolution
  // parameter at all.
  const resolutionValue = pickResolutionValue(matchingEndpoint.supported_parameters, requirements.minResolution);

  console.log(
    `OpenRouter model: ${picked.modelId} (${picked.provider}) — $${picked.usd.toFixed(4)} estimated, ` +
      `chosen from ${pool.length} candidates at/under the 30th-percentile+10% price threshold. ` +
      `Native transparent background: ${supportsTransparent ? "yes" : "no — using chroma-key cleanup"}. ` +
      `Resolution requested: ${resolutionValue ?? "(model declares no resolution parameter — omitted)"}.`,
  );

  return { modelId: picked.modelId, provider: picked.provider, needsChromaKey, resolutionValue };
}

async function generateImageOpenRouter(requirements: ImageGenerationRequirements, apiKey: string): Promise<{ bytes: Buffer; needsChromaKey: boolean }> {
  const { modelId, needsChromaKey, resolutionValue } = await resolveOpenRouterModel(requirements);

  const body = {
    model: modelId,
    prompt: buildPromptText(requirements.promptText, needsChromaKey),
    resolution: resolutionValue,
    aspect_ratio: requirements.aspectRatio,
    // Only pass "transparent" when the picked model actually declares
    // support for it — an unsupported enum value risks a request-time
    // rejection from providers that validate strictly. When it doesn't,
    // the chroma-key clause above stands in for the request instead.
    background: needsChromaKey ? undefined : requirements.background,
    output_format: outputFormat(requirements.destination),
  };

  const response = await fetch(OPENROUTER_IMAGES_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    throw new Error(`OpenRouter request failed: ${response.status} ${response.statusText}\n${await response.text()}`);
  }

  const result = await response.json();
  const b64Json: string | undefined = result.data?.[0]?.b64_json;

  if (!b64Json) {
    throw new Error(`OpenRouter response had no image content:\n${JSON.stringify(result, null, 2)}`);
  }

  return { bytes: Buffer.from(b64Json, "base64"), needsChromaKey };
}

const MIN_RESOLUTIONS = ["0.5K", "1K", "2K", "4K"] as const;

function parseArgs(argv: string[]): {
  assetsDir: string;
  assetId: string;
  key: string;
  forceResolution?: ImageGenerationRequirements["minResolution"];
} {
  let assetsDir: string | undefined;
  let key: string | undefined;
  let forceResolution: ImageGenerationRequirements["minResolution"] | undefined;
  const positional: string[] = [];

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--assets-dir") {
      assetsDir = argv[++i];
    } else if (arg.startsWith("--key=")) {
      key = arg.slice("--key=".length);
    } else if (arg === "--force-resolution") {
      const value = argv[++i];
      if (!MIN_RESOLUTIONS.includes(value as ImageGenerationRequirements["minResolution"])) {
        throw new Error(`--force-resolution must be one of ${MIN_RESOLUTIONS.join(", ")}, got "${value}"`);
      }
      forceResolution = value as ImageGenerationRequirements["minResolution"];
    } else {
      positional.push(arg);
    }
  }

  const assetId = positional[0];
  if (!assetsDir || !key || !assetId) {
    throw new Error(
      "Usage: generate-asset --assets-dir <path> --key=<openrouter-api-key> [--force-resolution <0.5K|1K|2K|4K>] <asset-id>\n" +
        "  --assets-dir   required. Directory containing <asset-id>.json + <asset-id>.prompt.txt, " +
        "resolved relative to the current directory.\n" +
        "  --key   required. OpenRouter API key for the Images API request. This file has no " +
        "opinion on where that key comes from — the bin/generate-asset shim resolves it from " +
        "`git config openrouter.imagenapikey` and passes it here; call this file directly " +
        "(bypassing the shim) to supply one another way.\n" +
        "  --force-resolution   optional. Overrides every asset's own minResolution for this run " +
        "(e.g. while iterating on prompts/layout, to keep requests cheap) without editing its spec.\n" +
        "To re-tune CHROMA_KEY_* constants against an already-generated raw without spending on a " +
        "fresh generation, use `./clean-image --input=<destination>.raw --output=<destination>` " +
        "instead — only works if this asset's generation actually needed chroma-key cleanup in the " +
        "first place (native-transparent and opaque outputs never cache a raw, since there's " +
        "nothing to re-clean).",
    );
  }

  return { assetsDir: resolve(callerCwd(), assetsDir), assetId, key, forceResolution };
}

async function main() {
  const { assetsDir, assetId, key, forceResolution } = parseArgs(process.argv.slice(2));

  const requirements = await readImageGenerationRequirements(assetsDir, assetId);
  if (forceResolution) {
    requirements.minResolution = forceResolution;
  }
  const destination = resolve(callerCwd(), requirements.destination);

  const result = await generateImageOpenRouter(requirements, key);
  const { bytes: rawBytes, needsChromaKey } = result;

  let imageBytes: Buffer;
  let rawPath: string | undefined;
  if (needsChromaKey) {
    // Only cache a .raw file when there's an actual cleanup step worth
    // re-tuning later (see clean-image.ts) — a pass-through re-encode has
    // nothing worth caching.
    rawPath = `${destination}.raw`;
    await mkdir(dirname(rawPath), { recursive: true });
    await writeFile(rawPath, rawBytes);
    imageBytes = await cleanImage(rawBytes);
  } else {
    imageBytes = await sharp(rawBytes).toFormat(outputFormat(requirements.destination)).toBuffer();
  }

  await mkdir(dirname(destination), { recursive: true });
  await writeFile(destination, imageBytes);

  console.log(
    rawPath
      ? `Wrote ${imageBytes.length} bytes to ${destination} (raw cached at ${rawPath})`
      : `Wrote ${imageBytes.length} bytes to ${destination} (no raw cached — output needed no chroma-key cleanup)`,
  );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exitCode = 1;
  });
}
