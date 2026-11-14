dsl_locals_without_parens = [
  # Xitdb.DSL transaction blocks
  tx: 2,
  tx: 3,
  tx!: 2,
  tx!: 3,
  tx_for: 2,
  tx_for: 3,
  tx_for: 4,
  tx_for!: 2,
  tx_for!: 3,
  tx_for!: 4,
  # Xitdb.DSL transaction operations
  put: 1,
  put: 2,
  update: 2,
  update: 3,
  rm: 1,
  append: 2,
  insert: 2,
  insert: 3,
  slice: 2,
  slice: 3,
  fork: 2,
  index_on: 3,
  init_col: 2,
  reset_col: 2,
  meta: 2,
  instant: 1,
  abort: 1,
  # Xitdb.DSL Datalog blocks & clauses
  datalog: 1,
  query: 2,
  query: 3,
  query!: 2,
  query!: 3,
  find: 1,
  find: 2,
  find: 3,
  find: 4,
  from: 1,
  where: 1
]

spark_locals_without_parens = [
  # Shared & Xitdb.Ash.DataLayer options/entities
  store: 1,
  collection: 1,
  nested_in: 1,
  nested_in: 2,
  index: 1,
  index: 2,
  index_relationships?: 1,
  counted_set_fields: 1,
  search_field: 1,
  search_field: 2,
  reference: 1,
  reference: 2,
  # Xitdb.Ash.Resource (v1.0.2 hybrid MDM projection) options
  merge_redirect_collection: 1,
  locked_ids_set: 1,
  companion_resource: 1,
  editable_fields: 1,
  passthru_fields: 1,
  computed_xitdb_fields: 1,
  field_aliases: 1,
  indexes: 1,
  sync_update_action: 1,
  ignored_sync_attributes: 1,
  lock_action: 1,
  unlock_action: 1,
  lock_change: 1
]

exported_locals = dsl_locals_without_parens ++ spark_locals_without_parens

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,benchmarks}/**/*.{ex,exs}"],
  locals_without_parens: exported_locals ++ [scenario: 2],
  export: [locals_without_parens: exported_locals]
]
