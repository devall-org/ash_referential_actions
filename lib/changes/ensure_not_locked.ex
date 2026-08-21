defmodule AshOwnership.Changes.EnsureNotLocked do
  @moduledoc """
  Runtime guard added to every destroy action of a resource that declares
  `locked_by`: the destroy (hard delete, or archive when the resource is
  archival) is rejected while live locking records exist.

  Locking records are enumerated through the resource's `locked_by` relationships
  and counted via each relationship's declared `read_action` (or the
  locking resource's primary read — a verifier rejects a filtered primary read as
  the default), so action-level read filters cannot silently hide live
  locking records. Archival's global `is_nil(archived_at)` preparation still
  applies — an archived locking record does not block. Inside a transaction, locking records archived
  earlier in the same transaction are already invisible, which lets an
  reference cascade pass deterministically as long as it archives locking records
  before the locked resource (see the `archive_last` option of `ash_cascade_archival`).

  Before counting, the record being destroyed is locked `FOR UPDATE` where the
  data layer supports it, pairing with the `FOR SHARE` lock
  `AshOwnership.Changes.EnsureTargetLive` takes on the same row. That closes the
  window where a lock is created concurrently with a destroy. On data layers
  without lock support (e.g. ETS) both stay plain application-level checks and
  the race remains.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &ensure_not_locked/1)
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "AshOwnership.Changes.EnsureNotLocked must query locking records"}
  end

  # Ash stops at the first error, and this guard usually runs before a
  # resource's own checks, so its wording is what callers see. A resource can
  # export `locked_message/1` to replace it — returning nil for a relationship
  # falls back to the generic sentence.
  defp locked_message(resource, rel) do
    Code.ensure_loaded?(resource)

    custom =
      if function_exported?(resource, :locked_message, 1) do
        resource.locked_message(rel.name)
      end

    custom ||
      "cannot destroy #{inspect(resource)}: still locked by " <>
        "#{inspect(rel.destination)} via :#{rel.name}"
  end

  defp ensure_not_locked(changeset) do
    # Serialize against locking records being created concurrently: they take a
    # FOR SHARE lock on this row before inserting, so after this returns
    # either they are committed and visible below, or they must wait for
    # this transaction and will then see the destroy.
    AshOwnership.Query.lock_record(changeset)

    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&AshOwnership.Info.locked_by?/1)
    |> Enum.reduce(changeset, fn rel, changeset ->
      source_value = AshOwnership.Query.data_attribute!(changeset, rel.source_attribute)

      locked? =
        AshOwnership.Query.exists?(rel, [{rel.destination_attribute, source_value}], changeset)

      if locked? do
        Ash.Changeset.add_error(changeset, locked_message(changeset.resource, rel))
      else
        changeset
      end
    end)
  end
end
