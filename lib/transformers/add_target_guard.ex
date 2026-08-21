defmodule AshOwnership.Transformers.AddTargetGuard do
  @moduledoc false
  # Prepends AshOwnership.Changes.EnsureTargetLive to every create and update
  # action of a user resource, so a locks foreign key can never be
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
    # Nothing to guard without locks edges. Skipping keeps the extension
    # free to sit on a base resource module: resources that use nothing
    # are untouched, and in particular stay atomic-capable for bulk updates.
    if Enum.any?(Ash.Resource.Info.relationships(dsl_state), &AshOwnership.Info.locks?/1) do
      add_guard(dsl_state)
    else
      {:ok, dsl_state}
    end
  end

  defp add_guard(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type in [:create, :update]))
    |> Enum.reduce({:ok, dsl_state}, fn action, {:ok, dsl_state} ->
      with {:ok, guard} <-
             Transformer.build_entity(Ash.Resource.Dsl, [:actions, action.type], :change,
               change: {AshOwnership.Changes.EnsureTargetLive, []}
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
