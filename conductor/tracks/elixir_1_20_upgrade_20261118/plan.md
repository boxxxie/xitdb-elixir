# Implementation Plan: Upgrade xitdb to Elixir 1.20.5 & Erlang/OTP 29.1.2

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `elixir_1_20_upgrade_20261118`
> - **Specification:** [`./spec.md`](./spec.md)

---

## Phase 1: Toolchain Pins, `mix.exs` & Dependency Verification

- [ ] Task: Update toolchain version pins and `mix.exs`
    - [ ] Set `erlang 29.1.2` and `elixir 1.20.5-otp-29` in `.tool-versions`
    - [ ] Update `:elixir` in `mix.exs` (`~> 1.19` -> `~> 1.19 (or ~> 1.20 if intentionally dropping 1.19 support)`)
    - [ ] Move `preferred_envs` from `def project` to `def cli` in `mix.exs`
    - [ ] Update Elixir/OTP versions (and `dialyzer-plt` cache keys if applicable) in `.github/workflows/ci.yml`
- [ ] Task: Verify dependency compatibility under Elixir `1.20.5-otp-29`
    - [ ] Clean build (`rm -rf _build/dev _build/test`) and run `mix deps.get && mix deps.compile`
    - [ ] Update any Hex deps in `mix.lock` that fail to compile on Erlang/OTP 29 / Elixir 1.20
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Toolchain Pins & Dependency Verification' (Protocol in workflow.md)

---

## Phase 2: Compiler, Type-System & Deprecation Remediation

- [ ] Task: Apply mechanical migrations and compile with `--warnings-as-errors`
    - [ ] Run `mix format --migrate` and review AST diff
    - [ ] Run `MIX_ENV=test mix compile --warnings-as-errors` and catalog all Elixir 1.19/1.20 warnings
- [ ] Task: Resolve type-checker, bitstring, struct-update, and OTP 28/29 regex warnings
    - [ ] Ensure `%Struct{} = var` pattern matches precede struct updates (`%Struct{var | ...}`)
    - [ ] Pin dynamic bitstring size variables (`<<x::size(^len), ...>>`)
    - [ ] Replace any `@attr ~r/.../` or `defstruct` regex defaults with runtime `~r/.../` or `~r/.../E`
    - [ ] Resolve any Elixir 1.20 guard/whole-body/map typing or unreachable-clause warnings
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Compiler & Type-System Remediation' (Protocol in workflow.md)

---

## Phase 3: Full Verification Suite

- [ ] Task: Run all project verification gates on Elixir `1.20.5-otp-29`
    - [ ] Run `mix precommit` and confirm exit status 0
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Full Verification Suite' (Protocol in workflow.md)
