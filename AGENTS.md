# Agent Instructions

## Workflow

- Read `BACKLOG.md` before starting any work to understand open items and priorities.
- When completing a task, move it from "To Do" or "In Progress" → "Done" with a one-line summary.
- When discovering new work, add it to "To Do" in `BACKLOG.md` with enough context for another agent to pick it up.
- Do not remove items from "Done" — they serve as project history.

## Key References

- `PROTOCOL.md` — serial communication spec between the macOS app and ESP32-S3. This is the shared contract; any protocol change must update this file and both implementations.
- `macos-app/AGENTS.md` — landmines and gotchas specific to the macOS app.
- `firmware/AGENTS.md` — landmines and gotchas specific to the ESP32-S3 firmware.
- Per-app `README.md` files document architecture and build instructions.

## Rules

- Do not duplicate information that is already discoverable by reading the code or existing documentation.
- Do not add codebase overviews, directory structures, or tech stack descriptions to any `AGENTS.md` file. That belongs in `README.md`.
- `AGENTS.md` files are for non-obvious gotchas, landmines, and workflow conventions only.
- **Formatting:** Never leave trailing spaces on any lines, especially empty new lines.