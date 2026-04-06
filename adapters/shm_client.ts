// Shared memory sidecar client — reads CALL frames from shared memory,
// writes RESULT frames back. Signals via futex_wake.
//
// Replaces the unix socket transport in call_runtime_v2.ts.
// Same dispatch logic, different transport.
//
// Usage: import { ShmClient } from './shm_client';

// Built with: cd addons/shm && npm run build (uses zig cc, no node-gyp).
const shmAddon = require("../addons/shm/shm.node");

import { crc32 } from "node:zlib";

export interface ShmClientOptions {
  shmName: string;
  slotCount: number;
  slotDataSize: number; // frame_max
}

// Layout matches shm_bus.zig SlotHeader (64 bytes).
const HEADER_SIZE = 64;
const SERVER_SEQ_OFFSET = 0;
const SIDECAR_SEQ_OFFSET = 4;
const REQUEST_LEN_OFFSET = 8;
const RESPONSE_LEN_OFFSET = 12;
const REQUEST_CRC_OFFSET = 16;
const RESPONSE_CRC_OFFSET = 20;

export class ShmClient {
  private buf: Buffer;
  private slotCount: number;
  private slotDataSize: number;
  private slotPairSize: number;
  private lastSeenSeqs: Uint32Array;
  private onFrame: ((slotIndex: number, data: Buffer) => void) | null = null;

  constructor(opts: ShmClientOptions) {
    this.slotCount = opts.slotCount;
    this.slotDataSize = opts.slotDataSize;
    this.slotPairSize = HEADER_SIZE + this.slotDataSize * 2;

    const regionSize = this.slotCount * this.slotPairSize;
    this.buf = shmAddon.mmapShm(opts.shmName, regionSize);
    this.lastSeenSeqs = new Uint32Array(this.slotCount);

    console.log(`[shm] mapped ${opts.shmName}: ${regionSize} bytes, ${this.slotCount} slots`);
  }

  setFrameHandler(handler: (slotIndex: number, data: Buffer) => void) {
    this.onFrame = handler;
  }

  // Slot offsets.
  private headerOffset(slot: number): number { return slot * this.slotPairSize; }
  private requestOffset(slot: number): number { return this.headerOffset(slot) + HEADER_SIZE; }
  private responseOffset(slot: number): number { return this.requestOffset(slot) + this.slotDataSize; }

  // Read a u32 BE from the buffer.
  private readU32(offset: number): number { return this.buf.readUInt32BE(offset); }
  private writeU32(offset: number, val: number): void { this.buf.writeUInt32BE(val, offset); }

  // Poll all slots for new requests. Returns number of requests found.
  poll(): number {
    let found = 0;
    for (let i = 0; i < this.slotCount; i++) {
      const hdr = this.headerOffset(i);
      const serverSeq = this.readU32(hdr + SERVER_SEQ_OFFSET);

      if (serverSeq > this.lastSeenSeqs[i]) {
        this.lastSeenSeqs[i] = serverSeq;

        // Read request.
        const requestLen = this.readU32(hdr + REQUEST_LEN_OFFSET);
        if (requestLen > this.slotDataSize) continue;

        // Validate CRC (len ++ payload).
        const storedCrc = this.readU32(hdr + REQUEST_CRC_OFFSET);
        const lenBuf = Buffer.alloc(4);
        lenBuf.writeUInt32BE(requestLen, 0);
        const crcLen = crc32(lenBuf);
        const payload = this.buf.subarray(this.requestOffset(i), this.requestOffset(i) + requestLen);
        const computedCrc = requestLen > 0 ? crc32(payload, crcLen) : crcLen;
        if ((computedCrc >>> 0) !== (storedCrc >>> 0)) {
          console.error(`[shm] CRC mismatch on slot ${i}`);
          continue;
        }

        // Deliver to handler.
        if (this.onFrame) {
          this.onFrame(i, payload);
        }
        found++;
      }
    }
    return found;
  }

  // Write a response to a slot and signal the server.
  writeResponse(slot: number, data: Uint8Array): void {
    const hdr = this.headerOffset(slot);
    const respOffset = this.responseOffset(slot);

    // Write payload.
    if (data.length > 0) {
      this.buf.set(data, respOffset);
    }

    // CRC covers len ++ payload.
    const lenBuf = Buffer.alloc(4);
    lenBuf.writeUInt32BE(data.length, 0);
    const crcLen = crc32(lenBuf);
    const computedCrc = data.length > 0
      ? crc32(Buffer.from(data), crcLen)
      : crcLen;

    // Update header: length, CRC, then seq.
    this.writeU32(hdr + RESPONSE_LEN_OFFSET, data.length);
    this.writeU32(hdr + RESPONSE_CRC_OFFSET, computedCrc >>> 0);

    // Increment sidecar_seq (release ordering via write order).
    const currentSeq = this.readU32(hdr + SIDECAR_SEQ_OFFSET);
    this.writeU32(hdr + SIDECAR_SEQ_OFFSET, currentSeq + 1);

    // Wake server's futex wait on sidecar_seq.
    shmAddon.futexWake(this.buf, hdr + SIDECAR_SEQ_OFFSET);
  }

  // Start tight polling loop via setImmediate. Checks for new
  // requests every event loop iteration (~0.1ms, much faster than
  // setInterval's ~1ms minimum). For production, replace with
  // futex_wait for near-zero latency.
  startPolling(): void {
    const tick = () => {
      this.poll();
      setImmediate(tick);
    };
    setImmediate(tick);
  }
}
