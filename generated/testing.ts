// Framework-provided test utilities.
//
// Usage in test files:
//   import { TestRunner } from "tiger-web/testing";
//   const t = new TestRunner();
//   t.assert(condition, "message");
//   t.done(); // prints results, exits with code 1 on failures
//
// Handlers use assert() from "tiger-web" (throws on failure).
// Tests use TestRunner.assert() (collects failures, reports at end).
// Same developer intent ("this must be true"), different context.

export class TestRunner {
  passed = 0;
  failed = 0;

  /** Assert a condition. Collects failures instead of throwing. */
  assert(ok: boolean, msg: string): void {
    if (ok) {
      this.passed++;
    } else {
      this.failed++;
      console.error(`FAIL: ${msg}`);
    }
  }

  /** Print results and exit. Call at the end of the test suite. */
  done(): void {
    console.log(`\n${this.passed} passed, ${this.failed} failed`);
    if (this.failed > 0) process.exit(1);
  }
}
