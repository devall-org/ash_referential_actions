defmodule AshReferentialActions.Transformers.ConfigurePostgresReferences do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Relationships.BelongsTo
  alias Spark.Dsl.Transformer

  @on_delete %{cascade: :delete, restrict: :restrict, nilify: :nilify}

  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    existing = Transformer.get_entities(dsl_state, [:postgres, :references])

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&match?(%BelongsTo{}, &1))
    |> Enum.filter(&(AshReferentialActions.Info.action(&1) in Map.keys(@on_delete)))
    |> Enum.reduce({:ok, dsl_state}, fn rel, {:ok, dsl_state} ->
      expected = Map.fetch!(@on_delete, AshReferentialActions.Info.action(rel))

      case Enum.find(existing, &(Map.get(&1, :relationship) == rel.name)) do
        nil ->
          with {:ok, reference} <-
                 Transformer.build_entity(
                   AshPostgres.DataLayer,
                   [:postgres, :references],
                   :reference,
                   relationship: rel.name,
                   on_delete: expected
                 ) do
            {:ok, Transformer.add_entity(dsl_state, [:postgres, :references], reference)}
          end

        reference when reference.on_delete in [nil, expected] ->
          {:ok, dsl_state}

        reference ->
          {:error,
           "reference :#{rel.name} has on_delete #{inspect(reference.on_delete)}, " <>
             "but #{AshReferentialActions.Info.action(rel)} requires #{inspect(expected)}"}
      end
    end)
  end
end
