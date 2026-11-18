# Specification: Upgrade xitdb to Elixir 1.20.5 & Erlang/OTP 29.1.2

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `elixir_1_20_upgrade_20261118`
> - **Type:** `chore`
> - **Target Runtime:** Elixir `1.20.5-otp-29` / Erlang/OTP `29.1.2`

---

## 1. Overview & Current State

- **Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
- **Current `mix.exs` constraint:** `~> 1.19` (target: `~> 1.19 (or ~> 1.20 if intentionally dropping 1.19 support)`)
- **Current `.tool-versions`:** Not present (inherits global `~/.tool-versions`)
- **CI Workflows:** `.github/workflows/ci.yml`
- **Dockerfiles:** None detected

### Deployment / Runtime Notes
Library/NIF repo: `.github/workflows/ci.yml` already tests `1.20` on OTP `28`; add OTP `29` (`1.20.5` / `29.1.2`) and verify Zig/C NIF compilation on OTP 29.

---

## 2. Functional Requirements

1. **Toolchain & Dependency Alignment:**
   - Pin `erlang 29.1.2` and `elixir 1.20.5-otp-29` in `.tool-versions`.
   - Update `mix.exs` `:elixir` constraint to `~> 1.19 (or ~> 1.20 if intentionally dropping 1.19 support)` and verify all `mix.lock` dependencies compile cleanly on Erlang/OTP `29.1.2` + Elixir `1.20.5`.
2. **Elixir 1.19–1.20 & OTP 28/29 Remediation:**
- Fix any Elixir 1.19/1.20 gradual type-system warnings (struct updates without prior `%Struct{} = var` pattern match, protocol dispatch errors, guard/whole-body/map inference errors, redundant/unreachable clauses).
- Pin dynamic bitstring size variables (`<<x::binary-size(^len), rest::binary>>`) per Elixir 1.20.
- Run `mix format --migrate` (reviewing `unless` -> `if !`, charlists -> `~c`, bitstring parens).
- Move any compile-time `~r/.../` module attributes or `defstruct` regex defaults into runtime functions or `~r/.../E` for OTP 28/29 NIF regex compatibility.
- Move `:preferred_cli_env` / `:preferred_envs` out of `def project` into `def cli` in `mix.exs` (deprecated in Elixir 1.19).
- Decide whether `mix.exs` keeps a wider minimum floor (e.g. `~> 1.19`) for downstream compatibility while testing & pinning `1.20.5-otp-29` in `.tool-versions` and CI, or bumps `elixir:` to `~> 1.20`.
3. **CI / Container Alignment:**
   - Update all CI workflow matrices/images (`.github/workflows/ci.yml`) and container base images (None detected) to `1.20.5` / `29.1.2`.

---

## 3. Acceptance Criteria

- [ ] `.tool-versions` pins `erlang 29.1.2` and `elixir 1.20.5-otp-29`.
- [ ] `mix.exs`, CI workflows, and Dockerfiles (if present) reflect the target Elixir `1.20.5` / OTP `29.1.2` configuration.
- `mix precommit` passes with zero warnings/errors.
