from tiger_web import esc


def route(req):
    return {"operation": "list_collections", "id": "0" * 32}


def prefetch(msg, db):
    collections = db.query_all(
        "SELECT id, name FROM collections ORDER BY id LIMIT ?1", 50
    )
    return {"collections": collections}


def handle(ctx, db):
    return "ok"


def render(ctx, db=None):
    collections = ctx["prefetched"].get("collections") or []
    if not collections:
        return '<div class="meta">No collections</div>'

    return "".join(
        f'<div class="card"><strong>{esc(c["name"])}</strong>'
        f'<div class="meta">{c["id"]}</div></div>'
        for c in collections
    )
