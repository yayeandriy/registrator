# registrator

The registration → accumulation → validation Lua algorithm library shared between [`inventor-api`](https://github.com/yayeandriy/inventor-api) (Rust, via [`mlua`](https://github.com/mlua-rs/mlua)) and [`inventor-ios`](https://github.com/yayeandriy/inventor-ios) (Swift, via a native embedded Lua 5.4 host) — see `SCHEMA.md` for the exact JSON shape each script takes and returns.

## Why a separate repo

Every algorithm here is written exactly once, in `lua/`, and is meant to run **byte-for-byte identically** wherever it's hosted — a backend admin tool and an on-device live camera pipeline need to agree on "is this part in the right place" without ever risking two independently-maintained native implementations drifting apart. Neither consuming repo owns this code; both vendor it (as a git submodule) and treat it as read-only.

## Contents

- `lua/registration.lua`, `lua/validation.lua`, `lua/presence_validator.lua`, `lua/presence_latch.lua`, `lua/accumulator.lua` — the algorithms. Each file's own header comment is the authoritative spec; `SCHEMA.md` is a field-level index into them.
- `lua/json.lua` — a small dependency-free JSON encode/decode, needed only by a host with no native Lua-table marshaling of its own (i.e. a plain C Lua VM driven over the `lua_State*` API, like the Swift host) — `mlua`'s serde bridge on the Rust side has no use for this file at all.
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

- `inventor-api`: `crates/registrator/src/{registration,validation,accumulator}.rs` each `include_str!` their script straight out of the submodule.
- `inventor-ios`: the `Registrator` Swift package's Lua harness loads each script (and `json.lua`) as a bundled resource out of the submodule.

## Making a change

Since both hosts execute these files verbatim, any behavior change here needs both consuming repos' own test suites re-run against the new commit (`cargo test -p registrator` in `inventor-api`; `swift test` in `inventor-ios`'s `Registrator` package) before bumping the submodule pointer in either — this repo's own `tests/run_all.lua` is necessary but not sufficient proof a change is safe.
