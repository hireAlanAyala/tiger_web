import sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[2] / "adapters" / "python"))
from tiger_web import esc, price


def route(req):
    if req["params"].get("q"):
        return None
    return {"operation": "list_products", "id": "0" * 32}


def prefetch(msg, db):
    products = db.query_all(
        "SELECT id, name, description, price_cents, inventory, version, active "
        "FROM products ORDER BY id LIMIT ?1", 50
    )
    return {"products": products}


def handle(ctx, db):
    return "ok"


def render(ctx, db=None):
    products = ctx["prefetched"].get("products") or []
    if not products:
        return '<div class="meta">No products</div>'

    return "".join(
        f'<div class="card"><strong>{esc(p["name"])}</strong> &mdash; {price(p["price_cents"])}'
        f' &mdash; inv: {p["inventory"]} &mdash; v{p["version"]}</div>'
        for p in products if p.get("active")
    )
