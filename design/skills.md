These skills are meant to run # as the first iteration ## as a separate iteration, and so on

# harden - asssertions
look at the code and take inventory of all the invariants that must exist and the code is assuming are present during execution.
if they're not asserted in the correct outermost boundary, add an assertion.
internal code should be able to trust external assertions

## second loop
What would the tiger beetle team say about our new assertions?

# harden - test
Think about if any parts of the code would benefit from:
- fixed input unit tests: prevents regression
- seed unit tests: will find unhandled edge cases when passed in data can be unpredictable
- simulation tests: ensure integration
