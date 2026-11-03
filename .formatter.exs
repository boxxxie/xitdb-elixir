locals_without_parens = [
  scenario: 2,
  # Xitdb.DSL transaction operations
  put: 2,
  update: 2,
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
  abort: 1,
  # Xitdb.DSL Datalog clauses
  find: 1,
  find: 2,
  find: 3,
  find: 4,
  from: 1,
  where: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,benchmarks}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
