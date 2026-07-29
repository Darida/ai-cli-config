import { readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import sharp from "sharp";

// The one shared input model for every tool in this package (generate-
// asset, pick-image-model, list-image-models, image-cost-estimate) — what
// asset to generate, expressed in this toolkit's own provider-agnostic
// vocabulary. aspectRatio/minResolution/background map directly onto
// OpenRouter's Images API request fields.
//
// On disk, one asset == two colocated files sharing the asset id as their
// basename: <id>.json (this interface's structural fields) + <id>.prompt.txt
// (promptText, freeform). Deliberately split rather than one combined JSON
// file: prompt-text edits are frequent, low-stakes wording tweaks, while
// config edits (aspect ratio, resolution, background — rarer, more
// fundamental changes like layout/size) matter differently in git history.
// Keeping them in separate files keeps each kind of edit's diff/blame
// legible on its own, instead of every wording tweak burying config
// history in noise and vice versa.
export interface InputImage {
  path: string;
  width?: number;
  height?: number;
}

export interface AssetSpec {
  // Output file path, relative to the directory containing this asset's
  // own .json/.prompt.txt files (assetsDir) — resolved to an absolute path
  // by readImageGenerationRequirements below. Its extension is also the
  // output format.
  destination: string;
  aspectRatio?: "1:1" | "3:2" | "2:3" | "3:4" | "4:3" | "4:5" | "5:4" | "9:16" | "16:9" | "21:9";
  minResolution: "0.5K" | "1K" | "2K" | "4K"; // a floor, not an exact request — more resolution is always fine
  background: "transparent" | "opaque";
  mockImage?: string | InputImage; // Relative path string or InputImage object in .json
}

// Every library function in this package accepts this combined entity two
// ways: folder + asset id (readImageGenerationRequirements below, parses
// both files off disk — what every CLI's main() uses) or the entity
// already constructed in memory (what tests and other programmatic callers
// use directly, without touching the filesystem).
export interface ImageGenerationRequirements extends Omit<AssetSpec, "mockImage"> {
  promptText: string;
  mockImage?: InputImage;
}

// No tool in this package resolves a relative path against "wherever the
// caller happened to be standing" — that used to be done via an
// IMAGE_GEN_CALLER_CWD env var bridged in from the bin/* shims, which
// broke down as soon as vite-node needed the real process cwd to be this
// package's own directory (for dependency resolution) at the same time.
// Simpler and unambiguous: every directory a caller passes in must already
// be absolute. Fails loudly rather than guessing.
function requireAbsolutePath(flagName: string, value: string): void {
  if (!isAbsolute(value)) {
    throw new Error(`${flagName} must be an absolute path, got "${value}"`);
  }
}

export async function readImageGenerationRequirements(assetsDir: string, assetId: string): Promise<ImageGenerationRequirements> {
  requireAbsolutePath("assets directory", assetsDir);
  const spec = JSON.parse(await readFile(resolve(assetsDir, `${assetId}.json`), "utf8")) as AssetSpec;
  const promptText = (await readFile(resolve(assetsDir, `${assetId}.prompt.txt`), "utf8")).trim();

  let mockImage: InputImage | undefined;
  if (spec.mockImage) {
    const rawPath = typeof spec.mockImage === "string" ? spec.mockImage : spec.mockImage.path;
    const absPath = isAbsolute(rawPath) ? rawPath : resolve(assetsDir, rawPath);
    let width = typeof spec.mockImage === "object" ? spec.mockImage.width : undefined;
    let height = typeof spec.mockImage === "object" ? spec.mockImage.height : undefined;

    if (!width || !height) {
      try {
        const meta = await sharp(absPath).metadata();
        width = width ?? meta.width;
        height = height ?? meta.height;
      } catch {
        // If sharp fails to read metadata, dimensions remain undefined (cost estimate will fallback to tier budget)
      }
    }
    mockImage = { path: absPath, width, height };
  }

  return {
    ...spec,
    destination: resolve(assetsDir, spec.destination),
    mockImage,
    promptText,
  };
}
