defmodule Xitdb.MixProject do
  use Mix.Project

  @version "2.0.1"
  @source_url "https://github.com/boxxxie/xitdb-elixir"

  def project do
    [
      app: :xitdb,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      test_pattern: "*_{test,spec}.exs",
      test_load_filters: [~r/_(test|spec)\.exs$/],
      compilers: [:odin_nif] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description:
        "Embedded, immutable single-file database for Elixir with native Access/Enum navigation, built-in time-travel & diffs, Pull projections, Datalog, and an Ash Framework DataLayer with full-text search.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.37 and >= 3.37.2", optional: true},
      {:spark, "~> 2.2", optional: true},
      {:nimble_options, "~> 1.1 and >= 1.1.1"},
      {:telemetry, "~> 1.3"},
      {:ash_phoenix, "~> 2.1", only: :test},
      {:simple_sat, "~> 0.1", only: :test},
      {:stream_data, "~> 1.1", optional: true},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      files:
        ~w(lib docs native/nif_entry.c native/xitdb_nif.odin native/xitdb-odin/xitdb .formatter.exs mix.exs README.md CHANGELOG.md usage-rules.md LICENSE),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md": [title: "Overview"],
        "docs/access-and-enumerable.md": [title: "Reading & Updating (Access & Enum)"],
        "docs/collections-and-indexing.md": [title: "Collections & Secondary Indexes"],
        "docs/time-travel-and-storage.md": [title: "Time-Travel, Diffs & Storage"],
        "docs/transaction-dsl.md": [title: "Transaction DSL"],
        "docs/path-and-pull-dsl.md": [title: "Path Selectors & Pull Projections"],
        "docs/datalog-dsl.md": [title: "Datalog & Graph Queries"],
        "docs/ash-and-spark.md": [title: "Ash Framework & Full-Text Search"],
        "docs/architecture-and-internals.md": [title: "Architecture & Internals"],
        "usage-rules.md": [title: "LLM & Agent Usage Rules"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        "Core Concepts": [
          "docs/access-and-enumerable.md",
          "docs/collections-and-indexing.md",
          "docs/time-travel-and-storage.md"
        ],
        "DSLs, Queries & Ash": [
          "docs/transaction-dsl.md",
          "docs/path-and-pull-dsl.md",
          "docs/datalog-dsl.md",
          "docs/ash-and-spark.md"
        ],
        "Internals & Reference": [
          "docs/architecture-and-internals.md",
          "usage-rules.md",
          "CHANGELOG.md",
          "LICENSE"
        ]
      ],
      groups_for_modules: [
        "Core Client": [
          Xitdb,
          Xitdb.Cursor,
          Xitdb.Collection,
          Xitdb.Error
        ],
        "DSLs, Pull & Sigils": [
          Xitdb.DSL,
          Xitdb.Pull,
          Xitdb.Sigils
        ],
        "Ash Integration": [
          Xitdb.Ash.DataLayer,
          Xitdb.Ash.Dsl,
          Xitdb.Ash.Store,
          Xitdb.Ash.Search,
          Xitdb.Ash.TestSandbox,
          Xitdb.Ash.Info,
          Xitdb.Ash.Tx,
          Xitdb.Ash.LeaseError
        ],
        "Ash DSL Entities & Internals": [
          Xitdb.Ash.Index,
          Xitdb.Ash.SearchField,
          Xitdb.Ash.Reference,
          Xitdb.Ash.NestedIn,
          Xitdb.Ash.Codec,
          Xitdb.Ash.Indexer,
          Xitdb.Ash.Query,
          Xitdb.Ash.Mutator,
          Xitdb.Ash.Transformers.BuildIndexPlan,
          Xitdb.Ash.Verifiers.VerifyNoSqlFragments,
          Xitdb.Ash.Verifiers.VerifyCrossStoreReferences
        ]
      ],
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md",
        "usage-rules.md",
        "docs/architecture-and-internals.md"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test"
      ]
    ]
  end
end

defmodule Mix.Tasks.Compile.OdinNif do
  @moduledoc false
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    priv_dir = Path.expand("priv")
    File.mkdir_p!(priv_dir)

    so_path = Path.join(priv_dir, "xitdb_nif.so")
    c_src = Path.expand("native/nif_entry.c")
    c_obj = Path.expand("native/nif_entry.o")
    odin_src = Path.expand("native/xitdb_nif.odin")
    odin_pkg_dir = Path.expand("native")
    xitdb_col_dir = Path.expand("native/xitdb-odin/xitdb")

    xitdb_sources = Path.wildcard(Path.join(xitdb_col_dir, "*.odin"))
    all_sources = [c_src, odin_src | xitdb_sources]

    if needs_compile?(so_path, all_sources) do
      odin_bin = System.find_executable("odin") || Mix.raise("odin compiler not found in PATH")
      cc_bin = System.find_executable("cc") || System.find_executable("gcc") || "cc"

      erts_include =
        Path.join([
          to_string(:code.root_dir()),
          "erts-#{:erlang.system_info(:version)}",
          "include"
        ])

      Mix.shell().info("Compiling xitdb Odin NIF (priv/xitdb_nif.so)...")

      {cc_out, cc_status} =
        System.cmd(
          cc_bin,
          ["-c", "-fPIC", "-O3", "-Wall", "-Wextra", "-I#{erts_include}", c_src, "-o", c_obj],
          stderr_to_stdout: true
        )

      if cc_status != 0 do
        Mix.raise("Failed to compile native/nif_entry.c:\n#{cc_out}")
      end

      {odin_out, odin_status} =
        System.cmd(
          odin_bin,
          [
            "build",
            odin_pkg_dir,
            "-build-mode:shared",
            "-out:#{so_path}",
            "-collection:xitdb=#{xitdb_col_dir}",
            "-extra-linker-flags:#{c_obj}",
            "-o:speed"
          ],
          stderr_to_stdout: true
        )

      if odin_status != 0 do
        Mix.raise("Failed to compile native/xitdb_nif.odin:\n#{odin_out}")
      end
    end

    Mix.Project.build_structure()
    {:ok, []}
  end

  defp needs_compile?(target, sources) do
    case File.stat(target) do
      {:ok, %{mtime: target_mtime}} ->
        Enum.any?(sources, fn src ->
          case File.stat(src) do
            {:ok, %{mtime: src_mtime}} -> src_mtime > target_mtime
            _ -> true
          end
        end)

      _ ->
        true
    end
  end
end
