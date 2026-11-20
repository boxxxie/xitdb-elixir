defmodule Xitdb.Fuzz.ParsersAndCodecsFuzzTest do
  use ExUnit.Case, async: true
  use ExFuzz

  alias Ash.Resource.Attribute
  alias Xitdb.{Columnar, Compression, Error, Pull, Selector, Sigils}
  alias Xitdb.Ash.{Codec, Search}
  alias Xitdb.Columnar.Page

  @moduletag timeout: 500

  @selector_kinds [
    :hash_map,
    :counted_hash_map,
    :sorted_map,
    :hash_set,
    :counted_hash_set,
    :sorted_set
  ]

  if Code.ensure_loaded?(Ash.DataLayer) do
    defmodule StringPkDoc do
      @moduledoc false
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store Xitdb.TestSupport.MdmStore
        collection :fuzz_string_pk_docs
      end

      attributes do
        attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      end
    end

    defmodule CiStringPkDoc do
      @moduledoc false
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store Xitdb.TestSupport.MdmStore
        collection :fuzz_cistring_pk_docs
      end

      attributes do
        attribute(:id, :ci_string, primary_key?: true, allow_nil?: false, public?: true)
      end
    end

    defmodule UuidPkDoc do
      @moduledoc false
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store Xitdb.TestSupport.MdmStore
        collection :fuzz_uuid_pk_docs
      end

      attributes do
        uuid_primary_key(:id)
      end
    end

    defmodule IntegerPkDoc do
      @moduledoc false
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store Xitdb.TestSupport.MdmStore
        collection :fuzz_integer_pk_docs
      end

      attributes do
        attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      end
    end
  end

  fuzz "Selector parse_selector_steps, normalize_root_or_steps, and format_step round-trip",
       data <- binary(),
       seeds: [
         ".users.alice",
         ~S(@0.users["a.b"][0][[1]]),
         "#counts$sorted%set#%cset^sset",
         <<?., ?\", ?\\, ?\", ?\">>,
         <<0, 255>>
       ] do
    try do
      steps = Selector.parse_selector_steps(data, true)
      assert is_list(steps)
    rescue
      ArgumentError -> :ok
    end

    try do
      normalized = Selector.normalize_root_or_steps(data)
      assert is_list(normalized)
    rescue
      ArgumentError -> :ok
    end

    kind = Enum.at(@selector_kinds, :erlang.phash2(data, length(@selector_kinds)))
    formatted = Selector.format_step(kind, data)
    assert Selector.parse_selector_steps(formatted) == [{kind, data}]
  end

  fuzz "Sigils validate_selector! and validate_datalog! raise only ArgumentError and preserve balanced delimiters",
       data <- binary(),
       seeds: [
         ~S(.users["a"][0]),
         "find ?x where .users[?id].name = ?x",
         ~S(.unclosed["x),
         ~S(find ?x where .a = "\")
       ] do
    try do
      res = Sigils.validate_selector!(data)
      assert res == String.trim(data)
    rescue
      ArgumentError -> :ok
    end

    try do
      res = Sigils.validate_datalog!(data)
      assert res == String.trim(data)
    rescue
      ArgumentError -> :ok
    end

    formatted = Selector.format_step(:hash_map, data)
    assert Sigils.validate_selector!(formatted) == formatted
  end

  fuzz "Pull.compile and Pull.split_wildcard_plan handle arbitrary binaries safely",
       data <- binary(),
       seeds: [
         "*",
         "{*, profile{city}, todos[0..3]}",
         ~S({a, "b,c"{d}, *}),
         ""
       ] do
    case Pull.compile(data) do
      {:ok, compiled} ->
        assert is_binary(compiled)
        assert_wildcard_plan(Pull.split_wildcard_plan(compiled))

      {:error, %Xitdb.Error{reason: :invalid_pull_pattern}} ->
        :ok
    end

    assert_wildcard_plan(Pull.split_wildcard_plan(data))

    case decode_pull_list(data) do
      [] ->
        :ok

      fields ->
        case Pull.compile(fields) do
          {:ok, compiled} ->
            assert is_binary(compiled)
            assert_wildcard_plan(Pull.split_wildcard_plan(compiled))

          {:error, %Xitdb.Error{reason: :invalid_pull_pattern}} ->
            :ok
        end
    end
  end

  if Code.ensure_loaded?(Ash.DataLayer) do
    fuzz "Ash.Search.tokenize handles arbitrary bytes, invalid UTF-8, and NUL bytes without crashing",
         data <- binary(),
         seeds: [
           "Hello, World! 2026",
           "café naïve résumé",
           <<0, 1, 2>>,
           "a\x00b"
         ] do
      tokens = Search.tokenize(data)
      assert is_list(tokens)

      assert Enum.all?(tokens, fn tok ->
               is_binary(tok) and tok != "" and String.valid?(tok)
             end)
    end

    fuzz "Ash.Codec encode_doc_id, decode_doc_id, and composite encode_index_key preserve order and escape NUL/0xFF",
         data <- binary(),
         seeds: [
           <<0, 0, 255, 1>>,
           "alice\x00bob\xff",
           "550e8400-e29b-41d4-a716-446655440000",
           "12345"
         ] do
      assert Codec.encode_doc_id(data) === data

      for resource <- [
            __MODULE__.StringPkDoc,
            __MODULE__.CiStringPkDoc,
            __MODULE__.UuidPkDoc,
            __MODULE__.IntegerPkDoc
          ] do
        case Codec.decode_doc_id(resource, data) do
          {:ok, _decoded} -> :ok
          {:error, _reason} -> :ok
        end
      end

      attrs = [
        %Attribute{name: :a, type: Ash.Type.Binary, constraints: []},
        %Attribute{name: :b, type: Ash.Type.Integer, constraints: []}
      ]

      {s1, s2, n1, n2} = split_composite_inputs(data)
      k1 = Codec.encode_index_key(attrs, [s1, n1])
      k2 = Codec.encode_index_key(attrs, [s2, n2])

      assert compare_terms(k1, k2) == compare_terms({s1, n1}, {s2, n2})
    end
  end

  @fuzz_plain_page_seed Page.encode_page!(["alpha", "beta", nil, "gamma", "alpha"],
                          encoding: :plain_block,
                          codec: :zlib
                        )
  @fuzz_rle_page_seed Page.encode_page!(["h1", "h1", nil, "h2", "h2"],
                        encoding: :dict_rle,
                        codec: :zlib
                      )

  fuzz "Compression decompress, resolve_tagged, and Columnar parse_pointer bounds safety",
       data <- binary(),
       seeds: [
         <<0x10, 4::unsigned-little-32, 0x78, 0x9C, 0x00>>,
         <<0x10, 50_000_000::unsigned-little-32, 0x78, 0x9C>>,
         <<0x10, 10::unsigned-little-32, 5, "dname", 1, 2, 3>>,
         <<0x10, 0::256>>,
         <<0x10, 3::16-little, "col", 4::16-little, "body", 2, "p1", 0::32-little>>,
         <<>>
       ] do
    case Compression.decompress(data, max_decompressed_bytes: 65_536) do
      {:ok, bin} -> assert is_binary(bin) and byte_size(bin) <= 65_536
      {:error, %Error{}} -> :ok
    end

    for tag <- ["cz", "zs", "zd", "bp", "pg"] do
      case Compression.resolve_tagged(tag, data, nil, -1, max_decompressed_bytes: 65_536) do
        {:ok, val} -> assert is_nil(val) or (is_binary(val) and byte_size(val) <= 65_536)
        {:error, %Error{}} -> :ok
      end
    end

    case Columnar.parse_pointer(data) do
      {:ok, col, field, page_id, row_idx} ->
        assert byte_size(col) > 0 and byte_size(field) > 0 and byte_size(page_id) > 0 and
                 row_idx >= 0

      {:error, %Error{}} ->
        :ok
    end
  end

  fuzz "Columnar.Page decode_page and decode_row bounds safety on mutated XCP1 frames",
       data <- binary(),
       seeds: [
         @fuzz_plain_page_seed,
         @fuzz_rle_page_seed,
         <<"XCP1", 1, 1, 1, 10::32-little, 50_000_000::32-little, 0, 1, 2, 3>>,
         <<"XCP1", 2, 0, 1, 3::32-little, 16::32-little, 0, 0, 99, 1, 2, 3>>,
         <<"XCP1", 99, 0, 0, 0::64, 0>>,
         <<"NOPE">>
       ] do
    case Page.decode_page(data, max_decompressed_bytes: 65_536) do
      {:ok, %Page{} = page} ->
        case Page.decode_row(page, 0) do
          {:ok, v} -> assert is_nil(v) or is_binary(v)
          {:error, %Error{}} -> :ok
        end

        assert {:error, %Error{reason: :corrupt_column_page}} =
                 Page.decode_row(page, page.row_count)

      {:error, %Error{}} ->
        :ok
    end
  end

  defp assert_wildcard_plan({:single, pat}) when is_binary(pat), do: :ok
  defp assert_wildcard_plan({:merge_top, "*", pat}) when is_binary(pat), do: :ok

  defp decode_pull_list(<<>>), do: []

  defp decode_pull_list(data) do
    parts =
      data
      |> :binary.bin_to_list()
      |> Enum.chunk_every(4)
      |> Enum.take(4)
      |> Enum.with_index()

    Enum.map(parts, fn {bytes, idx} ->
      name = :erlang.list_to_binary(bytes)

      case rem(idx, 3) do
        0 -> name
        1 -> {name, 0..max(rem(hd(bytes), 8), 0)}
        2 -> {name, [:*]}
      end
    end)
  end

  defp split_composite_inputs(data) do
    len = byte_size(data)
    mid = div(len, 2)
    s1 = binary_part(data, 0, mid)
    s2 = binary_part(data, mid, len - mid)

    n1 =
      case data do
        <<x::signed-big-64, _::binary>> -> x
        <<x::signed-big-32, _::binary>> -> x
        <<x::signed-8, _::binary>> -> x
        <<>> -> 0
      end

    n2 =
      case s2 do
        <<y::signed-big-64, _::binary>> -> y
        <<y::signed-big-32, _::binary>> -> y
        <<y::signed-8, _::binary>> -> y
        <<>> -> -n1
      end

    {s1, s2, n1, n2}
  end

  defp compare_terms(a, b) when a < b, do: :lt
  defp compare_terms(a, b) when a > b, do: :gt
  defp compare_terms(_a, _b), do: :eq
end
