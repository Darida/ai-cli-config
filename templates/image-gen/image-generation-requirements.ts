import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

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
export interface AssetSpec {
  destination: string; // output file path, relative to the caller's directory — its extension is also the output format
  aspectRatio?: "1:1" | "3:2" | "2:3" | "3:4" | "4:3" | "4:5" | "5:4" | "9:16" | "16:9" | "21:9";
  minResolution: "0.5K" | "1K" | "2K" | "4K"; // a floor, not an exact request — more resolution is always fine
  background: "transparent" | "opaque";
}

// Every library function in this package accepts this combined entity two
// ways: folder + asset id (readImageGenerationRequirements below, parses
// both files off disk — what every CLI's main() uses) or the entity
// already constructed in memory (what tests and other programmatic callers
// use directly, without touching the filesystem).
export interface ImageGenerationRequirements extends AssetSpec {
  promptText: string;
}

export async function readImageGenerationRequirements(assetsDir: string, assetId: string): Promise<ImageGenerationRequirements> {
  const spec = JSON.parse(await readFile(resolve(assetsDir, `${assetId}.json`), "utf8")) as AssetSpec;
  const promptText = (await readFile(resolve(assetsDir, `${assetId}.prompt.txt`), "utf8")).trim();
  return { ...spec, promptText };
}
