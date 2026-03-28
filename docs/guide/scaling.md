# Scaling Beyond One Core

Tiger-web is single-threaded by design — no locks, no races, no
shared state. One process handles ~55,000 req/s on one core. For
most applications, this is more than enough.

When it isn't, run multiple processes. Each process gets its own
core and its own SQLite database. A reverse proxy distributes
requests across them.

## Process per core

```bash
# Start 4 processes on 4 ports, each with its own database
for i in 0 1 2 3; do
  tiger-web --port=$((3000+i)) --db=shard_$i.db &
done
```

## Load balancer (Nginx)

```nginx
upstream tiger {
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    server 127.0.0.1:3002;
    server 127.0.0.1:3003;
}

server {
    listen 80;
    location / {
        proxy_pass http://tiger;
    }
}
```

## Sharding strategies

Each process has its own SQLite database. Requests must be routed
to the process that owns the data.

**By tenant/customer.** Each customer's data lives in one shard.
Route by customer ID (cookie, subdomain, or URL prefix). No
cross-shard queries needed — a customer only sees their own data.
Best for SaaS, multi-tenant ecommerce.

**By function.** Products on shard 0-1, orders on shard 2-3. Route
by URL path. Cross-shard queries needed for "order contains product"
— handle at the application level or export to an analytics database.

**Round-robin.** Stateless requests (no user session) go to any
process. Each process has a full copy of the database. Writes go to
one primary, reads go to any replica. Requires replication — not
built into tiger-web. Use Litestream or LiteFS.

## Why this works

SQLite is designed for this. One database per unit of isolation is
the documented deployment model. Each process has exclusive access
to its database — no connection pooling, no lock contention, no
WAL conflicts.

4 processes × 55,000 req/s = 220,000 req/s on a 4-core machine.
This exceeds most multi-threaded Rust frameworks (actix-web does
~80-120K on 4 cores with PostgreSQL) because there's no shared
state overhead.

## When NOT to shard

If your traffic is under 50,000 req/s, one process is enough.
Sharding adds operational complexity (multiple databases, routing
logic, cross-shard queries). Don't shard until you need to.

50,000 req/s at 1KB per response is 50MB/s of traffic. At an
average page size of 5KB, that's 10,000 page views per second —
864 million page views per day. Most websites never reach this.
