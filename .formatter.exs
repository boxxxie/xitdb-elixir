locals_without_parens = [
  scenario: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,benchmarks}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
