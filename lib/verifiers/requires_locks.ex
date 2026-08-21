defmodule AshOwnership.Verifiers.RequiresLocks do
  @moduledoc false
  # A plain `belongs_to` to a resource with the AshOwnership extension is only allowed
  # when it is containment — that is, when the locked resource declares the reverse
  # `has_many`/`has_one` back to this resource. A locked resource may well own
  # children of its own; those children go down with it and need no guard.
  #
  # Without that reverse declaration the relationship is a non-owning
  # reference, which must be declared with `locks` so the guards can see it.
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
        not AshOwnership.Info.locks?(rel) and not AshOwnership.Info.refers?(rel) and
          AshOwnership.Info.enabled?(rel.destination)

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
           AshOwnership extension, but #{inspect(rel.destination)} declares no relationship \
           back to #{inspect(module)}.

           If this is a non-owning reference, declare it with `locks` so the guards \
           can see it:

             locks :#{rel.name}, #{inspect(rel.destination)}

           If #{inspect(module)} is instead owned by #{inspect(rel.destination)}, \
           declare the containment on #{inspect(rel.destination)} with a plain \
           `has_many`/`has_one` back to #{inspect(module)}.

           If this only carries a referenced resource's id and the real parent is another \
           relationship, declare it with `refers`:

             refers :#{rel.name}, #{inspect(rel.destination)}
           """
         )}
    end
  end

  # Containment is declared by the owner: a plain (non-locked_by) reverse
  # relationship on the destination, matching both key attributes.
  defp contained?(belongs_to, module) do
    belongs_to.destination
    |> Ash.Resource.Info.relationships()
    |> Enum.any?(fn
      %kind{} = rel when kind in [HasMany, HasOne] ->
        not AshOwnership.Info.locked_by?(rel) and rel.destination == module and
          AshOwnership.Info.reverse_of?(rel, belongs_to)

      %{} ->
        false
    end)
  end
end
