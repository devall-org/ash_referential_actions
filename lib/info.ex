defmodule AshBorrow.Info do
  @moduledoc """
  Introspection helpers for AshBorrow.
  """

  @doc "Returns true if the relationship was declared with `uses`."
  def uses?(relationship), do: Map.get(relationship, :__uses__, false) == true

  @doc "Returns true if the relationship was declared with `used_by`."
  def used_by?(relationship), do: Map.get(relationship, :__used_by__, false) == true

  @doc "Returns true if the resource module has the `AshBorrow` extension."
  def enabled?(resource) when is_atom(resource) do
    AshBorrow in (Spark.Dsl.Extension.get_persisted(resource, :extensions) || [])
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
