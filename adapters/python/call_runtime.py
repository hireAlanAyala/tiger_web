#!/usr/bin/env python3
# CALL/RESULT sidecar runtime — dumb function executor.
#
# Connects to the server's unix socket. Receives CALL frames, dispatches
# to handler functions, sends RESULT frames. QUERY sub-protocol for
# db.query() in prefetch and render.
#
# Port of adapters/call_runtime.ts. Python's blocking sockets make this
# simpler than the Node async version — no event loop, no promises.
# The serial pipeline (one CALL at a time) maps naturally to blocking IO.
#
# Usage: python adapters/python/call_runtime.py <socket-path> <generated-dir>

import json
import socket
import struct
import sys
from pathlib import Path

# Add adapters/python to sys.path for sibling imports.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from serde import (
    CallTag, ResultFlag, QueryMode,
    read_row_set, write_params, send_frame, read_frame,
)
from routing import match_route
from protocol_types import (
    OPERATION_VALUES, STATUS_NAMES, METHODS,
)


# --- Handler registry (generated) ---
# Modules and route table are loaded from handlers_generated.py,
# produced by adapters/python.py from the scanner's manifest.json.

handlers: dict[str, dict] = {}
route_table: list[dict] = []


def load_generated(generated_dir: str) -> None:
    """Load modules and route_table from the generated file."""
    global handlers, route_table

    gen_path = Path(generated_dir) / "handlers_generated.py"
    if not gen_path.exists():
        print(f"[call_runtime] error: {gen_path} not found — run the adapter first", file=sys.stderr)
        sys.exit(1)

    import importlib.util
    spec = importlib.util.spec_from_file_location("handlers_generated", gen_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    route_table = mod.route_table

    # Convert loaded modules to handler dicts.
    for op, handler_mod in mod.modules.items():
        if handler_mod is None:
            continue
        handlers[op] = {
            "route": getattr(handler_mod, "route", None),
            "prefetch": getattr(handler_mod, "prefetch", None),
            "handle": getattr(handler_mod, "handle", None),
            "render": getattr(handler_mod, "render", None),
        }

    print(f"[call_runtime] loaded {len(handlers)} handlers from {generated_dir}")


# --- Per-request state ---

class RequestState:
    __slots__ = ("operation", "id", "body", "params", "prefetched")

    def __init__(self):
        self.operation = ""
        self.id = ""
        self.body = {}
        self.params = {}
        self.prefetched = {}

    def reset(self):
        self.operation = ""
        self.id = ""
        self.body = {}
        self.params = {}
        self.prefetched = {}


# --- Protocol helpers ---

def build_result(request_id: int, flag: int, data: bytes) -> bytes:
    buf = bytearray(1 + 4 + 1 + len(data))
    buf[0] = CallTag.RESULT
    struct.pack_into(">I", buf, 1, request_id)
    buf[5] = flag
    buf[6:] = data
    return bytes(buf)


def build_query(request_id: int, query_id: int, sql: str, mode: int, params: list) -> bytes:
    sql_bytes = sql.encode("utf-8")
    buf = bytearray(1 + 4 + 2 + 2 + len(sql_bytes) + 1 + 1 + len(params) * 256)
    pos = 0

    buf[pos] = CallTag.QUERY
    pos += 1
    struct.pack_into(">I", buf, pos, request_id)
    pos += 4
    struct.pack_into(">H", buf, pos, query_id)
    pos += 2
    struct.pack_into(">H", buf, pos, len(sql_bytes))
    pos += 2
    buf[pos:pos + len(sql_bytes)] = sql_bytes
    pos += len(sql_bytes)
    buf[pos] = mode
    pos += 1
    buf[pos] = len(params)
    pos += 1
    pos += write_params(buf, pos, params)

    return bytes(buf[:pos])


# --- QUERY sub-protocol ---

def query_server(sock, request_id: int, query_id_counter: list,
                 sql: str, mode: int, params: list):
    query_id = query_id_counter[0]
    query_id_counter[0] = (query_id + 1) & 0xFFFF

    frame = build_query(request_id, query_id, sql, mode, params)
    send_frame(sock, frame)

    result_frame = read_frame(sock)
    if result_frame is None:
        raise ConnectionError("disconnected waiting for QUERY_RESULT")

    tag = result_frame[0]
    if tag != CallTag.QUERY_RESULT:
        raise ValueError(f"expected QUERY_RESULT, got tag={tag}")

    resp_query_id = struct.unpack_from(">H", result_frame, 5)[0]
    if resp_query_id != query_id:
        raise ValueError(f"query_id mismatch: sent {query_id}, got {resp_query_id}")

    row_data = result_frame[7:]
    if len(row_data) == 0:
        return [] if mode == QueryMode.QUERY_ALL else None

    if len(row_data) < 6:
        print(f"[call_runtime] QUERY_RESULT too short: {len(row_data)} bytes", file=sys.stderr)
        return [] if mode == QueryMode.QUERY_ALL else None

    row_set, _ = read_row_set(row_data, 0)

    if mode == QueryMode.QUERY:
        return row_set["rows"][0] if row_set["rows"] else None
    else:
        return row_set["rows"]


# --- CALL dispatch ---

def dispatch_route(sock, state: RequestState, request_id: int, args: bytes) -> None:
    from urllib.parse import parse_qs

    pos = 0
    method = args[pos]
    pos += 1
    path_len = struct.unpack_from(">H", args, pos)[0]
    pos += 2
    path = args[pos:pos + path_len].decode("utf-8")
    pos += path_len
    body_len = struct.unpack_from(">H", args, pos)[0]
    pos += 2
    body = args[pos:pos + body_len].decode("utf-8")

    method_str = METHODS[method] if method < len(METHODS) else "get"

    query_idx = path.find("?")
    query_string = path[query_idx + 1:] if query_idx >= 0 else ""
    query_params = parse_qs(query_string, keep_blank_values=True)

    result = None
    matched_op = ""

    for entry in route_table:
        if entry["method"] != method_str:
            continue
        params = match_route(path, entry["pattern"])
        if params is None:
            continue

        for qname in entry["query_params"]:
            qval = query_params.get(qname)
            if qval:
                params[qname] = qval[0]

        route_fn = handlers.get(entry["operation"], {}).get("route")
        if route_fn is None:
            continue

        req = {"method": method_str, "path": path, "body": body, "params": params}
        try:
            route_result = route_fn(req)
        except Exception as e:
            print(f"[call_runtime] {entry['operation']} route error: {e}", file=sys.stderr)
            continue

        if route_result is not None:
            result = route_result
            matched_op = entry["operation"]
            break

    if result is None:
        send_frame(sock, build_result(request_id, ResultFlag.SUCCESS, bytes([0])))
        return

    state.operation = matched_op
    state.id = (result.get("id") or "").replace("-", "")
    state.body = json.loads(body) if body else {}
    state.params = result.get("params", {})

    op_value = OPERATION_VALUES.get(matched_op, 0)
    result_buf = bytearray(1 + 1 + 16)
    result_buf[0] = 1
    result_buf[1] = op_value
    id_hex = state.id.ljust(32, "0")[:32]
    for i in range(16):
        result_buf[2 + i] = int(id_hex[i * 2:i * 2 + 2], 16)

    send_frame(sock, build_result(request_id, ResultFlag.SUCCESS, bytes(result_buf)))


def dispatch_prefetch(sock, state: RequestState, request_id: int, args: bytes) -> None:
    mod = handlers.get(state.operation, {})
    prefetch_fn = mod.get("prefetch")

    if prefetch_fn is None:
        send_frame(sock, build_result(request_id, ResultFlag.SUCCESS, b""))
        return

    msg = {
        "operation": state.operation,
        "id": state.id,
        "body": state.body,
    }

    query_id_counter = [0]

    class Db:
        def query(self, sql, *params):
            return query_server(sock, request_id, query_id_counter,
                                sql, QueryMode.QUERY, list(params))

        def query_all(self, sql, *params):
            return query_server(sock, request_id, query_id_counter,
                                sql, QueryMode.QUERY_ALL, list(params))

    prefetched = prefetch_fn(msg, Db())
    state.prefetched = prefetched or {}

    send_frame(sock, build_result(request_id, ResultFlag.SUCCESS, b""))


def dispatch_handle(sock, state: RequestState, request_id: int, args: bytes) -> None:
    mod = handlers.get(state.operation, {})
    handle_fn = mod.get("handle")

    if handle_fn is None:
        status_bytes = b"ok"
        result_buf = struct.pack(">H", len(status_bytes)) + status_bytes + b"\x00"
        send_frame(sock, build_result(request_id, ResultFlag.SUCCESS, result_buf))
        return

    writes = []

    class Db:
        def execute(self, sql, *params):
            writes.append({"sql": sql, "params": list(params)})

    ctx = {
        "operation": state.operation,
        "id": state.id,
        "body": state.body,
        "params": state.params,
        "prefetched": state.prefetched,
    }

    try:
        status = handle_fn(ctx, Db()) or "ok"
    except Exception as e:
        print(f"[call_runtime] {state.operation} handle error: {e}", file=sys.stderr)
        status = "storage_error"

    status_bytes = status.encode("utf-8")
    write_size = 0
    for w in writes:
        sql_bytes = w["sql"].encode("utf-8")
        write_size += 2 + len(sql_bytes) + 1
        for p in w["params"]:
            if p is None:
                write_size += 1
            elif isinstance(p, bool):
                write_size += 9
            elif isinstance(p, (int, float)):
                write_size += 9
            elif isinstance(p, str):
                write_size += 3 + len(p.encode("utf-8"))
            elif isinstance(p, (bytes, bytearray)):
                write_size += 3 + len(p)
            else:
                write_size += 1

    result_buf = bytearray(2 + len(status_bytes) + 1 + write_size)
    pos = 0

    struct.pack_into(">H", result_buf, pos, len(status_bytes))
    pos += 2
    result_buf[pos:pos + len(status_bytes)] = status_bytes
    pos += len(status_bytes)
    result_buf[pos] = len(writes)
    pos += 1

    for w in writes:
        sql_bytes = w["sql"].encode("utf-8")
        struct.pack_into(">H", result_buf, pos, len(sql_bytes))
        pos += 2
        result_buf[pos:pos + len(sql_bytes)] = sql_bytes
        pos += len(sql_bytes)
        result_buf[pos] = len(w["params"])
        pos += 1
        pos += write_params(result_buf, pos, w["params"])

    send_frame(sock, build_result(request_id, ResultFlag.SUCCESS, bytes(result_buf[:pos])))


def dispatch_render(sock, state: RequestState, request_id: int, args: bytes) -> None:
    status_value = args[1]
    status_name = STATUS_NAMES.get(status_value, "ok")

    mod = handlers.get(state.operation, {})
    render_fn = mod.get("render")

    if render_fn is None:
        send_frame(sock, build_result(request_id, ResultFlag.SUCCESS, b""))
        state.reset()
        return

    query_id_counter = [0]

    class Db:
        def query(self, sql, *params):
            return query_server(sock, request_id, query_id_counter,
                                sql, QueryMode.QUERY, list(params))

        def query_all(self, sql, *params):
            return query_server(sock, request_id, query_id_counter,
                                sql, QueryMode.QUERY_ALL, list(params))

    ctx = {
        "operation": state.operation,
        "id": state.id,
        "status": status_name,
        "body": state.body,
        "params": state.params,
        "prefetched": state.prefetched,
        "is_sse": False,
    }

    try:
        html = (render_fn(ctx, Db())) or ""
    except Exception as e:
        print(f"[call_runtime] {state.operation} render error: {e}", file=sys.stderr)
        html = '<div class="error">Internal error</div>'

    html_bytes = html.encode("utf-8")
    send_frame(sock, build_result(request_id, ResultFlag.SUCCESS, html_bytes))

    state.reset()


# --- Main loop ---

def handle_call(sock, state: RequestState, frame: bytes) -> None:
    request_id = struct.unpack_from(">I", frame, 1)[0]
    name_len = struct.unpack_from(">H", frame, 5)[0]
    name = frame[7:7 + name_len].decode("utf-8")
    args = frame[7 + name_len:]

    dispatch = {
        "route": dispatch_route,
        "prefetch": dispatch_prefetch,
        "handle": dispatch_handle,
        "render": dispatch_render,
    }

    fn = dispatch.get(name)
    if fn is None:
        print(f"[call_runtime] unknown function: {name}", file=sys.stderr)
        send_frame(sock, build_result(request_id, ResultFlag.FAILURE, b""))
        return

    try:
        fn(sock, state, request_id, args)
    except Exception as e:
        print(f"[call_runtime] {name} error: {e}", file=sys.stderr)
        send_frame(sock, build_result(request_id, ResultFlag.FAILURE, b""))


def run(socket_path: str, generated_dir: str) -> None:
    load_generated(generated_dir)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)
    print(f"[call_runtime] connected to {socket_path}")

    state = RequestState()

    try:
        while True:
            frame = read_frame(sock)
            if frame is None:
                print("[call_runtime] disconnected")
                break

            tag = frame[0]
            if tag == CallTag.CALL:
                handle_call(sock, state, frame)
            else:
                print(f"[call_runtime] unexpected tag: {tag}", file=sys.stderr)
                break
    finally:
        sock.close()


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python call_runtime.py <socket-path> <generated-dir>", file=sys.stderr)
        sys.exit(1)

    run(sys.argv[1], sys.argv[2])
