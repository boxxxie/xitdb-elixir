defmodule Xitdb.NIF do
  @moduledoc false
  @on_load :load_nif

  def load_nif do
    nif_path =
      :xitdb
      |> :code.priv_dir()
      |> Path.join("xitdb_nif")
      |> String.to_charlist()

    :erlang.load_nif(nif_path, 0)
  end

  def nif_open(_backend, _path, _hash), do: :erlang.nif_error(:nif_not_loaded)
  def nif_close(_db_ref), do: :erlang.nif_error(:nif_not_loaded)
  def nif_sync(_db_ref), do: :erlang.nif_error(:nif_not_loaded)
  def nif_info(_db_ref), do: :erlang.nif_error(:nif_not_loaded)
  def nif_moment_slot(_db_ref, _moment_idx), do: :erlang.nif_error(:nif_not_loaded)
  def nif_slot_get_key(_db_ref, _tag_id, _val, _key), do: :erlang.nif_error(:nif_not_loaded)
  def nif_slot_get_index(_db_ref, _tag_id, _val, _index), do: :erlang.nif_error(:nif_not_loaded)
  def nif_slot_count(_db_ref, _tag_id, _val), do: :erlang.nif_error(:nif_not_loaded)
  def nif_slot_contains(_db_ref, _tag_id, _val, _key), do: :erlang.nif_error(:nif_not_loaded)
  def nif_slot_slice(_db_ref, _tag_id, _val, _start, _len), do: :erlang.nif_error(:nif_not_loaded)

  def nif_slot_entries(_db_ref, _tag_id, _val, _offset, _limit),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_slot_materialize(_db_ref, _tag_id, _val, _full), do: :erlang.nif_error(:nif_not_loaded)
  def nif_transact(_db_ref, _base_moment, _ops, _doc), do: :erlang.nif_error(:nif_not_loaded)
  def nif_select(_db_ref, _moment_idx, _selector), do: :erlang.nif_error(:nif_not_loaded)
  def nif_pull(_db_ref, _tag_id, _val, _pattern), do: :erlang.nif_error(:nif_not_loaded)
  def nif_diff_moments(_db_ref, _moment_a, _moment_b), do: :erlang.nif_error(:nif_not_loaded)
  def nif_history_of(_db_ref, _selector), do: :erlang.nif_error(:nif_not_loaded)
  def nif_query_datalog(_db_ref, _moment_idx, _query_str), do: :erlang.nif_error(:nif_not_loaded)
  def nif_compact(_db_ref, _target_path), do: :erlang.nif_error(:nif_not_loaded)

  def nif_sorted_map_seek(_db_ref, _slot_tag_id, _slot_val_int, _prefix_bin, _limit_int),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_sorted_map_seek(
        _db_ref,
        _slot_tag_id,
        _slot_val_int,
        _start_key_bin,
        _limit_int,
        _prefix_only
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def nif_bm25_search(
        _db_ref,
        _root_tag_id,
        _root_val_int,
        _collection_bin,
        _query_terms,
        _limit_int,
        _opts_map
      ),
      do: :erlang.nif_error(:nif_not_loaded)
end
