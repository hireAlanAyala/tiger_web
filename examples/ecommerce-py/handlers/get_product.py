import sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[2] / "adapters" / "python"))
from tiger_web import esc, price


def route(req):
    return {"operation": "get_product", "id": req["params"]["id"]}


def prefetch(msg, db):
    product = db.query(
        "SELECT id, name, description, price_cents, inventory, version, active "
        "FROM products WHERE id = ?1", msg["id"]
    )
    return {"product": product}


def handle(ctx, db):
    if not ctx["prefetched"].get("product"):
        return "not_found"
    if not ctx["prefetched"]["product"].get("active"):
        return "not_found"
    return "ok"


def render(ctx, db=None):
    if ctx["status"] == "not_found":
        return '<div class="error">Product not found</div>'

    p = ctx["prefetched"]["product"]
    desc = f'<div class="meta">{esc(p["description"])}</div>' if p.get("description") else ""
    active = "" if p.get("active") else ' <span class="error">[inactive]</span>'

    return (
        f'<div class="card"><strong>{esc(p["name"])}</strong> &mdash; {price(p["price_cents"])}'
        f' &mdash; inv: {p["inventory"]} &mdash; v{p["version"]}{active}'
        f'<div class="meta">{p["id"]}</div>{desc}</div>'
    )
