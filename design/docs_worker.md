in deterministic systems users are responsible for providing a deterministic replacement for their non-deterministic systems.

that means that for workers, users must provide a mock for each api call.

I needed to get a random code in the state machine for email code auth. I ended up using the builtin self.prng to gen the code.
but if I absolutely needed to use some lib to do it, and it was not deterministic, i could put it inside of a worker and keep the system deterministic for free.
