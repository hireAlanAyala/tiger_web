
tiger beetle's diagnostic is seed+git_commit.
the seed is specfically for replaying the events in debug mode
You add asserts and logs into the code
you then follow the debug output until you understand the bug
when you make mutations to the code, the seed is not longer replayable
you then run simulations again and ensure its fixed

You're not expecting identical execution, youre expecting correct output

for my project since we dont own the db our debug target is
git commit + commit scoped wal + seed
will give us the whole story, messages ran + code that ran them + seed
