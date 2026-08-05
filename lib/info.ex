defmodule AshBorrow.Info do
  @moduledoc """
  Introspection helpers for AshBorrow.
  """

  @doc "Returns true if the relationship was declared with `borrows`."
  def borrows?(relationship), do: Map.get(relationship, :__borrows__, false) == true

  @doc "Returns true if the relationship was declared with `borrowed_by`."
  def borrowed_by?(relationship), do: Map.get(relationship, :__borrowed_by__, false) == true

  @doc "Returns true if the resource module uses the `AshBorrow.Borrowable` extension."
  def borrowable?(resource) when is_atom(resource) do
    AshBorrow.Borrowable in (Spark.Dsl.Extension.get_persisted(resource, :extensions) || [])
  end
end
