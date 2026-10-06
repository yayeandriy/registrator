# registrator

The registration → accumulation → validation Lua algorithm library shared between [`inventor-api`](https://github.com/yayeandriy/inventor-api) (Rust, via [`mlua`](https://github.com/mlua-rs/mlua)) and [`inventor-ios`](https://github.com/yayeandriy/inventor-ios) (Swift, via a native embedded Lua 5.4 host) — see `SCHEMA.md` for the exact JSON shape each script takes and returns.

## Why a separate repo

Every algorithm here is written exactly once, in `lua/`, and is meant to run **byte-for-byte identically** wherever it's hosted — a backend admin tool and an on-device live camera pipeline need to agree on "is this part in the right place" without ever risking two independently-maintained native implementations drifting apart. Neither consuming repo owns this code; both vendor it (as a git submodule) and treat it as read-only.

## Contents

- `lua/registration.lua`, `lua/validation.lua`, `lua/presence_validator.lua`, `lua/presence_latch.lua`, `lua/accumulator.lua`, `lua/zone.lua`, `lua/live.lua` (`live_strip.lua` / `live_spatial.lua` / `live_window.lua` / `live_zoned.lua`), `lua/inspect_view.lua`, `lua/prepare.lua` — the algorithms. Each file's own header comment is the authoritative spec; `SCHEMA.md` is a field-level index into them.
- `lua/verdict.lua`, `lua/ocr_window.lua`, `lua/session.lua`, `lua/session_zones.lua`, dispatched by `lua/session_host.lua` — the live-session policy (shown verdict, OCR settle, zone latch, settle gate, completion, next still, anchor search, router completion). Clients only keep the counters these ops return and paint the answer.
- `lua/json.lua` — a small dependency-free JSON encode/decode for hosts with no native Lua-table marshaling (the Swift host), and the JSON-text boundary of `session_host.lua`, which both hosts call the same way.
- `tests/` — a pure-Lua test suite (no Rust/Swift toolchain needed) exercising all three scripts across the same JSON-string boundary a real Swift host would use. Run with:

  ```bash
  lua5.4 tests/run_all.lua
  ```

## Consuming this repo

Both `inventor-api` and `inventor-ios` add this repo as a **git submodule** and read straight out of the checkout — there's no build step, package registry, or versioning scheme here beyond git commits:

```bash
git submodule add https://github.com/yayeandriy/registrator.git <path>
git submodule update --init --recursive
```

- `inventor-api`: `crates/registrator/src/*.rs` `include_str!` the scripts straight out of the submodule — one script per wrapper through `exec.rs`, and the session ops composed in `session.rs` (`run_session_op`). The desktop app (Tauri) links the same crate.
- `inventor-ios`: the `Registrator` Swift package bundles a synced copy of `lua/` (`Vendor/registrator-lua`) and composes `session_host.lua` the same way in `SessionOps.swift`. The monorepo's `scripts/check-lua-parity` fails when that copy drifts.

## The rule

Business logic — status, scores, matching, holds, completion, extras, view and profile choice — is written here once. Hosts gather facts, call an op, keep the state it returns, and render; they never re-implement a rule. Adding or changing an op: see the `lua-engine-op` skill in the Inventor monorepo (`.cursor/skills/lua-engine-op/SKILL.md`).

## Making a change

Since both hosts execute these files verbatim, any behavior change here needs both consuming repos' own test suites re-run against the new commit (`cargo test -p registrator` in `inventor-api`; `swift test` in `inventor-ios`'s `Registrator` package) before bumping the submodule pointer in either — this repo's own `tests/run_all.lua` is necessary but not sufficient proof a change is safe.
