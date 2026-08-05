defmodule AshBorrow.Borrowable.AddGuard do
  @moduledoc false
  # Prepends AshBorrow.Changes.EnsureNotBorrowed to every destroy action of a
  # borrowable resource, so a borrowed record can neither be hard-deleted nor
  # archived (archival rewrites destroys into soft updates, keeping the
  # change) while live borrowers exist.
  #
  # Ordering mirrors AshArchival's SetupArchival and additionally runs before
  # it, so the guard is in place before archival rewrites the destroy actions.
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # `defaults [:destroy]` is expanded into a real destroy action by
  # SetPrimaryActions, so the guard must be added after it; SetupArchival then
  # rewrites the destroys into soft updates while keeping existing changes.
  @impl true
  def after?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def after?(_), do: false

  @impl true
  def before?(AshArchival.Resource.Transformers.SetupArchival), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    # Nothing to enumerate without borrowed_by edges. A borrowable that is
    # actually borrowed always has them (the borrower-side verifier requires
    # a matching one), so skipping here only spares resources nobody borrows.
    if Enum.any?(Ash.Resource.Info.relationships(dsl_state), &AshBorrow.Info.borrowed_by?/1) do
      add_guard(dsl_state)
    else
      {:ok, dsl_state}
    end
  end

  defp add_guard(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type == :destroy))
    |> Enum.reduce({:ok, dsl_state}, fn destroy_action, {:ok, dsl_state} ->
      with {:ok, guard} <-
             Transformer.build_entity(Ash.Resource.Dsl, [:actions, :destroy], :change,
               change: {AshBorrow.Changes.EnsureNotBorrowed, []}
             ) do
        new_action = %{destroy_action | changes: [guard | destroy_action.changes]}

        {:ok,
         Transformer.replace_entity(
           dsl_state,
           [:actions],
           new_action,
           &(&1.name == destroy_action.name)
         )}
      end
    end)
  end
end
