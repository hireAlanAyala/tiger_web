// Shared memory sidecar client — reads CALL frames from shared memory,
// writes RESULT frames back. Signals via futex.

const shmAddon = require("../addons/shm/shm.node");
import { crc32 } from "node:zlib";

export interface ShmClientOptions {
  shmName: string;
  slotCount: number;
  slotDataSize: number;
  skipCrc?: boolean;
}

const REGION_HEADER_SIZE = 64;
const EPOCH_OFFSET = 0;

const SLOT_HEADER_SIZE = 64;
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
  private skipCrc: boolean;
  private crcBuf = Buffer.alloc(4);
  private onFrame: ((slotIndex: number, data: Buffer) => void) | null = null;

  constructor(opts: ShmClientOptions) {
    this.slotCount = opts.slotCount;
    this.slotDataSize = opts.slotDataSize;
    this.slotPairSize = SLOT_HEADER_SIZE + this.slotDataSize * 2;
    this.skipCrc = opts.skipCrc ?? false;

    const regionSize = REGION_HEADER_SIZE + this.slotCount * this.slotPairSize;
    const shmPath = opts.shmName.startsWith("/") ? opts.shmName : "/" + opts.shmName;
    this.buf = shmAddon.mmapShm(shmPath, regionSize);
    this.lastSeenSeqs = new Uint32Array(this.slotCount);

    console.log(`[shm] mapped ${opts.shmName}: ${regionSize} bytes, ${this.slotCount} slots${this.skipCrc ? " (no-crc)" : ""}`);
  }

  setFrameHandler(handler: (slotIndex: number, data: Buffer) => void) {
    this.onFrame = handler;
  }

  private headerOffset(slot: number): number { return REGION_HEADER_SIZE + slot * this.slotPairSize; }
  private requestOffset(slot: number): number { return this.headerOffset(slot) + SLOT_HEADER_SIZE; }
  private responseOffset(slot: number): number { return this.requestOffset(slot) + this.slotDataSize; }
  private readU32(offset: number): number { return this.buf.readUInt32LE(offset); }
  private writeU32(offset: number, val: number): void { this.buf.writeUInt32LE(val, offset); }

  poll(): number {
    let found = 0;
    for (let i = 0; i < this.slotCount; i++) {
      const hdr = this.headerOffset(i);
      const serverSeq = this.readU32(hdr + SERVER_SEQ_OFFSET);

      if (serverSeq > this.lastSeenSeqs[i]) {
        this.lastSeenSeqs[i] = serverSeq;
        const requestLen = this.readU32(hdr + REQUEST_LEN_OFFSET);
        if (requestLen > this.slotDataSize) continue;

        const payload = this.buf.subarray(this.requestOffset(i), this.requestOffset(i) + requestLen);

        if (!this.skipCrc) {
          const storedCrc = this.readU32(hdr + REQUEST_CRC_OFFSET);
          this.crcBuf.writeUInt32LE(requestLen, 0);
          const crcLen = crc32(this.crcBuf);
          const computedCrc = requestLen > 0 ? crc32(payload, crcLen) : crcLen;
          if ((computedCrc >>> 0) !== (storedCrc >>> 0)) {
            console.error(`[shm] CRC mismatch on slot ${i}`);
            continue;
          }
        }

        if (this.onFrame) this.onFrame(i, payload);
        found++;
      }
    }
    return found;
  }

  writeResponse(slot: number, data: Uint8Array): void {
    const hdr = this.headerOffset(slot);
    const respOffset = this.responseOffset(slot);

    if (data.length > 0) this.buf.set(data, respOffset);

    this.writeU32(hdr + RESPONSE_LEN_OFFSET, data.length);

    if (!this.skipCrc) {
      this.crcBuf.writeUInt32LE(data.length, 0);
      const crcLen = crc32(this.crcBuf);
      const computedCrc = data.length > 0 ? crc32(Buffer.from(data), crcLen) : crcLen;
      this.writeU32(hdr + RESPONSE_CRC_OFFSET, computedCrc >>> 0);
    } else {
      this.writeU32(hdr + RESPONSE_CRC_OFFSET, 0);
    }

    const currentSeq = this.readU32(hdr + SIDECAR_SEQ_OFFSET);
    this.writeU32(hdr + SIDECAR_SEQ_OFFSET, currentSeq + 1);
    shmAddon.futexWake(this.buf, hdr + SIDECAR_SEQ_OFFSET);
  }

  startWaiting(): void {
    let lastEpoch = this.readU32(EPOCH_OFFSET);
    while (true) {
      lastEpoch = shmAddon.spinWait(this.buf, EPOCH_OFFSET, lastEpoch, 100000);
      this.poll();
    }
  }

  startPolling(): void {
    const tick = () => { this.poll(); setImmediate(tick); };
    setImmediate(tick);
  }
}
