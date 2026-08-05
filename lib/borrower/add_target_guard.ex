defmodule AshBorrow.Borrower.AddTargetGuard do
  @moduledoc false
  # Prepends AshBorrow.Changes.EnsureTargetLive to every create and update
  # action of a borrower resource, so a borrows foreign key can never be
  # pointed at an archived or missing target.
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # `defaults [:create, :update]` are expanded into real actions by
  # SetPrimaryActions, so the guard must be added after it.
  @impl true
  def after?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def after?(_), do: false

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type in [:create, :update]))
    |> Enum.reduce({:ok, dsl_state}, fn action, {:ok, dsl_state} ->
      with {:ok, guard} <-
             Transformer.build_entity(Ash.Resource.Dsl, [:actions, action.type], :change,
               change: {AshBorrow.Changes.EnsureTargetLive, []}
             ) do
        new_action = %{action | changes: [guard | action.changes]}

        {:ok,
         Transformer.replace_entity(
           dsl_state,
           [:actions],
           new_action,
           &(&1.name == action.name)
         )}
      end
    end)
  end
end
