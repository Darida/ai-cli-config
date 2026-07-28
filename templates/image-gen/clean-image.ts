import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

// Chroma-key cleanup, extracted so it's usable both as a library function
// (generate-asset.ts calls cleanImage() right after a generation that
// needed it) and standalone against an already-cached raw file:
// `./clean-image --input=<path> --output=<path>`. No asset-spec/JSON
// knowledge here at all — just two file paths — so there's no "maybe skip
// cleaning" branch either: invoking this at all, on any input, means
// chroma-key cleanup is what's wanted. generate-asset.ts's own convention
// (a `.raw` file only ever exists for an asset whose generation actually
// needed chroma-key cleanup — see its main()) lives entirely on that
// file's side, not in here.
const CHROMA_KEY_COLOR: [number, number, number] = [255, 0, 255]; // magenta — absent from every asset's actual palette
// Keyness = min(r, b) - g: how strongly a pixel matches magenta's actual
// signature (R and B both high, G suppressed), regardless of brightness.
// Empirically (sampled a real generation's raw JPEG pixel-by-pixel across
// its background transition) this tracks "does this look magenta" far
// better than Euclidean distance to (255,0,255) did: a pixel like
// (185,24,182) is only 104 units from pure magenta by Euclidean distance —
// distance treated it as ~80% opaque — despite plainly reading as pink to
// the eye, because Euclidean distance penalizes darker/dimmer shades of the
// key color as if they were "far" from it even though the R-high/G-low/
// B-high pattern that makes something look magenta is still fully intact.
const CHROMA_KEY_INNER_KEYNESS = 20; // at/below this, opaque — real subject content sampled at ~-5 to 5
const CHROMA_KEY_OUTER_KEYNESS = 140; // at/above this, transparent — pure background sampled at ~150-230
// Below this alpha, skip de-spill (unmixing divides by alpha, which blows
// up numerically as alpha -> 0) — the pixel is transparent enough that its
// exact leftover color barely matters anyway.
const CHROMA_KEY_DESPILL_MIN_ALPHA = 40;

function chromaKeyAlpha(keyness: number): number {
  if (keyness <= CHROMA_KEY_INNER_KEYNESS) return 255;
  if (keyness >= CHROMA_KEY_OUTER_KEYNESS) return 0;
  const t = (keyness - CHROMA_KEY_INNER_KEYNESS) / (CHROMA_KEY_OUTER_KEYNESS - CHROMA_KEY_INNER_KEYNESS);
  return Math.round((1 - t) * 255);
}

export async function cleanImage(rawBytes: Buffer): Promise<Buffer> {
  const { data, info } = await sharp(rawBytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const [kr, kg, kb] = CHROMA_KEY_COLOR;

  for (let i = 0; i < data.length; i += info.channels) {
    const keyness = Math.min(data[i], data[i + 2]) - data[i + 1];
    const alpha = chromaKeyAlpha(keyness);
    data[i + 3] = alpha;

    // De-spill: a partially-keyed edge pixel is a blend of the real subject
    // color and the magenta backdrop (JPEG blur/anti-aliasing at the
    // boundary), so its RGB is still magenta-tinted even though its alpha
    // is now reduced — left alone, this shows up as a visible magenta
    // fringe once composited over anything but magenta. Unmix assuming the
    // observed pixel = subject * a + key * (1 - a), i.e. subject = (observed
    // - key * (1 - a)) / a, using our own alpha as the assumed blend factor.
    // Skipped below CHROMA_KEY_DESPILL_MIN_ALPHA — dividing by a near-zero
    // alpha amplifies pixel noise into wildly wrong colors, and a pixel
    // that transparent barely shows its color anyway.
    if (alpha >= CHROMA_KEY_DESPILL_MIN_ALPHA && alpha < 255) {
      const a = alpha / 255;
      data[i] = Math.max(0, Math.min(255, Math.round((data[i] - kr * (1 - a)) / a)));
      data[i + 1] = Math.max(0, Math.min(255, Math.round((data[i + 1] - kg * (1 - a)) / a)));
      data[i + 2] = Math.max(0, Math.min(255, Math.round((data[i + 2] - kb * (1 - a)) / a)));
    }
  }

  return sharp(data, { raw: { width: info.width, height: info.height, channels: info.channels } })
    .png()
    .toBuffer();
}

// No relative-path resolution against "wherever the caller happened to be
// standing" here (unlike vite-node's own real process cwd, which the bin/
// clean-image shim still has to cd into a package's own directory to
// resolve dependencies correctly) — --input/--output must already be
// absolute. Fails loudly rather than guessing what they're relative to.
function requireAbsolutePath(flagName: string, value: string): void {
  if (!isAbsolute(value)) {
    throw new Error(`${flagName} must be an absolute path, got "${value}"`);
  }
}

function parseArgs(argv: string[]): { input: string; output: string } {
  let input: string | undefined;
  let output: string | undefined;

  for (const arg of argv) {
    if (arg.startsWith("--input=")) {
      input = arg.slice("--input=".length);
    } else if (arg.startsWith("--output=")) {
      output = arg.slice("--output=".length);
    }
  }

  if (!input || !output) {
    throw new Error(
      "Usage: clean-image --input=<absolute-path> --output=<absolute-path>\n" +
        "Applies chroma-key cleanup to the raw image at --input and writes the result to " +
        "--output. Both must be absolute paths. No asset-spec/JSON involved — just two file " +
        "paths. Free and offline: no network calls, no API cost, safe to re-run while tuning " +
        "CHROMA_KEY_* above.",
    );
  }

  requireAbsolutePath("--input", input);
  requireAbsolutePath("--output", output);
  return { input, output };
}

async function main() {
  const { input: inputPath, output: outputPath } = parseArgs(process.argv.slice(2));

  const rawBytes = await readFile(inputPath);
  const imageBytes = await cleanImage(rawBytes);
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, imageBytes);

  console.log(`Wrote ${imageBytes.length} bytes to ${outputPath} (re-cleaned from ${inputPath})`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exitCode = 1;
  });
}
