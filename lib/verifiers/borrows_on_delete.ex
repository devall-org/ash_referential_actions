defmodule AshBorrow.Verifiers.BorrowsOnDeleteRestrict do
  @moduledoc false
  # The foreign key of a `borrows` relationship is what excludes hard deletes
  # of borrowed records, so its reference must keep restrict semantics.
  # `:restrict` and `:nothing` both leave the database rejecting deletes of
  # referenced rows; `:delete` and `:nilify` would break the invariant.
  #
  # Reads the `[:postgres, :references]` section generically so ash_postgres
  # is not a dependency.
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @allowed_on_delete [nil, :restrict, :nothing]

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    borrows_names =
      dsl_state
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&AshBorrow.Info.borrows?/1)
      |> MapSet.new(& &1.name)

    dsl_state
    |> Verifier.get_entities([:postgres, :references])
    |> Kernel.||([])
    |> Enum.find(fn reference ->
      Map.get(reference, :relationship) in borrows_names and
        (Map.get(reference, :ignore?) == true or
           Map.get(reference, :on_delete) not in @allowed_on_delete)
    end)
    |> case do
      nil ->
        :ok

      reference ->
        relationship = Map.get(reference, :relationship)

        message =
          if Map.get(reference, :ignore?) == true do
            """
            The reference for `borrows :#{relationship}` sets `ignore?: true`, which \
            removes the foreign key constraint entirely.

            The database rejecting deletes of borrowed records is what keeps borrows \
            references from dangling — a borrows reference must create a real foreign key.
            """
          else
            """
            The reference for `borrows :#{relationship}` sets \
            `on_delete: #{inspect(Map.get(reference, :on_delete))}`.

            A borrows foreign key must keep restrict semantics (omit `on_delete`, \
            or use `:restrict`/`:nothing`): the database rejecting deletes of \
            borrowed records is what keeps borrows references from dangling.
            """
          end

        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:postgres, :references, relationship],
           message: message
         )}
    end
  end
end
