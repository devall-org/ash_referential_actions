defmodule AshBorrow.Verifiers.BorrowsTargetBorrowable do
  @moduledoc false
  # Every `borrows` relationship must target an `AshBorrow.Borrowable` resource.
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&AshBorrow.Info.borrows?/1)
    |> Enum.find(&(not AshBorrow.Info.borrowable?(&1.destination)))
    |> case do
      nil ->
        :ok

      rel ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:relationships, rel.name],
           message: """
           `borrows :#{rel.name}` targets #{inspect(rel.destination)}, which is not borrowable.

           Add the `AshBorrow.Borrowable` extension to #{inspect(rel.destination)},
           or use a regular `belongs_to` if this is a containment relationship.
           """
         )}
    end
  end
end
