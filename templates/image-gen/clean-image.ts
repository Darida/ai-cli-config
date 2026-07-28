import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import type { AssetSpec } from "./image-cost-estimate";

// Chroma-key cleanup, extracted so it's usable both as a library function
// (generate-asset.ts calls cleanImage() right after a generation that
// needed it) and standalone against an already-cached raw file:
// `./clean-image --assets-dir <path> <asset-id>`. There's no "maybe skip
// cleaning" branch in here — invoking this at all, either way, means
// chroma-key cleanup is what's needed. A generation whose output didn't
// need it (native transparent support, or an opaque background) never
// writes a `.raw` file in the first place (see generate-asset.ts's
// main()) — it writes its final image directly, since a pure format
// re-encode has nothing worth caching for a later re-clean pass. So a
// `.raw` file's mere existence already means chroma-key applies; running
// this against one never needs to ask "was chroma-key actually needed
// here?" over the network or from any stored flag.
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

async function readSpec(assetsDir: string, assetId: string): Promise<AssetSpec> {
  return JSON.parse(await readFile(resolve(assetsDir, `${assetId}.json`), "utf8")) as AssetSpec;
}

// The caller's actual directory, not this process's real cwd — see
// bin/clean-image's own comment for why the two differ (vite-node needs
// real cwd to be this package's own directory to resolve dependencies
// correctly) and how IMAGE_GEN_CALLER_CWD bridges that.
function callerCwd(): string {
  return process.env.IMAGE_GEN_CALLER_CWD ?? process.cwd();
}

async function main() {
  const args = process.argv.slice(2);
  let assetsDir: string | undefined;
  const positional: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--assets-dir") {
      assetsDir = args[++i];
    } else {
      positional.push(args[i]);
    }
  }
  const assetId = positional[0];

  if (!assetsDir || !assetId) {
    throw new Error(
      "Usage: clean-image --assets-dir <path> <asset-id>  (e.g. building-arena)\n" +
        "Applies chroma-key cleanup to that asset's already-cached <destination>.raw file " +
        "(destination resolved relative to the current directory) — fails if none exists " +
        "(never silently regenerates; run generate-asset for that). Free and offline: no " +
        "network calls, no API cost, safe to re-run while tuning CHROMA_KEY_* above.",
    );
  }

  const spec = await readSpec(resolve(callerCwd(), assetsDir), assetId);
  const destination = resolve(callerCwd(), spec.destination);
  const rawPath = `${destination}.raw`;
  const rawBytes = await readFile(rawPath);

  const imageBytes = await cleanImage(rawBytes);
  await mkdir(dirname(destination), { recursive: true });
  await writeFile(destination, imageBytes);

  console.log(`Wrote ${imageBytes.length} bytes to ${destination} (re-cleaned from cached raw at ${rawPath})`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exitCode = 1;
  });
}
