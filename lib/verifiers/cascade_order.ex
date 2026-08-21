defmodule AshReferentialActions.Verifiers.CascadeOrder do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    archive_related = AshArchival.Resource.Info.archive_archive_related!(dsl_state)
    edges = restrict_edges(dsl_state, archive_related)

    if violated?(edges, archive_related) do
      module = Verifier.get_persisted(dsl_state, :module)

      {:error,
       Spark.Error.DslError.exception(
         module: module,
         path: [:referential_actions, :archive_last],
         message: """
         Cascade order archives restricted resources before their referrers.
         Set `referential_actions.archive_last` to:

           archive_last [#{Enum.map_join(suggestion(edges, archive_related), ", ", &":#{&1}")}]
         """
       )}
    else
      :ok
    end
  end

  defp restrict_edges(dsl_state, archive_related) do
    for restricted_name <- archive_related,
        restricted_rel = relationship(dsl_state, restricted_name),
        restricted_rel != nil,
        referrers = restricting_resources(restricted_rel.destination),
        referrers != MapSet.new(),
        referrer_name <- archive_related,
        referrer_name != restricted_name,
        referrer_rel = relationship(dsl_state, referrer_name),
        referrer_rel != nil,
        MapSet.member?(referrers, referrer_rel.destination),
        uniq: true do
      {referrer_name, restricted_name}
    end
  end

  defp violated?(edges, names) do
    position = names |> Enum.with_index() |> Map.new()
    Enum.any?(edges, fn {before, after_} -> position[before] > position[after_] end)
  end

  defp suggestion(edges, names) do
    nodes = edges |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()

    predecessors =
      Enum.reduce(edges, Map.new(nodes, &{&1, MapSet.new()}), fn {before, after_}, acc ->
        Map.update!(acc, after_, &MapSet.put(&1, before))
      end)

    nodes
    |> Enum.sort_by(&Enum.find_index(names, fn name -> name == &1 end))
    |> topo_sort(predecessors, [])
  end

  defp topo_sort([], _predecessors, acc), do: Enum.reverse(acc)

  defp topo_sort(remaining, predecessors, acc) do
    set = MapSet.new(remaining)

    case Enum.find(remaining, &MapSet.disjoint?(predecessors[&1], set)) do
      nil -> Enum.reverse(acc) ++ remaining
      name -> topo_sort(remaining -- [name], predecessors, [name | acc])
    end
  end

  defp relationship(dsl_state, name) do
    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == name))
  end

  defp restricting_resources(module) do
    module
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&AshReferentialActions.Info.restrict?/1)
    |> MapSet.new(& &1.destination)
  end
end
