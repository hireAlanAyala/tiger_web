from tiger_web import esc, price


def route(req):
    return {"operation": "create_product", "id": "0" * 32}


def prefetch(msg, db):
    return {}


def handle(ctx, db):
    body = ctx["body"]
    name = body.get("name", "")
    description = body.get("description", "")
    price_cents = body.get("price_cents", 0)
    inventory = body.get("inventory", 0)

    db.execute(
        "INSERT INTO products (id, name, description, price_cents, inventory, version, active) "
        "VALUES (?1, ?2, ?3, ?4, ?5, 1, 1)",
        ctx["id"], name, description, price_cents, inventory,
    )
    return "ok"


def render(ctx, db=None):
    if ctx["status"] == "ok":
        return '<div class="card">Product created</div>'
    return f'<div class="error">{ctx["status"]}</div>'
