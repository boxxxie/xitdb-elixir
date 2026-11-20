if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Dsl do
    @moduledoc """
    Spark DSL extension for `Xitdb.Ash.DataLayer` (`xitdb do ... end`).
    """

    alias Xitdb.Ash.{Compress, Index, NestedIn, Reference, SearchField}

    @index %Spark.Dsl.Entity{
      name: :index,
      describe: "Declares a single-attribute or composite `:sorted_map` B+Tree secondary index.",
      examples: [
        "index :status",
        "index [:status, :inserted_at], name: :idx_status_recent"
      ],
      target: Index,
      args: [:fields],
      identifier: {:auto, :unique_integer},
      schema: [
        fields: [
          type: {:wrap_list, :atom},
          required: true,
          doc: "Ordered attribute name(s) composing the B+Tree index key."
        ],
        name: [
          type: {:or, [:atom, :string]},
          doc: "Optional custom slot name under `idx.<collection>`."
        ]
      ]
    }

    @nested_in %Spark.Dsl.Entity{
      name: :nested_in,
      describe: "Co-locates records inside `root[parent_collection][parent_id][path]`.",
      examples: [
        "nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many"
      ],
      target: NestedIn,
      args: [:parent_collection],
      identifier: {:auto, :unique_integer},
      schema: [
        parent_collection: [
          type: :atom,
          required: true,
          doc: "Parent collection key at the `.xit` root."
        ],
        foreign_key: [
          type: :atom,
          required: true,
          doc: "Attribute on this resource storing the parent primary key."
        ],
        path: [
          type: :atom,
          required: true,
          doc: "Map key inside the parent entity cursor holding child cursor(s)."
        ],
        cardinality: [
          type: {:in, [:one, :many]},
          default: :many,
          doc: "Whether the parent slot stores `:many` keyed records or `:one` embedded map."
        ]
      ]
    }

    @search_field %Spark.Dsl.Entity{
      name: :search_field,
      describe:
        "Indexes an attribute (or resolved value) in `idx.search.<collection>` for BM25 + prefix search.",
      examples: [
        "search_field :full_name, boost: 3.0",
        "search_field :firm_name, boost: 2.0, resolver: &__MODULE__.resolve_firm_name/2"
      ],
      target: SearchField,
      args: [:field],
      identifier: :field,
      schema: [
        field: [
          type: :atom,
          required: true,
          doc: "Attribute name (or virtual label when `:resolver` is provided)."
        ],
        boost: [
          type: :float,
          default: 1.0,
          doc: "Positive BM25 field weight multiplier."
        ],
        resolver: [
          type: {:or, [{:fun, 2}, {:in, [nil]}]},
          doc: "Optional `(record, db) -> term()` callback for cross-collection fields."
        ]
      ]
    }

    @compress %Spark.Dsl.Entity{
      name: :compress,
      describe:
        "Configures transparent value-level or Parquet-style row-group compression for attribute(s).",
      examples: [
        "compress [:body, :html_edit_body], mode: :row_group, row_group_size: 128, dictionary: :email_html",
        "compress :attachment_blob, codec: :zstd, intern_above: 4096"
      ],
      target: Compress,
      args: [:fields],
      identifier: {:auto, :unique_integer},
      schema: [
        fields: [
          type: {:wrap_list, :atom},
          required: true,
          doc: "Attribute name(s) whose stored binary payloads are compressed."
        ],
        mode: [
          type: {:in, [:value, :row_group]},
          default: :value,
          doc:
            "Compression granularity (`:value` per attribute or `:row_group` columnar pages on bulk writes)."
        ],
        codec: [
          type: {:in, [:zstd, :zlib, :none]},
          default: :zstd,
          doc: "Compression codec (`:zstd` falls back to `:zlib` if runtime lacks `:zstd`)."
        ],
        level: [
          type: {:or, [:integer, {:in, [nil]}]},
          default: nil,
          doc: "Optional codec compression level."
        ],
        min_bytes: [
          type: :non_neg_integer,
          default: 128,
          doc: "Minimum byte length required before compressing in `:value` mode."
        ],
        min_savings: [
          type: :non_neg_integer,
          default: 16,
          doc: "Minimum byte reduction required to keep a compressed tag instead of raw bytes."
        ],
        dictionary: [
          type: {:or, [:atom, :string, {:in, [nil]}]},
          default: nil,
          doc: "Optional shared dictionary name stored under `__dicts`."
        ],
        intern_above: [
          type: {:or, [:pos_integer, {:in, [nil]}]},
          default: nil,
          doc: "Optional byte threshold above which payloads are content-addressed in `__blobs`."
        ],
        row_group_size: [
          type: :pos_integer,
          default: 128,
          doc: "Rows per immutable `\"XCP1\"` column page when `mode: :row_group`."
        ],
        encoding: [
          type: {:in, [:auto, :plain_block, :dict_rle, :dict_block]},
          default: :auto,
          doc:
            "Column page intra-page encoding (`:auto`, `:plain_block`, `:dict_rle`, or `:dict_block`)."
        ]
      ]
    }

    @reference %Spark.Dsl.Entity{
      name: :reference,
      describe:
        "Configures referential action when the referenced `belongs_to` parent is destroyed.",
      examples: [
        "reference :organization, on_delete: :nilify",
        "reference :organizer, on_delete: :restrict"
      ],
      target: Reference,
      args: [:relationship],
      identifier: :relationship,
      schema: [
        relationship: [
          type: :atom,
          required: true,
          doc: "Name of a `belongs_to` relationship on this resource."
        ],
        on_delete: [
          type: {:in, [:nothing, :delete, :nilify, :restrict]},
          default: :nothing,
          doc: "Action enforced atomically when the target parent record is destroyed."
        ]
      ]
    }

    @references %Spark.Dsl.Section{
      name: :references,
      describe: "Foreign-key `on_delete` rules within the same `.xit` store.",
      entities: [@reference]
    }

    @xitdb %Spark.Dsl.Section{
      name: :xitdb,
      describe:
        "Configures Xitdb storage, subtree nesting, B+Tree indexes, BM25 search, and FK rules.",
      entities: [@nested_in, @index, @search_field, @compress],
      sections: [@references],
      schema: [
        store: [
          type: :atom,
          doc:
            "Supervised `Xitdb.Ash.Store` module or registered name (falls back to `config :xitdb, :default_store` unless required by `BuildIndexPlan`)."
        ],
        collection: [
          type: :atom,
          doc: "Logical collection & sequence key in the `.xit` store."
        ],
        counted_set_fields: [
          type: {:list, :atom},
          default: [],
          doc: "Attributes backed by `:counted_hash_set` slots."
        ],
        index_relationships?: [
          type: :boolean,
          default: true,
          doc: "Automatically creates secondary B+Tree indexes for all `belongs_to` foreign keys."
        ]
      ]
    }

    use Spark.Dsl.Extension,
      sections: [@xitdb],
      transformers: [Xitdb.Ash.Transformers.BuildIndexPlan],
      verifiers: [
        Xitdb.Ash.Verifiers.VerifyNoSqlFragments,
        Xitdb.Ash.Verifiers.VerifyCrossStoreReferences
      ]
  end
end
