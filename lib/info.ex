defmodule AshOwnership.Info do
  @moduledoc """
  Introspection helpers for AshOwnership.
  """

  @doc "Returns true if the relationship was declared with `locks`."
  def locks?(relationship), do: Map.get(relationship, :__locks__, false) == true

  @doc "Returns true if the relationship was declared with `refers`."
  def refers?(relationship), do: Map.get(relationship, :__refers__, false) == true

  @doc "Returns true if the relationship was declared with `locked_by`."
  def locked_by?(relationship), do: Map.get(relationship, :__locked_by__, false) == true

  @doc "Returns true if the resource module has the `AshOwnership` extension."
  def enabled?(resource) when is_atom(resource) do
    AshOwnership in (Spark.Dsl.Extension.get_persisted(resource, :extensions) || [])
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
