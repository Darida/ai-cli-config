import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

// Without this, vite-node (which has no config file to anchor it) walks
// up from cwd looking for a workspace root and can land on an outer git
// repo this package happens to be nested inside (ai-cli-config, or a
// workspace beyond that) instead of this directory — which then breaks
// dependency resolution for anything not hoisted to that outer root's
// node_modules (observed: sharp, a native/CJS-only package, failed to
// resolve at all — "Failed to load url sharp"). Pinning root here stops
// that walk.
export default defineConfig({
  root: dirname(fileURLToPath(import.meta.url)),
});
