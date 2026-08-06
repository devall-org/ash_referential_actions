defmodule AshBorrow.Verifiers.RequiresUses do
  @moduledoc false
  # A plain `belongs_to` to a resource with the AshBorrow extension is only allowed
  # when it is containment — that is, when the used resource declares the reverse
  # `has_many`/`has_one` back to this resource. A used resource may well own
  # children of its own; those children go down with it and need no guard.
  #
  # Without that reverse declaration the relationship is a non-owning
  # reference, which must be declared with `uses` so the guards can see it.
  use Spark.Dsl.Verifier

  alias Ash.Resource.Relationships.{BelongsTo, HasMany, HasOne}
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(fn
      %BelongsTo{} = rel ->
        not AshBorrow.Info.uses?(rel) and AshBorrow.Info.enabled?(rel.destination)

      %{} ->
        false
    end)
    |> Enum.find(&(not contained?(&1, module)))
    |> case do
      nil ->
        :ok

      rel ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:relationships, rel.name],
           message: """
           `belongs_to :#{rel.name}` targets #{inspect(rel.destination)}, which has the \
           AshBorrow extension, but #{inspect(rel.destination)} declares no relationship \
           back to #{inspect(module)}.

           If this is a non-owning reference, declare it with `uses` so the guards \
           can see it:

             uses :#{rel.name}, #{inspect(rel.destination)}

           If #{inspect(module)} is instead owned by #{inspect(rel.destination)}, \
           declare the containment on #{inspect(rel.destination)} with a plain \
           `has_many`/`has_one` back to #{inspect(module)}.
           """
         )}
    end
  end

  # Containment is declared by the owner: a plain (non-used_by) reverse
  # relationship on the destination, matching both key attributes.
  defp contained?(belongs_to, module) do
    belongs_to.destination
    |> Ash.Resource.Info.relationships()
    |> Enum.any?(fn
      %kind{} = rel when kind in [HasMany, HasOne] ->
        not AshBorrow.Info.used_by?(rel) and rel.destination == module and
          AshBorrow.Info.reverse_of?(rel, belongs_to)

      %{} ->
        false
    end)
  end
end
