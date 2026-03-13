# Slop Engine

## Test Tasks

This project uses `rake` as the entrypoint for the fixture-based test harness.

- `rake` runs the full test suite.
- `rake test` runs the full test suite explicitly.
- `JOBS=2 rake test` overrides the number of parallel fixture workers.
- `rake clean` removes fixture build outputs.

The tasks use the system `ruby` and `rake` installation directly. No Bundler setup is required.
Each fixture under `test/examples` also exposes its own `rake build` and `rake clean` tasks.
