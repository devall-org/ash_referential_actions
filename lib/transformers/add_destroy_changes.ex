defmodule AshReferentialActions.Transformers.AddDestroyChanges do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Relationships.{HasMany, HasOne}
  alias Spark.Dsl.Transformer

  @impl true
  def after?(AshArchival.Resource.Transformers.SetupArchival), do: true
  def after?(AshReferentialActions.Transformers.AddNilifyActions), do: true
  def after?(_), do: false

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    relationships = Ash.Resource.Info.relationships(dsl_state)
    restrict? = Enum.any?(relationships, &reverse?(&1, :restrict))
    nilify_rels = Enum.filter(relationships, &reverse?(&1, :nilify))

    if restrict? or nilify_rels != [] do
      add_changes(dsl_state, restrict?, nilify_rels)
    else
      {:ok, dsl_state}
    end
  end

  defp reverse?(%kind{} = rel, action) when kind in [HasMany, HasOne],
    do: AshReferentialActions.Info.action(rel) == action

  defp reverse?(_rel, _action), do: false

  defp add_changes(dsl_state, restrict?, nilify_rels) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type == :destroy and &1.soft?))
    |> Enum.reduce({:ok, dsl_state}, fn destroy_action, {:ok, dsl_state} ->
      changes = nilify_changes(nilify_rels)
      changes = if restrict?, do: [restrict_change() | changes], else: changes
      new_action = %{destroy_action | changes: changes ++ destroy_action.changes}

      {:ok,
       Transformer.replace_entity(
         dsl_state,
         [:actions],
         new_action,
         &(&1.name == destroy_action.name)
       )}
    end)
  end

  defp restrict_change do
    Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :destroy], :change,
      change: {AshReferentialActions.Changes.EnsureNotRestricted, []}
    )
  end

  defp nilify_changes(rels) do
    Enum.map(rels, fn rel ->
      action = AshReferentialActions.Info.nilify_action_name(rel.destination_attribute)

      Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :destroy], :change,
        change: Ash.Resource.Change.Builtins.cascade_update(rel.name, action: action)
      )
    end)
  end
end
