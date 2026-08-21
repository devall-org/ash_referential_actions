defmodule AshReferentialActions.Verifiers.PairConsistency do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Ash.Resource.Relationships.{BelongsTo, HasMany, HasOne}
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    relationships = Ash.Resource.Info.relationships(dsl_state)

    with :ok <- verify_forwards(module, relationships) do
      verify_reverses(module, relationships)
    end
  end

  defp verify_forwards(module, relationships) do
    relationships
    |> Enum.filter(&(match?(%BelongsTo{}, &1) and lifecycle?(&1)))
    |> Enum.reduce_while(:ok, fn forward, :ok ->
      case verify_forward(module, forward) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp verify_reverses(module, relationships) do
    relationships
    |> Enum.filter(&(reverse?(&1) and lifecycle?(&1)))
    |> Enum.reduce_while(:ok, fn reverse, :ok ->
      case verify_reverse(module, reverse) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp lifecycle?(rel),
    do: AshReferentialActions.Info.action(rel) in [:cascade, :restrict, :nilify]

  defp reverse?(%kind{}) when kind in [HasMany, HasOne], do: true
  defp reverse?(_relationship), do: false

  defp verify_forward(module, forward) do
    destination = forward.destination

    if AshReferentialActions.Info.enabled?(destination) do
      matching =
        destination
        |> Ash.Resource.Info.relationships()
        |> Enum.filter(fn reverse ->
          reverse?(reverse) and reverse.destination == module and
            AshReferentialActions.Info.reverse_of?(reverse, forward)
        end)

      verify_matching_actions(module, forward, matching, "reverse")
    else
      error(module, forward, "#{inspect(destination)} must use AshReferentialActions")
    end
  end

  defp verify_reverse(module, reverse) do
    matching =
      reverse.destination
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(fn forward ->
        match?(%BelongsTo{}, forward) and forward.destination == module and
          AshReferentialActions.Info.reverse_of?(reverse, forward)
      end)

    verify_matching_actions(module, reverse, matching, "forward")
  end

  defp verify_matching_actions(module, relationship, matching, side) do
    expected = AshReferentialActions.Info.action(relationship)
    lifecycle = Enum.filter(matching, &lifecycle?/1)
    matching_actions = Enum.map(lifecycle, &AshReferentialActions.Info.action/1)

    cond do
      expected not in matching_actions ->
        error(
          module,
          relationship,
          "missing matching #{side} #{expected} relationship; " <>
            "matching lifecycle actions found: #{inspect(matching_actions)}"
        )

      Enum.any?(matching_actions, &(&1 != expected)) ->
        error(
          module,
          relationship,
          "conflicting lifecycle actions on the same key pair: #{inspect(matching_actions)}"
        )

      true ->
        :ok
    end
  end

  defp error(module, rel, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: module,
       path: [:relationships, rel.name],
       message: message
     )}
  end
end
