spark_locals_without_parens = [
  borrowed_by: 2,
  borrowed_by: 3,
  borrows: 2,
  borrows: 3
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
