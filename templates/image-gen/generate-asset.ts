import { mkdir, writeFile } from "node:fs/promises";
import { dirname, extname } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { adjust, shouldCleanupImage } from "./asset-adjuster";
import { cleanImage } from "./clean-image";
import { fetchModelEndpoints, generateImage } from "./clients/open-router";
import { type ImageGenerationRequirements, readImageGenerationRequirements } from "./image-generation-requirements";
import { selectImageModel } from "./pick-image-model";

const MIN_RESOLUTIONS = ["0.5K", "1K", "2K", "4K"] as const;

async function main() {
  const { assetsDir, assetId, key, forceResolution } = parseArgs(process.argv.slice(2));

  const requirements = await readImageGenerationRequirements(assetsDir, assetId);
  if (forceResolution) {
    requirements.minResolution = forceResolution;
  }

  const { picked, pool } = await selectImageModel(requirements);

  // Re-fetch this specific model fresh right here, rather than trusting
  // the bulk-list data selectImageModel() already had — capabilities can
  // differ by the time we're actually about to spend on a generation.
  const freshModels = await fetchModelEndpoints(picked.modelId);
  const model = freshModels.find((m) => m.provider === picked.provider);
  if (!model) {
    throw new Error(`Picked model ${picked.modelId} (${picked.provider}) no longer has that provider endpoint on re-fetch.`);
  }

  const adjusted = adjust(requirements, model);
  if (!adjusted) {
    throw new Error(`Picked model ${picked.modelId} (${picked.provider}) no longer supports this asset's requirements on re-fetch.`);
  }
  const needsChromaKey = shouldCleanupImage(requirements, adjusted);

  console.log(
    `OpenRouter model: ${picked.modelId} (${picked.provider}) — $${picked.usd.toFixed(4)} estimated, ` +
      `chosen from ${pool.length} candidates at/under the 30th-percentile+10% price threshold. ` +
      `${needsChromaKey ? "Native transparent background not supported — using chroma-key cleanup." : "Requested field values are natively supported."}`,
  );

  const rawBytes = await generateImage(model, adjusted, key);

  const destination = requirements.destination; // already absolute — resolved by readImageGenerationRequirements
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
    imageBytes = await sharp(rawBytes).toFormat(outputFormat(destination)).toBuffer();
  }

  await mkdir(dirname(destination), { recursive: true });
  await writeFile(destination, imageBytes);

  console.log(
    rawPath
      ? `Wrote ${imageBytes.length} bytes to ${destination} (raw cached at ${rawPath})`
      : `Wrote ${imageBytes.length} bytes to ${destination} (no raw cached — output needed no chroma-key cleanup)`,
  );
}

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
      "Usage: generate-asset --assets-dir <absolute-path> --key=<openrouter-api-key> [--force-resolution <0.5K|1K|2K|4K>] <asset-id>\n" +
        "  --assets-dir   required. Absolute path to the directory containing <asset-id>.json + " +
        "<asset-id>.prompt.txt — must be absolute, this file does no relative-path resolution at " +
        "all (see readImageGenerationRequirements).\n" +
        "  --key   required. OpenRouter API key for the Images API request. This file has no " +
        "opinion on where that key comes from — image-generation.sh resolves it from `git config " +
        "openrouter.imagenapikey` and passes it here; call this file directly (bypassing that " +
        "script) to supply one another way.\n" +
        "  --force-resolution   optional. Overrides every asset's own minResolution for this run " +
        "(e.g. while iterating on prompts/layout, to keep requests cheap) without editing its spec.\n" +
        "To re-tune CHROMA_KEY_* constants against an already-generated raw without spending on a " +
        "fresh generation, use `./image-generation.sh clean_image --input=<destination>.raw " +
        "--output=<destination>` instead — only works if this asset's generation actually needed " +
        "chroma-key cleanup in the first place (native-transparent and opaque outputs never cache " +
        "a raw, since there's nothing to re-clean).",
    );
  }

  return { assetsDir, assetId, key, forceResolution };
}

function outputFormat(destination: string): "png" | "jpeg" {
  const ext = extname(destination);
  if (ext === ".png") return "png";
  if (ext === ".jpg" || ext === ".jpeg") return "jpeg";
  throw new Error(`Unsupported destination extension for output format: ${ext}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exitCode = 1;
  });
}
