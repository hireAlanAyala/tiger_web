#!/usr/bin/env -S npx tsx
// focus-codegen — reads scanner manifest and generates handler dispatch code.
//
// Usage: focus-codegen <manifest.json> <output.ts> [operations.json] [operations.ts]
// Called by the .focus build hook.

import { runCodegen } from "../codegen.ts";

const manifestPath = process.argv[2];
const outputPath = process.argv[3];
const opsRegistryPath = process.argv[4];
const opsOutputPath = process.argv[5];

if (!manifestPath || !outputPath) {
  console.error("Usage: focus-codegen <manifest.json> <output.ts> [operations.json] [operations.ts]");
  process.exit(1);
}

runCodegen({ manifestPath, outputPath, opsRegistryPath, opsOutputPath });
