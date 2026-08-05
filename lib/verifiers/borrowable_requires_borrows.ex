defmodule AshBorrow.Verifiers.BorrowableRequiresBorrows do
  @moduledoc false
  # A plain `belongs_to` must not target an `AshBorrow.Borrowable` resource:
  # references to borrowable resources are non-owning by definition and must
  # be declared with `borrows`.
  use Spark.Dsl.Verifier

  alias Ash.Resource.Relationships.BelongsTo
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.find(fn
      %BelongsTo{} = rel ->
        not AshBorrow.Info.borrows?(rel) and AshBorrow.Info.borrowable?(rel.destination)

      %{} ->
        false
    end)
    |> case do
      nil ->
        :ok

      rel ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:relationships, rel.name],
           message: """
           `belongs_to :#{rel.name}` targets #{inspect(rel.destination)}, which is borrowable.

           References to a borrowable resource are non-owning and must be declared with:

             borrows :#{rel.name}, #{inspect(rel.destination)}
           """
         )}
    end
  end
end
