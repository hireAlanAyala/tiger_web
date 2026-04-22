// Minimal N-API addon: mmap shared memory + poll/dispatch/respond.
// All SHM I/O, CRC validation, frame parsing, response writing,
// and seq bumps happen in C. JS only runs handler logic.
//
// Cross-platform: uses only POSIX (shm_open, mmap) and atomics.
// No futex — both sides busy-poll.

#include <node_api.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Self-contained CRC32 (IEEE 802.3 / ISO-HDLC, polynomial 0xEDB88320).
// Same algorithm as zlib's crc32() and Zig's std.hash.crc.Crc32.
// Eliminates the -lz dependency for cross-compilation.
static const uint32_t crc32_table[256] = {
  0x00000000,0x77073096,0xEE0E612C,0x990951BA,0x076DC419,0x706AF48F,0xE963A535,0x9E6495A3,
  0x0EDB8832,0x79DCB8A4,0xE0D5E91E,0x97D2D988,0x09B64C2B,0x7EB17CBD,0xE7B82D07,0x90BF1D91,
  0x1DB71064,0x6AB020F2,0xF3B97148,0x84BE41DE,0x1ADAD47D,0x6DDDE4EB,0xF4D4B551,0x83D385C7,
  0x136C9856,0x646BA8C0,0xFD62F97A,0x8A65C9EC,0x14015C4F,0x63066CD9,0xFA0F3D63,0x8D080DF5,
  0x3B6E20C8,0x4C69105E,0xD56041E4,0xA2677172,0x3C03E4D1,0x4B04D447,0xD20D85FD,0xA50AB56B,
  0x35B5A8FA,0x42B2986C,0xDBBBC9D6,0xACBCF940,0x32D86CE3,0x45DF5C75,0xDCD60DCF,0xABD13D59,
  0x26D930AC,0x51DE003A,0xC8D75180,0xBFD06116,0x21B4F4B5,0x56B3C423,0xCFBA9599,0xB8BDA50F,
  0x2802B89E,0x5F058808,0xC60CD9B2,0xB10BE924,0x2F6F7C87,0x58684C11,0xC1611DAB,0xB6662D3D,
  0x76DC4190,0x01DB7106,0x98D220BC,0xEFD5102A,0x71B18589,0x06B6B51F,0x9FBFE4A5,0xE8B8D433,
  0x7807C9A2,0x0F00F934,0x9609A88E,0xE10E9818,0x7F6A0DBB,0x086D3D2D,0x91646C97,0xE6635C01,
  0x6B6B51F4,0x1C6C6162,0x856530D8,0xF262004E,0x6C0695ED,0x1B01A57B,0x8208F4C1,0xF50FC457,
  0x65B0D9C6,0x12B7E950,0x8BBEB8EA,0xFCB9887C,0x62DD1DDF,0x15DA2D49,0x8CD37CF3,0xFBD44C65,
  0x4DB26158,0x3AB551CE,0xA3BC0074,0xD4BB30E2,0x4ADFA541,0x3DD895D7,0xA4D1C46D,0xD3D6F4FB,
  0x4369E96A,0x346ED9FC,0xAD678846,0xDA60B8D0,0x44042D73,0x33031DE5,0xAA0A4C5F,0xDD0D7CC9,
  0x5005713C,0x270241AA,0xBE0B1010,0xC90C2086,0x5768B525,0x206F85B3,0xB966D409,0xCE61E49F,
  0x5EDEF90E,0x29D9C998,0xB0D09822,0xC7D7A8B4,0x59B33D17,0x2EB40D81,0xB7BD5C3B,0xC0BA6CAD,
  0xEDB88320,0x9ABFB3B6,0x03B6E20C,0x74B1D29A,0xEAD54739,0x9DD277AF,0x04DB2615,0x73DC1683,
  0xE3630B12,0x94643B84,0x0D6D6A3E,0x7A6A5AA8,0xE40ECF0B,0x9309FF9D,0x0A00AE27,0x7D079EB1,
  0xF00F9344,0x8708A3D2,0x1E01F268,0x6906C2FE,0xF762575D,0x806567CB,0x196C3671,0x6E6B06E7,
  0xFED41B76,0x89D32BE0,0x10DA7A5A,0x67DD4ACC,0xF9B9DF6F,0x8EBEEFF9,0x17B7BE43,0x60B08ED5,
  0xD6D6A3E8,0xA1D1937E,0x38D8C2C4,0x4FDFF252,0xD1BB67F1,0xA6BC5767,0x3FB506DD,0x48B2364B,
  0xD80D2BDA,0xAF0A1B4C,0x36034AF6,0x41047A60,0xDF60EFC3,0xA867DF55,0x316E8EEF,0x4669BE79,
  0xCB61B38C,0xBC66831A,0x256FD2A0,0x5268E236,0xCC0C7795,0xBB0B4703,0x220216B9,0x5505262F,
  0xC5BA3BBE,0xB2BD0B28,0x2BB45A92,0x5CB36A04,0xC2D7FFA7,0xB5D0CF31,0x2CD99E8B,0x5BDEAE1D,
  0x9B64C2B0,0xEC63F226,0x756AA39C,0x026D930A,0x9C0906A9,0xEB0E363F,0x72076785,0x05005713,
  0x95BF4A82,0xE2B87A14,0x7BB12BAE,0x0CB61B38,0x92D28E9B,0xE5D5BE0D,0x7CDCEFB7,0x0BDBDF21,
  0x86D3D2D4,0xF1D4E242,0x68DDB3F8,0x1FDA836E,0x81BE16CD,0xF6B9265B,0x6FB077E1,0x18B74777,
  0x88085AE6,0xFF0F6A70,0x66063BCA,0x11010B5C,0x8F659EFF,0xF862AE69,0x616BFFD3,0x166CCF45,
  0xA00AE278,0xD70DD2EE,0x4E048354,0x3903B3C2,0xA7672661,0xD06016F7,0x4969474D,0x3E6E77DB,
  0xAED16A4A,0xD9D65ADC,0x40DF0B66,0x37D83BF0,0xA9BCAE53,0xDEBB9EC5,0x47B2CF7F,0x30B5FFE9,
  0xBDBDF21C,0xCABAC28A,0x53B39330,0x24B4A3A6,0xBAD03605,0xCDD70693,0x54DE5729,0x23D967BF,
  0xB3667A2E,0xC4614AB8,0x5D681B02,0x2A6F2B94,0xB40BBE37,0xC30C8EA1,0x5A05DF1B,0x2D02EF8D,
};

static uint32_t crc32_compute(uint32_t crc, const uint8_t *buf, uint32_t len) {
  crc = ~crc;
  for (uint32_t i = 0; i < len; i++) {
    crc = crc32_table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
  }
  return ~crc;
}

// mmap_shm(name, size) → Buffer backed by shared memory
static napi_value mmap_shm(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);

  // Get name string.
  char name[256];
  size_t name_len;
  napi_get_value_string_utf8(env, args[0], name, sizeof(name), &name_len);

  // Get size.
  int64_t size;
  napi_get_value_int64(env, args[1], &size);

  // Open shared memory.
  int fd = shm_open(name, O_RDWR, 0600);
  if (fd < 0) {
    napi_throw_error(env, NULL, "shm_open failed");
    return NULL;
  }

  // Map it.
  void *ptr = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (ptr == MAP_FAILED) {
    napi_throw_error(env, NULL, "mmap failed");
    return NULL;
  }

  // Create an external Buffer backed by the mmap'd memory.
  // The Buffer shares the memory — no copy.
  napi_value buffer;
  napi_create_external_buffer(env, (size_t)size, ptr, NULL, NULL, &buffer);
  return buffer;
}

// =====================================================================
// High-performance poll + dispatch + respond — all in one C call.
//
// Replaces the JS poll() + onFrame() + writeResponse() chain.
// JS only runs the handler logic. All SHM reads, CRC validation,
// frame parsing, response writing, CRC computation, seq bumps
// happen in C.
//
// poll_dispatch(buffer, slotCount, slotPairSize, regionHeaderSize,
//               slotDataSize, lastSeqs_u32array, callback)
//
// callback(slotIndex, funcIndex, requestId, argsBuffer) → resultBuffer
//   funcIndex: 0=route, 1=prefetch, 2=handle, 3=render, -1=unknown
// =====================================================================

// CALL frame layout: [tag:1][request_id:4 BE][name_len:2 BE][name][args...]
// RESULT frame layout: [tag:1][request_id:4 BE][flag:1][data...]

// Slot header offsets (match shm_bus.zig SlotHeader).
#define SHM_SERVER_SEQ   0
#define SHM_SIDECAR_SEQ  4
#define SHM_REQUEST_LEN  8
#define SHM_RESPONSE_LEN 12
#define SHM_REQUEST_CRC  16
#define SHM_RESPONSE_CRC 20
#define SHM_SLOT_STATE   24   // SlotState: 0=free, 1=call_written, 2=result_written
#define SHM_SLOT_HEADER  64

// CRC32 over len_bytes ++ payload_bytes (TB convention).
static uint32_t compute_crc(const uint8_t *payload, uint32_t len) {
  uint8_t len_bytes[4];
  memcpy(len_bytes, &len, 4); // LE
  uint32_t c = crc32_compute(0, len_bytes, 4);
  if (len > 0) c = crc32_compute(c, payload, len);
  return c;
}

// Map CALL function name to index. Returns -1 for unknown.
static int func_name_index(const uint8_t *name, uint16_t len) {
  if (len == 5 && memcmp(name, "route", 5) == 0) return 0;
  if (len == 8 && memcmp(name, "prefetch", 8) == 0) return 1;
  if (len == 6 && memcmp(name, "handle", 6) == 0) return 2;
  if (len == 6 && memcmp(name, "render", 6) == 0) return 3;
  if (len == 13 && memcmp(name, "handle_render", 13) == 0) return 4;
  if (len == 14 && memcmp(name, "route_prefetch", 14) == 0) return 5;
  return -1;
}

static napi_value poll_dispatch(napi_env env, napi_callback_info info) {
  size_t argc = 7;
  napi_value argv[7];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  // arg0: buffer (mmap'd region)
  void *buf_data;
  size_t buf_len;
  napi_get_buffer_info(env, argv[0], &buf_data, &buf_len);
  uint8_t *buf = (uint8_t *)buf_data;

  // arg1: slotCount
  int64_t slot_count;
  napi_get_value_int64(env, argv[1], &slot_count);

  // arg2: slotPairSize
  int64_t slot_pair_size;
  napi_get_value_int64(env, argv[2], &slot_pair_size);

  // arg3: regionHeaderSize
  int64_t region_header_size;
  napi_get_value_int64(env, argv[3], &region_header_size);

  // arg4: slotDataSize (frame_max)
  int64_t slot_data_size;
  napi_get_value_int64(env, argv[4], &slot_data_size);

  // arg5: lastSeqs (Uint32Array — persistent across calls)
  void *seq_data;
  size_t seq_len;
  napi_get_typedarray_info(env, argv[5], NULL, &seq_len, &seq_data, NULL, NULL);
  uint32_t *last_seqs = (uint32_t *)seq_data;

  // arg6: callback(slotIndex, funcIndex, requestId, argsBuffer) → resultBuffer
  napi_value callback = argv[6];

  // Boundary assertion: JS args must be consistent with buffer size.
  if (region_header_size + slot_count * slot_pair_size > (int64_t)buf_len) {
    napi_throw_error(env, NULL, "buffer too small for slot layout");
    return NULL;
  }

  int found = 0;

  for (int i = 0; i < (int)slot_count; i++) {
    uint8_t *hdr = buf + region_header_size + (size_t)i * slot_pair_size;
    // Acquire load: ensures all CALL data written by the server is visible
    // after we observe the new server_seq value.
    uint32_t server_seq = __atomic_load_n((uint32_t *)(hdr + SHM_SERVER_SEQ), __ATOMIC_ACQUIRE);

    if (server_seq <= last_seqs[i]) continue;
    last_seqs[i] = server_seq;

    uint32_t request_len;
    memcpy(&request_len, hdr + SHM_REQUEST_LEN, 4);
    if (request_len > (uint32_t)slot_data_size) continue;

    uint8_t *payload = hdr + SHM_SLOT_HEADER; // request area starts after header

    // Validate CRC. Sentinel: CRC=0 means "not yet written" (server
    // crashed mid-CALL write). Skip rather than risk 1-in-2^32 false positive.
    uint32_t stored_crc;
    memcpy(&stored_crc, hdr + SHM_REQUEST_CRC, 4);
    if (stored_crc == 0) continue;
    uint32_t computed_crc = compute_crc(payload, request_len);
    if (stored_crc != computed_crc) continue;

    // Parse CALL frame: [tag:1][request_id:4 BE][name_len:2 BE][name][args]
    if (request_len < 7) continue;
    if (payload[0] != 0x10) continue; // Not a CALL tag

    uint32_t request_id = ((uint32_t)payload[1] << 24) |
                          ((uint32_t)payload[2] << 16) |
                          ((uint32_t)payload[3] << 8) |
                          (uint32_t)payload[4];
    uint16_t name_len = ((uint16_t)payload[5] << 8) | (uint16_t)payload[6];
    if (7 + name_len > request_len) continue;

    int func_idx = func_name_index(payload + 7, name_len);
    uint32_t args_offset = 7 + name_len;
    uint32_t args_len = request_len - args_offset;

    // Create args Buffer (subarray of the mmap — zero-copy).
    napi_value args_buf;
    napi_create_external_buffer(env, args_len, payload + args_offset, NULL, NULL, &args_buf);

    // Call JS: callback(slotIndex, funcIndex, requestId, argsBuffer)
    napi_value js_slot, js_func, js_reqid;
    napi_create_int32(env, i, &js_slot);
    napi_create_int32(env, func_idx, &js_func);
    napi_create_uint32(env, request_id, &js_reqid);

    napi_value js_args[4] = { js_slot, js_func, js_reqid, args_buf };
    napi_value js_result;
    napi_value global;
    napi_get_global(env, &global);

    napi_status status = napi_call_function(env, global, callback, 4, js_args, &js_result);
    if (status != napi_ok) continue;

    // Get result buffer from JS.
    void *result_data;
    size_t result_len;
    bool is_buf;
    napi_is_buffer(env, js_result, &is_buf);
    if (!is_buf) {
      // Try typedarray (Uint8Array).
      napi_is_typedarray(env, js_result, &is_buf);
      if (is_buf) {
        napi_get_typedarray_info(env, js_result, NULL, &result_len, &result_data, NULL, NULL);
      } else continue;
    } else {
      napi_get_buffer_info(env, js_result, &result_data, &result_len);
    }

    // Write response to SHM slot.
    uint8_t *resp_area = hdr + SHM_SLOT_HEADER + (size_t)slot_data_size; // response area
    if (result_len > 0 && result_len <= (size_t)slot_data_size) {
      memcpy(resp_area, result_data, result_len);
    }

    // Write response header: length, CRC, state, then seq.
    uint32_t resp_len32 = (uint32_t)result_len;
    memcpy(hdr + SHM_RESPONSE_LEN, &resp_len32, 4);
    uint32_t resp_crc = compute_crc(resp_area, resp_len32);
    memcpy(hdr + SHM_RESPONSE_CRC, &resp_crc, 4);
    hdr[SHM_SLOT_STATE] = 2; // result_written

    // Release fence: all stores above (data, len, CRC, state) must be
    // visible before the sidecar_seq bump. Without this, ARM CPUs may
    // reorder the seq write before data writes — the server would see
    // the new seq but read stale/partial data.
    __atomic_thread_fence(__ATOMIC_RELEASE);

    // Bump sidecar_seq — the server's acquire load on this field orders
    // all subsequent reads after this write becomes visible.
    uint32_t cur_seq;
    memcpy(&cur_seq, hdr + SHM_SIDECAR_SEQ, 4);
    cur_seq++;
    __atomic_store_n((uint32_t *)(hdr + SHM_SIDECAR_SEQ), cur_seq, __ATOMIC_RELEASE);

    found++;
  }

  napi_value js_found;
  napi_create_int32(env, found, &js_found);
  return js_found;
}

// CRC self-test — pair assertion against Zig's std.hash.crc.Crc32.
// If this fails, the table is corrupted and all SHM frames will be
// silently dropped (CRC mismatch on every CALL and RESULT).
static void verify_crc_table(void) {
  uint8_t test_input[] = "hello";
  uint32_t expected = 0x3610A686; // CRC32("hello") — matches zlib + Zig
  uint32_t actual = crc32_compute(0, test_input, 5);
  if (actual != expected) {
    fprintf(stderr, "FATAL: CRC32 table corrupted (got 0x%08X, expected 0x%08X)\n",
            actual, expected);
    abort();
  }
}

// Module init.
static napi_value init(napi_env env, napi_value exports) {
  verify_crc_table();
  napi_value fn;
  napi_create_function(env, "mmapShm", NAPI_AUTO_LENGTH, mmap_shm, NULL, &fn);
  napi_set_named_property(env, exports, "mmapShm", fn);
  napi_create_function(env, "pollDispatch", NAPI_AUTO_LENGTH, poll_dispatch, NULL, &fn);
  napi_set_named_property(env, exports, "pollDispatch", fn);
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
