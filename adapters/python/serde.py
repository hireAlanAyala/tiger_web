# Binary row format serde — reads row sets from the framework, writes
# params and SQL declarations back. Port of generated/serde.ts.
# No per-type codegen. Must agree exactly with protocol.zig and storage.zig.
# Correctness verified by cross-language tests.

import struct
from typing import Any

# --- Constants (match protocol.zig) ---

FRAME_MAX = 256 * 1024
COLUMNS_MAX = 32
COLUMN_NAME_MAX = 128
CELL_VALUE_MAX = 4096

# --- Type tags (match protocol.zig TypeTag) ---

class TypeTag:
    INTEGER = 0x01
    FLOAT = 0x02
    TEXT = 0x03
    BLOB = 0x04
    NULL = 0x05

class QueryMode:
    QUERY = 0x00
    QUERY_ALL = 0x01

class MessageTag:
    ROUTE_REQUEST = 0x01
    ROUTE_PREFETCH_RESPONSE = 0x02
    PREFETCH_RESULTS = 0x03
    HANDLE_RENDER_RESPONSE = 0x04
    RENDER_RESULTS = 0x05
    HTML_RESPONSE = 0x06

class CallTag:
    CALL = 0x10
    RESULT = 0x11
    QUERY = 0x12
    QUERY_RESULT = 0x13

class ResultFlag:
    SUCCESS = 0x00
    FAILURE = 0x01


# --- Row set reader (framework -> sidecar) ---

def read_row_set(buf: bytes, offset: int) -> tuple[dict, int]:
    """Read a self-describing row set from a binary buffer.
    Returns (row_set, new_offset)."""
    pos = offset

    # Column count.
    col_count = struct.unpack_from(">H", buf, pos)[0]
    pos += 2
    if col_count > COLUMNS_MAX:
        raise ValueError(f"column count exceeds max: {col_count}")

    # Column descriptors.
    columns = []
    for _ in range(col_count):
        type_tag = buf[pos]
        pos += 1
        name_len = struct.unpack_from(">H", buf, pos)[0]
        pos += 2
        if name_len > COLUMN_NAME_MAX:
            raise ValueError(f"column name exceeds max: {name_len}")
        name = buf[pos:pos + name_len].decode("utf-8")
        pos += name_len
        columns.append({"type_tag": type_tag, "name": name})

    # Row count.
    row_count = struct.unpack_from(">I", buf, pos)[0]
    pos += 4

    # Rows.
    rows = []
    for _ in range(row_count):
        row = {}
        for col in columns:
            value, pos = _read_typed_value(buf, pos, col["type_tag"])
            row[col["name"]] = value
        rows.append(row)

    return {"columns": columns, "rows": rows}, pos


def _read_typed_value(buf: bytes, pos: int, type_tag: int) -> tuple[Any, int]:
    """Read a single typed value from the buffer."""
    if type_tag == TypeTag.INTEGER:
        lo = struct.unpack_from("<I", buf, pos)[0]
        hi = struct.unpack_from("<i", buf, pos + 4)[0]
        pos += 8
        return hi * 0x100000000 + lo, pos
    elif type_tag == TypeTag.FLOAT:
        val = struct.unpack_from("<d", buf, pos)[0]
        pos += 8
        return val, pos
    elif type_tag == TypeTag.TEXT:
        length = struct.unpack_from(">H", buf, pos)[0]
        pos += 2
        if length > CELL_VALUE_MAX:
            raise ValueError(f"text value exceeds max: {length}")
        val = buf[pos:pos + length].decode("utf-8")
        pos += length
        return val, pos
    elif type_tag == TypeTag.BLOB:
        length = struct.unpack_from(">H", buf, pos)[0]
        pos += 2
        if length > CELL_VALUE_MAX:
            raise ValueError(f"blob value exceeds max: {length}")
        val = bytes(buf[pos:pos + length])
        pos += length
        return val, pos
    elif type_tag == TypeTag.NULL:
        return None, pos
    else:
        raise ValueError(f"unknown type tag: {type_tag}")


# --- Param writer (sidecar -> framework) ---

def write_params(buf: bytearray, offset: int, params: list[Any]) -> int:
    """Write a parameter list into a binary buffer. Returns bytes written."""
    pos = offset
    for param in params:
        pos = _write_typed_param(buf, pos, param)
    return pos - offset


def _write_typed_param(buf: bytearray, pos: int, val: Any) -> int:
    """Write a single typed parameter value."""
    if val is None:
        buf[pos] = TypeTag.NULL
        return pos + 1

    if isinstance(val, bool):
        buf[pos] = TypeTag.INTEGER
        pos += 1
        struct.pack_into("<i", buf, pos, 1 if val else 0)
        struct.pack_into("<i", buf, pos + 4, 0)
        return pos + 8

    if isinstance(val, int):
        buf[pos] = TypeTag.INTEGER
        pos += 1
        # Pack as i64 LE.
        struct.pack_into("<q", buf, pos, val)
        return pos + 8

    if isinstance(val, float):
        buf[pos] = TypeTag.FLOAT
        pos += 1
        struct.pack_into("<d", buf, pos, val)
        return pos + 8

    if isinstance(val, str):
        buf[pos] = TypeTag.TEXT
        pos += 1
        encoded = val.encode("utf-8")
        if len(encoded) > 0xFFFF:
            raise ValueError(f"text param exceeds u16 max length: {len(encoded)}")
        struct.pack_into(">H", buf, pos, len(encoded))
        pos += 2
        buf[pos:pos + len(encoded)] = encoded
        return pos + len(encoded)

    if isinstance(val, (bytes, bytearray)):
        buf[pos] = TypeTag.BLOB
        pos += 1
        if len(val) > 0xFFFF:
            raise ValueError(f"blob param exceeds u16 max length: {len(val)}")
        struct.pack_into(">H", buf, pos, len(val))
        pos += 2
        buf[pos:pos + len(val)] = val
        return pos + len(val)

    raise ValueError(f"unsupported param type: {type(val)}")


# --- Frame IO ---

def read_frame(sock) -> bytes | None:
    """Read a length-prefixed frame from a socket. Returns payload or None on disconnect."""
    header = _recv_exact(sock, 4)
    if header is None:
        return None
    length = struct.unpack(">I", header)[0]
    if length == 0:
        return b""
    payload = _recv_exact(sock, length)
    return payload


def send_frame(sock, payload: bytes) -> None:
    """Write a length-prefixed frame to a socket."""
    header = struct.pack(">I", len(payload))
    sock.sendall(header + payload)


def _recv_exact(sock, n: int) -> bytes | None:
    """Read exactly n bytes from a socket. Returns None on disconnect."""
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)
