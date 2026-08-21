defmodule AshReferentialActions.Transformers.AddNilifyActions do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Relationships.BelongsTo
  alias Spark.Dsl.Transformer

  @impl true
  def after?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def after?(_), do: false

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(match?(%BelongsTo{}, &1) and AshReferentialActions.Info.nilify?(&1)))
    |> Enum.reduce({:ok, dsl_state}, &add_action/2)
  end

  defp add_action(rel, {:ok, dsl_state}) do
    action_name = AshReferentialActions.Info.nilify_action_name(rel.source_attribute)

    if Enum.any?(Transformer.get_entities(dsl_state, [:actions]), &(&1.name == action_name)) do
      {:ok, dsl_state}
    else
      change =
        Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :change,
          change: Ash.Resource.Change.Builtins.set_attribute(rel.source_attribute, nil)
        )

      with {:ok, action} <-
             Transformer.build_entity(Ash.Resource.Dsl, [:actions], :update,
               name: action_name,
               public?: false,
               accept: [],
               changes: [change]
             ) do
        {:ok, Transformer.add_entity(dsl_state, [:actions], action)}
      end
    end
  end
end
