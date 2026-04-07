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
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
