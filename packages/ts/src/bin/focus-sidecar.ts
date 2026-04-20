#!/usr/bin/env -S npx tsx
// focus-sidecar — loads generated handler registry and starts the SHM sidecar.
//
// Usage: focus-sidecar <shm-name> <socket-path>
// Called by the .focus start hook: start = npx focus-sidecar $SHM $SOCK

import { resolve } from "path";
import { createSidecar } from "../sidecar.ts";

const shmName = process.argv[2];
const sockPath = process.argv[3];

if (!shmName) {
  console.error("Usage: focus-sidecar <shm-name> <socket-path>");
  process.exit(1);
}

// Load the user's generated handler registry.
const genPath = resolve(process.cwd(), "focus/handlers.generated.ts");

try {
  const gen = await import(genPath);
  createSidecar(shmName, sockPath, {
    modules: gen.modules,
    routeTable: gen.routeTable,
    prefetchKeyMap: gen.prefetchKeyMap,
    OperationValues: gen.OperationValues,
    workerFunctions: gen.workerFunctions,
  });
} catch (e: any) {
  if (e.code === "ERR_MODULE_NOT_FOUND" || e.code === "MODULE_NOT_FOUND") {
    console.error(`error: ${genPath} not found — run 'focus build' first`);
  } else {
    console.error(`error: failed to load handlers: ${e.message}`);
  }
  process.exit(1);
}
