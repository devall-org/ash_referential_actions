defmodule AshBorrow.Verifiers.UsesTargetEnabled do
  @moduledoc false
  # Every `uses` relationship must target a resource with the AshBorrow
  # extension, which is what makes the destroy guard and its verifiers apply.
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&AshBorrow.Info.uses?/1)
    |> Enum.find(&(not AshBorrow.Info.enabled?(&1.destination)))
    |> case do
      nil ->
        :ok

      rel ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:relationships, rel.name],
           message: """
           `uses :#{rel.name}` targets #{inspect(rel.destination)}, which does not have the
           `AshBorrow` extension, so nothing would guard it.

           Add `AshBorrow` to #{inspect(rel.destination)}, or use a regular `belongs_to`
           if this is a containment relationship.
           """
         )}
    end
  end
end
