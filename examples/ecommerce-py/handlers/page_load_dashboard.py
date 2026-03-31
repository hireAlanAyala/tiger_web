from tiger_web import esc, price


def route(req):
    return {"operation": "page_load_dashboard", "id": "0" * 32}


def prefetch(msg, db):
    products = db.query_all(
        "SELECT id, name, description, price_cents, inventory, version, active "
        "FROM products ORDER BY id LIMIT ?1", 10
    )
    collections = db.query_all(
        "SELECT id, name FROM collections ORDER BY id LIMIT ?1", 10
    )
    orders = db.query_all(
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders ORDER BY id LIMIT ?1", 10
    )
    return {"products": products, "collections": collections, "orders": orders}


def handle(ctx, db):
    return "ok"


def render(ctx, db=None):
    products = ctx["prefetched"].get("products") or []
    collections = ctx["prefetched"].get("collections") or []
    orders = ctx["prefetched"].get("orders") or []

    product_cards = "".join(
        f'<div class="card"><strong>{esc(p["name"])}</strong> &mdash; {price(p["price_cents"])}'
        f' &mdash; inv: {p["inventory"]} &mdash; v{p["version"]}</div>'
        for p in products if p.get("active")
    ) or '<div class="meta">No products</div>'

    collection_cards = "".join(
        f'<div class="card"><strong>{esc(c["name"])}</strong>'
        f'<div class="meta">{c["id"]}</div></div>'
        for c in collections
    ) or '<div class="meta">No collections</div>'

    order_cards = "".join(
        f'<div class="card">status={o["status"]} &mdash; {price(o["total_cents"])}'
        f'<div class="meta">{o["id"]}</div></div>'
        for o in orders
    ) or '<div class="meta">No orders</div>'

    return (
        '<h1>Tiger Web</h1>'
        '<div class="cols"><div>'
        f'<h2>Products</h2>{product_cards}'
        f'<h2>Collections</h2>{collection_cards}'
        f'</div><div>'
        f'<h2>Orders</h2>{order_cards}'
        '</div></div>'
    )
