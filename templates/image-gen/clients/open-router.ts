import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import type { ImageGenerationRequirements } from "../image-generation-requirements";
import type { Model, ParamSpec, PricingLine } from "../model/types";

const IMAGES_MODELS_URL = "https://openrouter.ai/api/v1/images/models";
const IMAGES_URL = "https://openrouter.ai/api/v1/images";

interface RawEndpoint {
  provider_name: string;
  supported_parameters?: Record<string, ParamSpec>;
  pricing: PricingLine[];
}

async function fetchModelIds(): Promise<{ id: string }[]> {
  const response = await fetch(IMAGES_MODELS_URL);
  if (!response.ok) {
    throw new Error(`Failed to list models: ${response.status} ${response.statusText}`);
  }
  return (await response.json()).data;
}

async function fetchRawEndpoints(modelId: string): Promise<RawEndpoint[]> {
  const response = await fetch(`${IMAGES_MODELS_URL}/${modelId}/endpoints`);
  if (!response.ok) {
    throw new Error(`Failed to fetch endpoints for ${modelId}: ${response.status} ${response.statusText}`);
  }
  return (await response.json()).endpoints;
}

function flattenModels(modelIds: { id: string }[], endpointLists: RawEndpoint[][]): Model[] {
  const models: Model[] = [];
  modelIds.forEach((m, i) => {
    for (const raw of endpointLists[i]) {
      models.push({ modelId: m.id, provider: raw.provider_name, supported_parameters: raw.supported_parameters, pricing: raw.pricing });
    }
  });
  return models;
}

// Every model×provider endpoint across OpenRouter's whole Images API
// catalog — unauthenticated, free to call. supported_parameters/pricing
// are returned exactly as OpenRouter reported them, no format conversion
// (see asset-adjuster.ts and generateImage() below for where that
// happens, in each direction).
export async function fetchModels(): Promise<Model[]> {
  const modelIds = await fetchModelIds();
  const endpointLists = await Promise.all(modelIds.map((m) => fetchRawEndpoints(m.id)));
  return flattenModels(modelIds, endpointLists);
}

// Just one model's own endpoints — for re-checking a specific picked
// model fresh right before spending on a real generation, instead of
// trusting bulk-list data that could be stale by then.
export async function fetchModelEndpoints(modelId: string): Promise<Model[]> {
  const endpoints = await fetchRawEndpoints(modelId);
  return flattenModels([{ id: modelId }], [endpoints]);
}

function outputFormat(destination: string): "png" | "jpeg" {
  const ext = extname(destination).toLowerCase();
  if (ext === ".png") return "png";
  if (ext === ".jpg" || ext === ".jpeg") return "jpeg";
  throw new Error(`Unsupported destination extension for output format: ${ext}`);
}

function mimeTypeFor(filePath: string): string {
  const ext = extname(filePath).toLowerCase();
  if (ext === ".png") return "image/png";
  if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
  if (ext === ".webp") return "image/webp";
  if (ext === ".gif") return "image/gif";
  return "image/png";
}

// Our tier name -> this specific model's own literal wire spelling.
// Deliberately duplicated from asset-adjuster.ts's own rank table (see
// its comment for why) rather than shared — the two serve opposite
// directions and the table is tiny.
const RESOLUTION_RANK: Record<string, number> = { "512": 0, "0.5K": 0, "1K": 1, "2K": 2, "4K": 3 };

function resolutionValueFor(model: Model, tier: ImageGenerationRequirements["minResolution"]): string | undefined {
  const declared = model.supported_parameters?.resolution?.values;
  if (!declared) return undefined;
  const wantedRank = RESOLUTION_RANK[tier];
  return declared.find((v) => RESOLUTION_RANK[v] === wantedRank);
}

// spec must already be adjusted (asset-adjuster.ts's adjust()) against
// this exact model — this only converts field values into OpenRouter's
// wire format, it doesn't check support itself.
export async function generateImage(model: Model, spec: ImageGenerationRequirements, apiKey: string): Promise<Buffer> {
  const body: Record<string, any> = {
    model: model.modelId,
    prompt: spec.promptText,
    resolution: resolutionValueFor(model, spec.minResolution),
    aspect_ratio: spec.aspectRatio,
    background: spec.background === "transparent" ? "transparent" : undefined,
    output_format: outputFormat(spec.destination),
  };

  if (spec.mockImage) {
    const fileBytes = await readFile(spec.mockImage.path);
    const mime = mimeTypeFor(spec.mockImage.path);
    const dataUrl = `data:${mime};base64,${fileBytes.toString("base64")}`;
    body.input_images = [dataUrl];
    body.image = dataUrl;
  }

  const response = await fetch(IMAGES_URL, {
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

  return Buffer.from(b64Json, "base64");
}
