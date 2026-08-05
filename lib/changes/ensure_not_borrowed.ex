defmodule AshBorrow.Changes.EnsureNotBorrowed do
  @moduledoc """
  Runtime guard added to every destroy action of an `AshBorrow.Borrowable`
  resource: the destroy (hard delete, or archive when the resource is
  archival) is rejected while live borrowers exist.

  Borrowers are enumerated through the resource's `borrowed_by` relationships
  and counted via each relationship's declared `read_action` (or the
  borrower's primary read — a verifier rejects a filtered primary read as
  the default), so action-level read filters cannot silently hide live
  borrowers. Archival's global `is_nil(archived_at)` preparation still
  applies — an archived borrower does not block. Inside a transaction, borrowers archived
  earlier in the same transaction are already invisible, which lets an
  ancestor cascade pass deterministically as long as it archives borrowers
  before the borrowable (see the `order` option of `ash_cascade_archival`).

  This is an application-level check: unlike the foreign key restricting hard
  deletes, it is not serialized by the database, so a borrow created
  concurrently with a destroy can theoretically slip through.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &ensure_not_borrowed/1)
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "AshBorrow.Changes.EnsureNotBorrowed must query borrowers"}
  end

  defp ensure_not_borrowed(changeset) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&AshBorrow.Info.borrowed_by?/1)
    |> Enum.reduce(changeset, fn rel, changeset ->
      source_value = AshBorrow.Query.data_attribute!(changeset, rel.source_attribute)

      borrowed? =
        AshBorrow.Query.exists?(rel, [{rel.destination_attribute, source_value}], changeset)

      if borrowed? do
        Ash.Changeset.add_error(
          changeset,
          "cannot destroy #{inspect(changeset.resource)}: still borrowed via :#{rel.name}"
        )
      else
        changeset
      end
    end)
  end
end
