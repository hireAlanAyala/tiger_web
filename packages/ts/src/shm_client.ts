// Shared memory sidecar client — reads CALL frames from shared memory,
// writes RESULT frames back. All SHM I/O, CRC, frame parsing, and
// response writing happens in C (pollDispatch). JS only runs handlers.

import { createRequire } from "node:module";

// Native addon must use require — Node.js doesn't support import for .node files.
const require_ = createRequire(import.meta.url);
const shmAddon = require_("../native/shm.node");

export interface ShmClientOptions {
  shmName: string;
  slotCount: number;
  slotDataSize: number;
}

const REGION_HEADER_SIZE = 64;
const EPOCH_OFFSET = 0;
const SIDECAR_POLLING_OFFSET = 12; // RegionHeader.sidecar_polling — u32 LE at offset 12.
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
    const slotCount = headerBuf.readUInt16LE(4);   // RegionHeader.slot_count @ offset 4.
    const frameMax = headerBuf.readUInt32LE(8);     // RegionHeader.frame_max @ offset 8.
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

  // Write response to SHM slot. Used by 2-RT path where the server
  // (not the C addon) triggers the response write.
  writeResponse(slot: number, data: Uint8Array): void {
    const hdr = REGION_HEADER_SIZE + slot * this.slotPairSize;
    const respOffset = hdr + SLOT_HEADER_SIZE + this.slotDataSize;
    if (data.length > 0) this.buf.set(data, respOffset);
    this.buf.writeUInt32LE(data.length, hdr + 12);
    // CRC skipped in legacy path — pollDispatch handles CRC in C.
    this.buf.writeUInt32LE(0, hdr + 20);
    const curSeq = this.buf.readUInt32LE(hdr + 4);
    this.buf.writeUInt32LE(curSeq + 1, hdr + 4);
    shmAddon.futexWake(this.buf, hdr + 4);
  }

  startPolling(): void {
    // Signal the server: we're actively polling, no futex_wake needed.
    // Offset 12 in region header = sidecar_polling flag.
    // NOTE: once set, never transitions back to 0. The sidecar polls
    // for the entire process lifetime. If adaptive idle/active transitions
    // are needed in the future, add a tick counter that clears the flag
    // after N idle ticks and calls startWaiting().
    this.buf.writeUInt32LE(1, SIDECAR_POLLING_OFFSET);
    const tick = () => { this.poll(); setImmediate(tick); };
    setImmediate(tick);
  }

  startWaiting(): void {
    // Signal the server: we're in futex_wait, futex_wake is needed.
    this.buf.writeUInt32LE(0, SIDECAR_POLLING_OFFSET);
    let lastEpoch = this.buf.readUInt32LE(EPOCH_OFFSET);
    while (true) {
      lastEpoch = shmAddon.spinWait(this.buf, EPOCH_OFFSET, lastEpoch, 100000);
      this.poll();
    }
  }
}
