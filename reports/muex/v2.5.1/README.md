# Muex Mutation Testing Report — `v2.5.1` (`d631326`)

- **Commit**: `d631326` (`chore(release): prepare v2.5.1`)
- **Command**:
  ```bash
  mix do run -e "Application.ensure_all_started(:tools)" + muex \
    --mirror native \
    --concurrency 8 \
    --timeout 30000 \
    --coverage-guided \
    --preset ash \
    --verbose \
    --fail-at 0 \
    --format json \
    --output muex-report.json
  ```
- **Runner**: Hetzner `cpx62` (`16` vCPU AMD EPYC-Genoa, `32 GB` RAM, Ubuntu 24.04, OTP `29.1.2`, Elixir `1.20.5`, Odin `dev-2026-10`), with `deps/muex` patched for per-worker state isolation, AST module-name extraction (`if Code.ensure_loaded?/defimpl`), and parallel coverage collection.

## Summary

| Metric | Value |
| --- | ---: |
| Mutation Score | `62.23%..62.49%` |
| Total Mutants | `5,620` |
| Killed | `2,406` |
| Survived | `1,450` |
| Invalid | `1,086` |
| Timed Out | `10` |
| Equivalent | `180` |
| No Coverage | `488` |

## Artifacts

- [`muex-report.parquet`](muex-report.parquet) (`4.7 MiB`, ZSTD Parquet — `5,620` rows across `43` files, converted from `131 MiB` JSON)
- [`summary_by_file.tsv`](summary_by_file.tsv)

## Querying with DuckDB

```sql
SELECT file, count(*) FILTER (status = 'survived') AS survived
FROM 'reports/muex/v2.5.1/muex-report.parquet'
GROUP BY file
ORDER BY survived DESC;
```
