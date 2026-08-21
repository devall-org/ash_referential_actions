spark_locals_without_parens =
  for action <- [:cascade, :restrict, :nilify, :view],
      type <- [:belongs_to, :has_many, :has_one],
      arity <- [2, 3] do
    name = :"#{action}_#{type}"

    {name, arity}
  end

[
  import_deps: [:ash, :ash_archival, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
