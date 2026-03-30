# Route matching — port of generated/routing.ts.
# Verified by cross-language test vectors (route_match_vectors.json).


def match_route(raw_path: str, pattern: str) -> dict[str, str] | None:
    """Match a request path against a route pattern, extracting :param values.
    Returns params dict or None if no match."""
    if len(raw_path) == 0 or raw_path[0] != "/":
        return None

    # Strip query string.
    qmark = raw_path.find("?")
    path = raw_path[:qmark] if qmark >= 0 else raw_path

    # Root pattern matches root path only.
    if pattern == "/":
        return {} if path == "/" else None

    pat_segs = pattern[1:].split("/")
    path_segs = path[1:].split("/")

    if len(pat_segs) != len(path_segs):
        return None

    params = {}
    for pat, val in zip(pat_segs, path_segs):
        if pat.startswith(":"):
            if len(val) == 0:
                return None
            params[pat[1:]] = val
        else:
            if pat != val:
                return None
    return params
