# image-gen

Generic, project-agnostic asset-image generator against OpenRouter's
dedicated Images API. Point it at any project's own folder of asset specs
via `--assets-dir` — nothing in this package assumes a particular project
layout, folder name, or asset catalog. Run it directly by path from
wherever your project lives, e.g. from a project root that has this repo
checked out as a sibling or submodule:

```
../ai-cli-config/templates/image-gen/image-generation.sh generate_asset --assets-dir "$(pwd)/src/assets/prompts" building-arena
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

One dispatcher, `image-generation.sh`, for every tool:

```
image-generation.sh <subcommand> [--flag=value ...] [args...]
```

It resolves its own real location to find its `node_modules`/`.ts` files,
then `cd`s into this package's own directory before running (vite-node
needs its real process cwd to be here to resolve native deps like `sharp`
correctly). Because of that `cd`, **every path a subcommand takes
(`--assets-dir`, `--input`, `--output`) must be an absolute path** —
nothing here does relative-path resolution against "wherever you happened
to be standing" when you invoked it.

- **`generate_asset --assets-dir <absolute-path> [--force-resolution <tier>] <asset-id>`**
  — the actual generator. Reads `<assets-dir>/<asset-id>.json` (spec) and
  `<assets-dir>/<asset-id>.prompt.txt` (prompt), picks a model (see Model
  selection), calls OpenRouter's Images API, and writes the result to
  `destination` from the spec (resolved relative to `assets-dir` — see
  Input model below). `--force-resolution` overrides every asset's own
  `minResolution` for that one run without editing its spec — useful
  while iterating on prompts/layout to keep requests cheap. The only
  subcommand that spends money.
- **`clean_image --input=<absolute-path> --output=<absolute-path>`** —
  re-runs just the chroma-key cleanup step (see Transparency) against an
  already-cached raw file (typically `<destination>.raw` from a prior
  `generate_asset` run), without calling any generation API again. Takes
  plain file paths, not `--assets-dir`/asset id — no asset-spec/JSON
  knowledge involved. Free and fully offline — no network calls at all —
  so it's safe to re-run repeatedly while tuning the `CHROMA_KEY_*`
  constants at the top of `clean-image.ts`. Fails if `--input` doesn't
  exist; a `.raw` file only exists for an asset whose generation actually
  needed chroma-key cleanup in the first place (see below) — there's
  nothing to re-clean for others.
- **`list_models --assets-dir <absolute-path> <asset-id>`** — human-facing
  landscape view. Estimates a real dollar cost for every OpenRouter Images
  API model/provider endpoint that can actually serve that asset's spec +
  prompt, prints everything sorted cheapest-first, plus a feature-support
  tally and a bucket for endpoints with no published pricing (not free,
  just unpriced — excluded from ranking but still shown). Unauthenticated,
  free to run.
- **`pick_model --assets-dir <absolute-path> <asset-id>`** — CLI preview
  of the same selection algorithm `generate_asset` uses internally (see
  `selectImageModel()` in `pick-image-model.ts`), without spending on an
  actual generation. Also unauthenticated, free to run.

## Auth

`generate_asset` needs an OpenRouter API key: `git config
openrouter.imagenapikey`. **`image-generation.sh` is the only thing in
this package that knows anything about git** — for the `generate_asset`
subcommand specifically, it resolves the key via `git -C <caller-dir>
config --get openrouter.imagenapikey` (caller's directory, not this
package's own — git itself walks up from there to find the nearest
`.git`, exactly like any other git command) and passes it to
`generate-asset.ts` as a plain `--key=<value>` flag. `generate-asset.ts`
itself has no git/config knowledge at all — it just takes whatever `--key`
value it's given and uses it. This package has no opinion on workspace
layout: run it from a plain standalone repo, a submodule, or an outer
workspace root that holds the key on behalf of several submodules —
whichever repo your cwd is inside when you invoke it is where the key
must be configured. Fails loudly, with the directory it looked in, if
it's unset — never searches anywhere else or falls back to a default.
(`list_models`/`pick_model` never need a key at all — OpenRouter's
model/endpoint discovery endpoints they call are unauthenticated.)

## Architecture

Four layers, each with one job:

- **`model/types.ts`** — pure data. `ParamSpec`/`PricingLine` (OpenRouter's
  own wire shapes) and `Model` (one model×provider endpoint, flattened —
  what `fetchModels()` returns a list of). No logic lives here at all.
- **`clients/open-router.ts`** — the only file that talks to OpenRouter.
  `fetchModels()`/`fetchModelEndpoints()` for discovery (unauthenticated),
  `generateImage(model, spec, apiKey)` for the real generation request.
  Owns converting values *our* way into whatever *that specific model's*
  wire format expects (see Resolution format below) — everything upstream
  of this file only ever deals in our own vocabulary.
- **`asset-adjuster.ts`** — `adjust(spec, model)` is the single place that
  decides whether a model can serve a spec at all, and if so, returns a
  spec adjusted to what it actually supports: `minResolution` substituted
  for the cheapest tier the model actually declares, and — when the model
  can't natively render transparency — `background` downgraded to
  `"opaque"` with the chroma-key clause appended to `promptText`. Returns
  `null` when nothing here makes the model usable (unsupported aspect
  ratio, or no resolution tier meets the floor). `supportsBackground()`/
  `supportsAspectRatio()`/`pickResolutionTier()` live here too, exported
  only for independent unit testing — every real caller in this package
  goes through `adjust()`, never these directly.
  `shouldCleanupImage(original, adjusted)` compares an `adjust()`
  input/output pair to tell whether a fallback workaround got applied
  (currently: did `background` get downgraded from `"transparent"`) —
  generalizes to any future field `adjust()` might override.
- **`image-cost-estimate.ts`** — `estimateCost(model, adjustedSpec)`, pure
  math, no network/fs. Takes an *already-adjusted* spec (see Model
  selection below for why that matters) and a model's pricing lines and
  estimates a dollar cost.

`list-image-models.ts`'s `listModels()` composes the last three: fetch →
`adjust()` (excludes unsupported models, `null` → dropped) → `estimateCost()`
on the adjusted spec → sorted list. `pick-image-model.ts`'s
`selectImageModel()` calls `listModels()` and adds the percentile-cutoff +
random pick on top (see Model selection). `generate-asset.ts` calls
`selectImageModel()`, then **re-fetches that specific picked model fresh**
(`fetchModelEndpoints()`) and calls `adjust()` again itself, right before
spending — never trusting bulk-list data that could be stale by then —
before finally calling `generateImage()`.

## Input model

Every layer above works against one shared entity,
`ImageGenerationRequirements` (`image-generation-requirements.ts`) — what
asset to generate, in this toolkit's own provider-agnostic vocabulary.
This is the officially supported input shape; nothing in this package
accepts anything else.

Each library function accepts that entity two ways:

- **Folder + asset id** — `readImageGenerationRequirements(assetsDir,
  assetId)` parses it off disk (what every subcommand's `main()` does):
  the id's `.json` file for the structural fields below, plus its
  `.prompt.txt` for `promptText`. `assetsDir` must be an absolute path —
  this function fails loudly if it isn't, rather than guessing what a
  relative one would be relative to.
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

- `destination` — output file path, resolved relative to `--assets-dir`
  (the directory containing this JSON file itself), not to any caller
  context — `readImageGenerationRequirements` resolves it to an absolute
  path immediately when parsing. Its extension is also the output format
  (`.png`/`.jpg`/`.jpeg`).
- `aspectRatio` — optional; one of `1:1`, `3:2`, `2:3`, `3:4`, `4:3`,
  `4:5`, `5:4`, `9:16`, `16:9`, `21:9`. Omit when no aspect ratio actually
  matters for the asset (CSS force-stretches it regardless, or too few
  Images API models support the ratio you'd otherwise want — check with
  `list_models`).
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

## Model selection

There's no auto-router on OpenRouter's Images API (unlike the general
chat-completions endpoint's `"openrouter/auto"`) — every request needs a
concrete model slug. `selectImageModel()` in `pick-image-model.ts` picks
one:

1. `listModels()` fetches every model×provider endpoint and runs
   `adjust()` against each — anything `adjust()` returns `null` for
   (unsupported aspect ratio, or no resolution tier meets the floor) is
   excluded entirely; everything else gets costed via `estimateCost()`
   against its *adjusted* spec, not the raw requested one (this is what
   makes cost estimation correct when a model's cheapest qualifying
   resolution sits above the asset's floor — the estimate reflects what
   will actually be requested, not just the floor).
2. Compute the **30th-percentile** price (not the mean) of the
   cost-complete candidates, add a 10% margin, and drop everything priced
   above that threshold — keeps a mid/cheap band, excludes the expensive
   tail.
3. Pick uniformly at random from what remains, so repeated runs spread
   across providers instead of always hitting the single cheapest one.

Cost estimation (`image-cost-estimate.ts`) handles OpenRouter's three
output-pricing shapes: flat per-image (`unit: "image"`, optionally
per-resolution-`variant`), per-megapixel (`unit: "megapixel"`), and
per-token (`unit: "token"`, using the general ViT patch-tokenization
estimate `N = (H×W)/P²` — deliberately not a hardcoded per-vendor token
table, since none of that is exposed by the API and vendor docs go stale;
calibrated against real recorded generations, see
`image-cost-estimate.test.ts` and `PATCH_SIZE_PX`'s own comment for the
numbers).

`background` is never a hard filter — a model's transparency support only
ever changes what `adjust()` returns (native `"transparent"` passed
through, or downgraded to `"opaque"` + chroma-key clause), never whether
the model is considered at all.

## Resolution format

OpenRouter's declared `resolution` values mix API shapes — real data has
shown the smallest tier spelled `"512"` (a bare pixel number) rather than
our own `"0.5K"`, while `"1K"`/`"2K"`/`"4K"` have so far always appeared
spelled identically to our own vocabulary. `Model.supported_parameters`
keeps whatever OpenRouter actually returned, unconverted — the two files
that need to reason about that raw spelling each own their own small,
deliberately duplicated rank table rather than sharing one:

- `asset-adjuster.ts` compares a model's raw declared values against our
  floor to decide support and picks the cheapest qualifying tier — but
  always resolves to one of **our own** four tier names. The adjusted
  spec never contains a raw provider string.
- `clients/open-router.ts`'s `generateImage()` does the reverse: given our
  tier name from the adjusted spec and *that specific model's* raw
  declared enum, it finds the matching literal wire value to actually
  send.

## Transparency

Two independent halves:

- **The prompt-side ask** (`asset-adjuster.ts`): when an asset needs
  transparency but the model picked for this request can't natively
  deliver it, `adjust()` appends an extra clause
  (`CHROMA_KEY_BACKGROUND_CLAUSE`) to the prompt asking for a flat solid
  magenta (`#FF00FF`) background instead — pick a project palette where
  magenta never legitimately appears, so it's safe to key out without
  clipping real image content.
- **The pixel-side cleanup** (`clean-image.ts`): turns that magenta
  background into real alpha. Both a library function (`generate-
  asset.ts` calls `cleanImage()` directly right after a generation that
  needed it) and its own standalone subcommand (see Tools above). Works
  *only* on `.raw` files, and a `.raw` file only ever exists for an asset
  whose original generation actually needed chroma-key cleanup — an asset
  whose picked model supports native `background: "transparent"`, or
  whose spec has `"background": "opaque"`, writes its final image
  directly and caches no raw at all, since a pure format re-encode has
  nothing worth caching for a later re-clean pass.

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
