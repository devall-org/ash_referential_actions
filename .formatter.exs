spark_locals_without_parens =
  for action <- [:cascade, :restrict, :nilify, :view],
      type <- [:belongs_to, :has_many, :has_one],
      arity <- [2, 3],
      variant <- if(type == :belongs_to, do: [nil, :req, :req_priv, :opt, :opt_priv], else: [nil]),
      not (action == :nilify and variant in [:req, :req_priv]) do
    name =
      [variant, action, type]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("_")
      |> String.to_atom()

    {name, arity}
  end

[
  import_deps: [:ash, :ash_archival, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens
]
