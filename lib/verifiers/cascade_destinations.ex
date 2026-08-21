defmodule AshReferentialActions.Verifiers.CascadeDestinations do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&AshReferentialActions.Info.cascade?/1)
    |> Enum.reject(&match?(%Ash.Resource.Relationships.BelongsTo{}, &1))
    |> Enum.find_value(&destination_error(module, &1))
    |> case do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp destination_error(module, rel) do
    case Ash.Resource.Info.primary_action(rel.destination, :destroy) do
      nil ->
        error(
          module,
          rel,
          "cascade destination #{inspect(rel.destination)} has no primary destroy action"
        )

      %{soft?: true, manual: nil, changes: []} ->
        if Ash.Resource.Info.changes(rel.destination, :destroy) == [] do
          error(
            module,
            rel,
            "cascade destination #{inspect(rel.destination)} has a no-op soft destroy"
          )
        end

      %{soft?: true} ->
        nil

      %{soft?: false} ->
        error(
          module,
          rel,
          "cascade destination #{inspect(rel.destination)} would be hard-deleted"
        )
    end
  end

  defp error(module, rel, message) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:relationships, rel.name],
      message: message
    )
  end
end
