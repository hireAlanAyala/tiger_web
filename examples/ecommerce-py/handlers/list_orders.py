import sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[2] / "adapters" / "python"))
from tiger_web import price


def route(req):
    return {"operation": "list_orders", "id": "0" * 32}


def prefetch(msg, db):
    orders = db.query_all(
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders ORDER BY id LIMIT ?1", 50
    )
    return {"orders": orders}


def handle(ctx, db):
    return "ok"


def render(ctx, db=None):
    orders = ctx["prefetched"].get("orders") or []
    if not orders:
        return '<div class="meta">No orders</div>'

    return "".join(
        f'<div class="card">status={o["status"]} &mdash; {price(o["total_cents"])}'
        f' &mdash; {o["items_len"]} items'
        f'<div class="meta">{o["id"]}</div></div>'
        for o in orders
    )
