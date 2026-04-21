// Shared memory sidecar client — reads CALL frames from shared memory,
// writes RESULT frames back. All SHM I/O, CRC, frame parsing, and
// response writing happens in C (pollDispatch). JS only runs handlers.

import { createRequire } from "node:module";

// Native addon must use require — Node.js doesn't support import for .node files.
// Platform detection follows TigerBeetle's index.ts pattern:
// focus binary extracts to native/shm.node (flat path), npm distribution
// uses native/dist/{arch}-{os}/shm.node (platform subdirectory).
const require_ = createRequire(import.meta.url);
const shmAddon = (() => {
  try {
    // Focus binary extracts the correct platform binary to this flat path.
    return require_("../native/shm.node");
  } catch {
    // npm distribution: platform-specific subdirectory.
    const archMap: Record<string, string> = { "arm64": "aarch64", "x64": "x86_64" };
    const platformMap: Record<string, string> = { "linux": "linux", "darwin": "macos" };
    const arch = archMap[process.arch];
    const platform = platformMap[process.platform];
    if (!arch || !platform) throw new Error(`Unsupported platform: ${process.arch}-${process.platform}`);
    return require_(`../native/dist/${arch}-${platform}/shm.node`);
  }
})();

export interface ShmClientOptions {
  shmName: string;
  slotCount: number;
  slotDataSize: number;
}

const REGION_HEADER_SIZE = 64;
const SLOT_HEADER_SIZE = 64;

export class ShmClient {
  private buf: Buffer;
  private slotCount: number;
  private slotDataSize: number;
  private slotPairSize: number;
  private lastSeenSeqs: Uint32Array;
  // Handler receives pre-parsed fields: (slotIndex, funcIndex, requestId, argsBuffer)
  // funcIndex: 0=route, 1=prefetch, 2=handle, 3=render, 4=handle_render
  // Must return Uint8Array with the RESULT frame payload.
  private onDispatch: ((slotIndex: number, funcIndex: number, requestId: number, args: Buffer) => Uint8Array) | null = null;

  constructor(opts: ShmClientOptions) {
    this.slotCount = opts.slotCount;
    this.slotDataSize = opts.slotDataSize;
    this.slotPairSize = SLOT_HEADER_SIZE + this.slotDataSize * 2;

    const regionSize = REGION_HEADER_SIZE + this.slotCount * this.slotPairSize;
    const shmPath = opts.shmName.startsWith("/") ? opts.shmName : "/" + opts.shmName;
    this.buf = shmAddon.mmapShm(shmPath, regionSize);
    this.lastSeenSeqs = new Uint32Array(this.slotCount);

    console.log(`[shm] mapped ${opts.shmName}: ${regionSize} bytes, ${this.slotCount} slots`);
  }

  /// Open an SHM region and read slot_count + frame_max from the header.
  /// No hardcoded constants needed — the server writes these at init.
  static open(shmName: string): ShmClient {
    // First map just the header to read slot_count and frame_max.
    const shmPath = shmName.startsWith("/") ? shmName : "/" + shmName;
    const headerBuf: Buffer = shmAddon.mmapShm(shmPath, REGION_HEADER_SIZE);
    const slotCount = headerBuf.readUInt16LE(0);   // RegionHeader.slot_count @ offset 0.
    const frameMax = headerBuf.readUInt32LE(4);     // RegionHeader.frame_max @ offset 4.
    // Unmap the header-only mapping — we'll remap the full region.
    // (Node Buffer from mmap stays valid; we just need the values.)
    return new ShmClient({ shmName, slotCount, slotDataSize: frameMax });
  }

  setDispatchHandler(handler: (slotIndex: number, funcIndex: number, requestId: number, args: Buffer) => Uint8Array) {
    this.onDispatch = handler;
  }

  // Native poll+dispatch+respond — all in C. JS only runs the handler.
  poll(): number {
    if (!this.onDispatch) return 0;
    return shmAddon.pollDispatch(
      this.buf,
      this.slotCount,
      this.slotPairSize,
      REGION_HEADER_SIZE,
      this.slotDataSize,
      this.lastSeenSeqs,
      this.onDispatch,
    );
  }

  startPolling(): void {
    // Adaptive polling: poll aggressively (setImmediate) when active,
    // back off to 1ms setTimeout when idle. Prevents 100% CPU at idle
    // while maintaining low latency under load.
    //
    // Transition: active → idle after 1000 idle ticks (~10ms of no work).
    // Transition: idle → active on first dispatched frame.
    let idleTicks = 0;
    const IDLE_THRESHOLD = 1000; // ticks with no work before backing off

    const activeTick = () => {
      const dispatched = this.poll();
      if (dispatched > 0) {
        idleTicks = 0;
        setImmediate(activeTick);
      } else {
        idleTicks++;
        if (idleTicks >= IDLE_THRESHOLD) {
          idleTick();
        } else {
          setImmediate(activeTick);
        }
      }
    };

    const idleTick = () => {
      const dispatched = this.poll();
      if (dispatched > 0) {
        idleTicks = 0;
        setImmediate(activeTick);
      } else {
        setTimeout(idleTick, 1);
      }
    };

    setImmediate(activeTick);
  }

}
