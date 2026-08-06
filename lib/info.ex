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

  @doc """
  Returns true if `reverse` (a `has_many`/`has_one`) is the reverse side of
  `forward` (a `belongs_to`): both key attributes line up.

  Checking only one attribute would accept a mis-wired pair whose query never
  finds the rows it is meant to find.
  """
  def reverse_of?(reverse, forward) do
    reverse.destination_attribute == forward.source_attribute and
      reverse.source_attribute == forward.destination_attribute
  end
end
