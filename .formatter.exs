spark_locals_without_parens = [
  opt_priv_uses: 2,
  opt_priv_uses: 3,
  opt_uses: 2,
  opt_uses: 3,
  req_priv_uses: 2,
  req_priv_uses: 3,
  req_uses: 2,
  req_uses: 3,
  used_by: 2,
  used_by: 3,
  uses: 2,
  uses: 3
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
