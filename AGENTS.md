# Repository Guidelines

## Project Structure & Module Organization
- `src/`: core Zig module (e.g., `src/root.zig`, `src/conn.zig`).
- `src/tests/`: unit/integration tests aggregated by `src/tests/mod.zig` and driven by `test_runner.zig`.
- `examples/`: runnable samples (`basic.zig`, `prepared.zig`, `transactions.zig`, etc.).
- `lib/`: Kuzu C API headers and libs (`kuzu.h`, `libkuzu.*`, static deps).
- `build.zig`/`build.zig.zon`: build graph and prebuilt Kuzu dependencies.
- `docs/`, `README.md`, `ROADMAP.md`, `Taskfile.yml`: documentation and helper tasks.

## Build, Test, and Development Commands
- `zig build test`: run all tests (default `-Dkuzu-provider=prebuilt`, downloads Kuzu).
- `zig build -Dkuzu-provider=local test`: use headers/libs from `lib/` (offline).
- `zig build -Dkuzu-provider=system -Dkuzu-include-dir=/path/include -Dkuzu-lib-dir=/path/lib test`: use system install.
- Examples: `zig build example-basic` (also `example-prepared`, `example-transactions`, `example-pool`, `example-performance`, `example-errors`).
- Optional: `task build-kuzu && task copy-lib` to build Kuzu from source into `lib/`.

Tip: When running built binaries manually with shared libs, set `DYLD_LIBRARY_PATH` (macOS) or `LD_LIBRARY_PATH` (Linux) to `lib/`.

## Coding Style & Naming Conventions
- Formatting: run `zig fmt .` (required before PRs).
- Indentation: 4 spaces; no tabs.
- Naming: Types/structs PascalCase, functions/variables lowerCamelCase, files snake_case.
- Keep modules small and cohesive; prefer explicit error sets.

## Testing Guidelines
- Framework: Zig `std.testing` with custom `test_runner.zig`.
- Location: add new tests in `src/tests/` (picked up via `src/tests/mod.zig`).
- Conventions: descriptive test names (e.g., `"integration: transactions happy path"`).
- Run: `zig build test`; ensure tests pass for all supported providers you touch.

## Commit & Pull Request Guidelines
- Commits: follow Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`). Keep messages imperative and scoped.
- PRs must include: clear description, linked issues, how to test (commands + expected output), platform (`macOS/Linux/Windows`) and provider used (`prebuilt/system/local/source`). Attach logs if behavior differs across OS.

## Security & Configuration Tips
- Do not commit secrets or system paths. Large binaries in `lib/` are intentional—avoid modifying unless updating Kuzu.
- Prefer `-Dkuzu-provider=local` for offline CI; use `prebuilt` only where network is allowed.
