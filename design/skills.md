These skills are meant to run # as the first iteration ## as a separate iteration, and so on

# harden - asssertions
look at the code and take inventory of all the invariants that must exist and the code is assuming are present during execution.
if they're not asserted earlier in the code path, add an assertion.

## second loop
What would the tiger beetle team say about our new assertions?

# harden - test
Think about if any parts of the code would benefit from:
- fixed input unit tests
- seed unit tests
- simulation tests
