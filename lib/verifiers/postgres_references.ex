defmodule AshReferentialActions.Verifiers.PostgresReferences do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Ash.Resource.Relationships.BelongsTo
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    if Ash.Resource.Info.data_layer(dsl_state) == :"Elixir.AshPostgres.DataLayer" do
      verify_postgres(dsl_state)
    else
      :ok
    end
  end

  defp verify_postgres(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    forwards =
      dsl_state
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&match?(%BelongsTo{}, &1))
      |> Map.new(&{&1.name, &1})

    references = Verifier.get_entities(dsl_state, [:postgres, :references]) || []

    forwards
    |> Enum.find_value(fn {name, rel} ->
      reference = Enum.find(references, &(Map.get(&1, :relationship) == name))
      reference_error(module, rel, reference)
    end)
    |> case do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp reference_error(module, rel, reference) do
    case AshReferentialActions.Info.action(rel) do
      :restrict ->
        if reference &&
             (Map.get(reference, :ignore?) == true or
                Map.get(reference, :on_delete) not in [nil, :restrict, :nothing]) do
          error(module, rel, "restrict_belongs_to must keep database restrict semantics")
        end

      :nilify ->
        if is_nil(reference) or Map.get(reference, :ignore?) == true or
             Map.get(reference, :on_delete) != :nilify do
          error(
            module,
            rel,
            "nilify_belongs_to requires a PostgreSQL reference with on_delete: :nilify"
          )
        end

      _ ->
        nil
    end
  end

  defp error(module, rel, message) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:postgres, :references, rel.name],
      message: message
    )
  end
end
