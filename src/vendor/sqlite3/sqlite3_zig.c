// sqlite3_zig.c — Compiled wrappers for SQLITE_TRANSIENT.
// See sqlite3_zig.h for rationale.

#include "sqlite3_zig.h"

int sqlite3_bind_text_transient(sqlite3_stmt *stmt, int col, const char *val, int len) {
    return sqlite3_bind_text(stmt, col, val, len, SQLITE_TRANSIENT);
}

int sqlite3_bind_blob_transient(sqlite3_stmt *stmt, int col, const void *val, int len) {
    return sqlite3_bind_blob(stmt, col, val, len, SQLITE_TRANSIENT);
}
