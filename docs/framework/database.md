
getting rid of memorystorage and running th esim against a local binary of the db is fine
our sim will just be as fast as prod. which is fine becuase problems in the web server space show up within 10k seeds likely
tiger beetle needs millions of seeds to corrupt

# wal
wal in development is a session, not a record
wal in prod is an audit, not a replay.
when wal is no longer accurate delete it

to the user
prod level wal: marketed as logs
dev level wal: marketed as session
