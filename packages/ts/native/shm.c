// Minimal N-API addon: mmap shared memory + futex_wake.
// ~60 lines. No dependencies beyond libc + node-api.

#include <node_api.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/futex.h>
#include <sys/syscall.h>
#include <stdint.h>
#include <string.h>

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

// futex_wake(buffer, offset) — wake one waiter on the u32 at buffer[offset]
static napi_value futex_wake(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);

  // Get buffer pointer.
  void *data;
  size_t length;
  napi_get_buffer_info(env, args[0], &data, &length);

  // Get offset.
  int64_t offset;
  napi_get_value_int64(env, args[1], &offset);

  // futex_wake on the u32 at data + offset.
  uint32_t *addr = (uint32_t *)((uint8_t *)data + offset);
  // No FUTEX_PRIVATE_FLAG — shared memory is cross-process.
  syscall(SYS_futex, addr, FUTEX_WAKE, 1, NULL, NULL, 0);

  return NULL;
}

// futex_wait(buffer, offset, expected) — block until *(u32*)(buffer+offset) != expected.
// Returns 0 on wake, -1 on spurious wakeup or error. Caller should re-check
// the value and retry if needed — standard futex pattern.
static napi_value futex_wait(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);

  void *data;
  size_t length;
  napi_get_buffer_info(env, args[0], &data, &length);

  int64_t offset;
  napi_get_value_int64(env, args[1], &offset);

  int64_t expected;
  napi_get_value_int64(env, args[2], &expected);

  uint32_t *addr = (uint32_t *)((uint8_t *)data + offset);
  // No FUTEX_PRIVATE_FLAG — shared memory is cross-process.
  long rc = syscall(SYS_futex, addr, FUTEX_WAIT,
                    (uint32_t)expected, NULL, NULL, 0);

  napi_value result;
  napi_create_int32(env, (int32_t)rc, &result);
  return result;
}

// spin_wait(buffer, offset, expected, spin_count) — spin until value changes,
// then fall back to futex_wait. Returns the new value.
// Spin phase is pure native (no JS overhead). Under load, the value
// typically changes within the spin window. When idle, falls through
// to futex_wait (0% CPU).
static napi_value spin_wait(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);

  void *data;
  size_t length;
  napi_get_buffer_info(env, args[0], &data, &length);

  int64_t offset;
  napi_get_value_int64(env, args[1], &offset);

  int64_t expected;
  napi_get_value_int64(env, args[2], &expected);

  int64_t spin_count;
  napi_get_value_int64(env, args[3], &spin_count);

  volatile uint32_t *addr = (volatile uint32_t *)((uint8_t *)data + offset);
  uint32_t exp = (uint32_t)expected;

  // Spin phase — check value at native speed.
  for (long i = 0; i < spin_count; i++) {
    uint32_t val = __atomic_load_n(addr, __ATOMIC_ACQUIRE);
    if (val != exp) {
      napi_value result;
      napi_create_int64(env, (int64_t)val, &result);
      return result;
    }
  }

  // Futex phase — sleep until value changes.
  while (1) {
    long rc = syscall(SYS_futex, (uint32_t *)addr, FUTEX_WAIT,
                      exp, NULL, NULL, 0);
    uint32_t val = __atomic_load_n(addr, __ATOMIC_ACQUIRE);
    if (val != exp) {
      napi_value result;
      napi_create_int64(env, (int64_t)val, &result);
      return result;
    }
    // Spurious wakeup — retry.
    (void)rc;
  }
}

// =====================================================================
// High-performance poll + dispatch + respond — all in one C call.
//
// Replaces the JS poll() + onFrame() + writeResponse() chain.
// JS only runs the handler logic. All SHM reads, CRC validation,
// frame parsing, response writing, CRC computation, seq bumps,
// and futex wakes happen in C.
//
// poll_dispatch(buffer, slotCount, slotPairSize, regionHeaderSize,
//               slotDataSize, lastSeqs_u32array, callback)
//
// callback(slotIndex, funcIndex, requestId, argsBuffer) → resultBuffer
//   funcIndex: 0=route, 1=prefetch, 2=handle, 3=render, -1=unknown
// =====================================================================

#include <zlib.h> // crc32

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
  uint32_t c = crc32(0, len_bytes, 4);
  if (len > 0) c = crc32(c, payload, len);
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

  int found = 0;

  for (int i = 0; i < (int)slot_count; i++) {
    uint8_t *hdr = buf + region_header_size + (size_t)i * slot_pair_size;
    uint32_t server_seq;
    memcpy(&server_seq, hdr + SHM_SERVER_SEQ, 4); // LE native

    if (server_seq <= last_seqs[i]) continue;
    last_seqs[i] = server_seq;

    uint32_t request_len;
    memcpy(&request_len, hdr + SHM_REQUEST_LEN, 4);
    if (request_len > (uint32_t)slot_data_size) continue;

    uint8_t *payload = hdr + SHM_SLOT_HEADER; // request area starts after header

    // Validate CRC.
    uint32_t stored_crc;
    memcpy(&stored_crc, hdr + SHM_REQUEST_CRC, 4);
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

    // Bump sidecar_seq.
    uint32_t cur_seq;
    memcpy(&cur_seq, hdr + SHM_SIDECAR_SEQ, 4);
    cur_seq++;
    memcpy(hdr + SHM_SIDECAR_SEQ, &cur_seq, 4);

    // No futex_wake needed: server polls sidecar_seq in its tick loop
    // (poll_responses called every tick). Same optimization as the
    // server→sidecar direction (sidecar_polling flag).

    found++;
  }

  napi_value js_found;
  napi_create_int32(env, found, &js_found);
  return js_found;
}

// Module init.
static napi_value init(napi_env env, napi_value exports) {
  napi_value fn;
  napi_create_function(env, "mmapShm", NAPI_AUTO_LENGTH, mmap_shm, NULL, &fn);
  napi_set_named_property(env, exports, "mmapShm", fn);
  napi_create_function(env, "futexWake", NAPI_AUTO_LENGTH, futex_wake, NULL, &fn);
  napi_set_named_property(env, exports, "futexWake", fn);
  napi_create_function(env, "futexWait", NAPI_AUTO_LENGTH, futex_wait, NULL, &fn);
  napi_set_named_property(env, exports, "futexWait", fn);
  napi_create_function(env, "spinWait", NAPI_AUTO_LENGTH, spin_wait, NULL, &fn);
  napi_set_named_property(env, exports, "spinWait", fn);
  napi_create_function(env, "pollDispatch", NAPI_AUTO_LENGTH, poll_dispatch, NULL, &fn);
  napi_set_named_property(env, exports, "pollDispatch", fn);
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
