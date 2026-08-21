spark_locals_without_parens = [
  opt_priv_locks: 2,
  opt_priv_locks: 3,
  opt_locks: 2,
  opt_locks: 3,
  req_priv_locks: 2,
  req_priv_locks: 3,
  req_locks: 2,
  req_locks: 3,
  locked_by: 2,
  locked_by: 3,
  locks: 2,
  locks: 3
]

[
  import_deps: [:spark, :ash],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}"
  ],
  plugins: [Spark.Formatter],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
