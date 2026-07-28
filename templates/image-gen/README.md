# image-gen

Generic, project-agnostic asset-image generator against OpenRouter's
dedicated Images API. Point it at any project's own folder of asset specs
via `--assets-dir` — nothing in this package assumes a particular project
layout, folder name, or asset catalog. Run the tools directly by path from
wherever your project lives, e.g. from a project root that has this repo
checked out as a sibling or submodule:

```
../ai-cli-config/templates/image-gen/generate-asset --assets-dir src/assets/prompts building-arena
```

## Setup (once per checkout)

```
npm --prefix ai-cli-config/templates/image-gen install
```

(Already wired into `git/setup` if this is checked out inside a workspace
that has one.) `sharp`/`vite-node`/`vitest`/`typescript` live only in this
package's own `node_modules` — no consuming project needs to add anything
to its own `package.json`.

## Tools

Each is a small bash shim (`generate-asset`, `list-image-models`,
`pick-image-model`, `clean-image`) that resolves its own real location to
find its `node_modules`/`.ts` file, but never `cd`s there — the actual
Node process keeps running with whatever directory you invoked it from as
its cwd. That matters for two things: `--assets-dir` resolves relative to
that cwd, and so does the OpenRouter API key lookup (see Auth below).

- **`./generate-asset --assets-dir <path> [--force-resolution <tier>] <asset-id>`**
  — the actual generator. Reads `<assets-dir>/<asset-id>.json` (spec) and
  `<assets-dir>/<asset-id>.prompt.txt` (prompt), picks a model (see Model
  selection), calls OpenRouter's Images API, and writes the result to
  `destination` from the spec (resolved relative to cwd). `--force-
  resolution` overrides every asset's own `minResolution` for that one
  run without editing its spec — useful while iterating on prompts/layout
  to keep requests cheap.
- **`./clean-image --assets-dir <path> <asset-id>`** — re-runs just the
  chroma-key cleanup step (see Transparency) against an already-cached
  `<destination>.raw` file, without calling any generation API again.
  Free and fully offline — no network calls at all — so it's safe to
  re-run repeatedly while tuning the `CHROMA_KEY_*` constants at the top
  of `clean-image.ts`. Fails if no `.raw` file exists for that asset,
  which is also the normal case for an asset whose generation didn't need
  chroma-key cleanup in the first place (see below) — there's nothing to
  re-clean for those.
- **`./list-image-models --assets-dir <path> <asset-id>`** — human-facing
  landscape view. Estimates a real dollar cost for every OpenRouter
  Images API model/provider endpoint against that asset's actual spec +
  prompt, prints everything sorted cheapest-first, plus a feature-support
  tally and a bucket for endpoints with no published pricing (not free,
  just unpriced — excluded from ranking but still shown). Doesn't filter
  by feature support; for deciding selection criteria, not for automating
  a pick.
- **`./pick-image-model --assets-dir <path> <asset-id>`** — CLI preview of
  the same selection algorithm `generate-asset` uses internally (see
  `selectImageModel()` in `pick-image-model.ts`), without spending on an
  actual generation.

## Auth

`generate-asset` needs an OpenRouter API key: `git config
openrouter.imagenapikey`. Looked up via plain `git config --get` — no
explicit repo path — so it resolves against whatever repo the *calling*
directory happens to be inside (git itself walks up from cwd to find the
nearest `.git`, exactly like any other git command). This package has no
opinion on workspace layout: run it from a plain standalone repo, a
submodule, or an outer workspace root that holds the key on behalf of
several submodules — whichever repo your cwd is inside when you invoke
the shim is where the key must be configured. Fails loudly, with the
directory it looked in, if it's unset — never searches anywhere else or
falls back to a default.

## Model selection

There's no auto-router on OpenRouter's Images API (unlike the general
chat-completions endpoint's `"openrouter/auto"`) — every request needs a
concrete model slug. `selectImageModel()` in `pick-image-model.ts` picks
one, using live data from OpenRouter's discovery endpoints (`GET
/api/v1/images/models`, `GET /api/v1/images/models/{id}/endpoints` —
wrapped by `openrouter-images-api.ts`):

1. Filter to endpoints that support the asset's `aspectRatio` (if any)
   and whose declared `resolution` values reach at least its
   `minResolution` floor (a model with no declared `resolution` parameter
   at all is assumed to output around 512px by default, so it only
   qualifies for `0.5K` assets).
2. Drop endpoints with no computable price.
3. Sort by estimated cost, ascending.
4. Compute the **30th-percentile** price (not the mean) of what's left,
   add a 10% margin, and drop everything priced above that threshold —
   keeps a mid/cheap band, excludes the expensive tail.
5. Pick uniformly at random from what remains, so repeated runs spread
   across providers instead of always hitting the single cheapest one.

Cost estimation (`image-cost-estimate.ts`) handles OpenRouter's three
output-pricing shapes: flat per-image (`unit: "image"`, optionally
per-resolution-`variant`), per-megapixel (`unit: "megapixel"`, computed
from *the asset's own* `minResolution` tier directly, never gated on
declared model support — that gating is what the filters above are for),
and per-token (`unit: "token"`, using the general ViT patch-tokenization
estimate `N = (H×W)/P²` in `image-token-estimate.ts` — deliberately not a
hardcoded per-vendor token table, since none of that is exposed by the
API and vendor docs go stale; calibrated against one real recorded
generation, see `image-cost-estimate.test.ts` and `PATCH_SIZE_PX`'s own
comment for the numbers).

Neither `selectImageModel()` nor `list-image-models.ts` filters by
`background` — a model's transparency support is informational only
(`supportsBackground()`); it never removes a model from consideration.
`resolveOpenRouterModel()` in `generate-asset.ts` checks the specific
model that got picked, at the point it's about to be used, and decides
from that whether the request needs the chroma-key workaround (see
Transparency below) — re-checked fresh on every call, never cached or
persisted anywhere, since the picked model can differ from one run to the
next.

`selectImageModel()` also only guarantees that *some* declared resolution
value on the picked model meets the asset's floor — not that this
package's own `"0.5K"`/`"512"` shape is literally one of that model's
declared values. `pickResolutionValue()` in `image-cost-estimate.ts`
picks the cheapest value the model actually declares that still meets the
floor (or omits the field entirely if the model declares no `resolution`
parameter at all).

## Transparency

Two independent halves, split across two files:

- **The prompt-side ask** (`generate-asset.ts`): when an asset needs
  transparency but the model picked for this request can't natively
  deliver it, the prompt gets an extra clause
  (`CHROMA_KEY_BACKGROUND_CLAUSE`) asking for a flat solid magenta
  (`#FF00FF`) background instead — pick a project palette where magenta
  never legitimately appears, so it's safe to key out without clipping
  real image content.
- **The pixel-side cleanup** (`clean-image.ts`): turns that magenta
  background into real alpha. Both a library function (`generate-
  asset.ts` calls `cleanImage()` directly right after a generation that
  needed it) and its own standalone CLI (see Tools above). Works *only*
  on `.raw` files, and a `.raw` file only ever exists for an asset whose
  original generation actually needed chroma-key cleanup — an asset whose
  picked model supports native `background: "transparent"`, or whose
  spec has `"background": "opaque"`, writes its final image directly and
  caches no raw at all, since a pure format re-encode has nothing worth
  caching for a later re-clean pass.

The cleanup algorithm: decode with `sharp`, key pixels out by **keyness**
— `min(r, b) - g`, i.e. how strongly a pixel matches magenta's actual
signature (R and B both high, G suppressed) — rather than Euclidean
distance to `(255, 0, 255)`. Distance was tried first and rejected: a
pixel like `(185, 24, 182)` is only 104 units from pure magenta by
Euclidean distance, so distance-based keying kept it ~80% opaque, despite
it plainly reading as pink — Euclidean distance penalizes darker/dimmer
shades of the key color as "far" even though the pattern that makes
something look magenta is fully intact. Keyness below
`CHROMA_KEY_INNER_KEYNESS` → opaque, above `CHROMA_KEY_OUTER_KEYNESS` →
transparent, linear falloff between (to avoid a hard-edged cutout), then
**de-spilled**: a partially-keyed edge pixel is still magenta-tinted even
after its alpha drops, so its RGB gets unmixed assuming `observed =
subject·a + magenta·(1-a)` — skipped below
`CHROMA_KEY_DESPILL_MIN_ALPHA`, since dividing by a near-zero alpha
amplifies noise into wildly wrong colors. Finally re-encodes as a real
alpha PNG.

## Input model

Every tool in this package (`generate-asset`, `list-image-models`,
`pick-image-model`, and the cost-estimation logic in
`image-cost-estimate.ts`) works against one shared entity,
`ImageGenerationRequirements` (`image-generation-requirements.ts`) — what
asset to generate, in this toolkit's own provider-agnostic vocabulary.
This is the officially supported input shape; nothing in this package
accepts anything else.

Each library function accepts that entity two ways:

- **Folder + asset id** — `readImageGenerationRequirements(assetsDir,
  assetId)` parses it off disk (what every CLI's `main()` does): the id's
  `.json` file for the structural fields below, plus its `.prompt.txt` for
  `promptText`.
- **Already parsed, in memory** — pass the entity directly (what tests and
  other programmatic callers do), no filesystem access involved.

`<asset-id>.json` in `--assets-dir`:

```json
{
  "destination": "path/to/output.png",
  "aspectRatio": "1:1",
  "minResolution": "1K",
  "background": "transparent"
}
```

- `destination` — output file path, resolved relative to the current
  directory when `generate-asset` runs. Its extension is also the output
  format (`.png`/`.jpg`/`.jpeg`).
- `aspectRatio` — optional; one of `1:1`, `3:2`, `2:3`, `3:4`, `4:3`,
  `4:5`, `5:4`, `9:16`, `16:9`, `21:9`. Omit when no aspect ratio actually
  matters for the asset (CSS force-stretches it regardless, or too few
  Images API models support the ratio you'd otherwise want — check with
  `list-image-models`).
- `minResolution` — a **floor**, not an exact request: one of `0.5K`,
  `1K`, `2K`, `4K`. More resolution is always fine.
- `background` — `"transparent"` or `"opaque"`.

`<asset-id>.prompt.txt` in the same directory: the raw prompt text (becomes
`promptText` on the parsed entity), plain text (not JSON), so it stays easy
to read and diff.

Prompt text and structural config are deliberately two files, not one JSON
blob with a `prompt` field: prompt-text edits are frequent, low-stakes
wording tweaks, while config edits (aspect ratio, resolution, background)
are rarer and more fundamental — they change actual layout/size decisions.
Splitting them keeps each kind of edit's diff and `git blame` legible on
its own, instead of every wording tweak burying config history in noise
and vice versa.
