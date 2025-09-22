Summary

- Zig: 0.15.1
- Many tests pass; 6 fail and the suite aborts on a segfault.

Crashes

- edge: connection failure and recovery - Segmentation fault inside libkuzu
  during reconnect. - Stack shows call in recover path:
  c.kuzu_connection_init(self.db_handle, &conn_handle) at src/conn.zig:277 and
  via validate() at src/conn.zig:662, called by test at
  src/tests/edge_cases.zig:83. - Likely cause: reinit against an invalid or
  stale database handle, or a libkuzu bug in reinitialization after an
  error-marked connection. Worth validating that self.db_handle is always valid
  and seeing whether lib version mismatch or state assumptions cause this.

Functional Failures

- pool validates and handles concurrent usage … error.TestUnexpectedResult -
  src/tests/conn.zig: test expects < 8 transient errors with 8 threads and a
  4-conn pool. - Current Pool.acquire() is non-blocking and frequently returns
  error.PoolExhausted when all 4 connections are busy, so more than 7 iterations
  error out. Consider blocking acquire (wait until available), backoff/retry in
  test, or relaxing the threshold.
- structured KuzuError integration across ops … error.TestUnexpectedResult -
  src/tests/errors.zig: A KuzuError expectation did not match
  (op/category/message presence). - setError() builds a structured error and
  also sets last_error_message. One of the asserts likely found missing/empty
  message or unexpected category. Adding temporary prints of
  conn.lastError()/message in this test would pinpoint which check fails.
- integration: end-to-end workflow … error.TestExpectedEqual (“expected 2, found
  3”) - src/tests/integration.zig: Before pool work, it expects exactly two
  Person rows after inserting Alice/Bob. - The DB path is a persistent folder
  under zig-cache; DbFixture.init() creates (but does not clear) the directory,
  so leftover rows from prior runs can exist. Either delete the dir in
  DbFixture.init() or use a unique temp dir per run.
- integration: large dataset and timing … error.TypeMismatch -
  src/tests/integration.zig: It reads count(p) as u64 with row.get(u64, 0); Kuzu
  returns an Int64 logical type, so the strict getter flags a mismatch. Use i64
  or adjust the getter to allow safe upcast when non-negative.
- edge: null handling and empty result sets … error.QueryFailed -
  src/tests/edge_cases.zig: conn.query("RETURN NULL") fails (QueryFailed) before
  any row iteration. - This suggests Kuzu reports the statement as not
  successful for bare NULL (or our wrapper treats it as failure). Capturing and
  printing conn.lastErrorMessage() in this test will clarify whether this is a
  Kuzu limitation or a wrapper condition (e.g., isSuccess false with no error).

Notable Code References

- Segfault reinit: src/conn.zig:277, src/conn.zig:662
- Test invoking validate that crashed: src/tests/edge_cases.zig:83
- Non-blocking acquire leading to more errors: src/pool.zig:100–200
- Persistent DB fixture using makeOpenPath only: src/tests/util.zig:22
- Strict typed count read: src/tests/integration.zig:63 and 117

Suggested Next Steps

- Add guardrails around reconnect: verify self.db_handle validity and try
  zero-initializing the new handle before init; instrument to log
  conn.lastErrorMessage() on recovery failures to get libkuzu’s message.
- Make Pool.acquire() optionally blocking (condition variable) or update the
  test to retry on PoolExhausted with a short sleep/backoff.
- Clean test DB directories in DbFixture.init() (deleteTree then recreate) or
  generate per-run unique dirs.
- Change the integration count read to i64 or relax Row.get to upcast
  signed->unsigned if >= 0.
- Print lastErrorMessage() in the NULL/empty-result test to see why Kuzu marks
  it as failure and adjust wrapper/test accordingly.

If you want, I can implement any of the above (e.g., blocking acquire, temp DB
cleanup, and the i64 fix) and rerun the suite.
