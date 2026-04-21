// sqlite3_zig.h — Zig-compatible wrappers for SQLITE_TRANSIENT.
//
// Zig's c_translation cannot produce a misaligned function pointer
// on macOS (pointer alignment is enforced). SQLITE_TRANSIENT is defined
// as ((sqlite3_destructor_type)-1) — a sentinel value that tells SQLite
// to immediately copy the bound data. Since it's never called as a
// function, the misalignment is safe, but Zig rejects it at comptime.
//
// These wrapper functions are compiled as C (sqlite3_zig.c) and linked,
// keeping the cast on the C side. Zero overhead at -O2.

#ifndef SQLITE3_ZIG_H
#define SQLITE3_ZIG_H

#include "sqlite3.h"

int sqlite3_bind_text_transient(sqlite3_stmt *stmt, int col, const char *val, int len);
int sqlite3_bind_blob_transient(sqlite3_stmt *stmt, int col, const void *val, int len);

#endif
