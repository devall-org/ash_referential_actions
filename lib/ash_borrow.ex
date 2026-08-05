defmodule AshBorrow do
  @moduledoc """
  Borrow semantics for Ash: non-owning references that can never dangle.

  A `belongs_to` relationship conflates two meanings:

  * **Containment** — the record is owned by its parent and must go down with it.
  * **Non-owning reference (a borrow)** — the record merely uses the target;
    the target must not vanish while the reference is alive.

  AshBorrow gives the second meaning its own vocabulary:

  * `AshBorrow.Borrower` provides the `borrows` relationship entity
    (a marked `belongs_to`).
  * `AshBorrow.Borrowable` marks a resource as a borrow target and provides
    the `borrowed_by` relationship entity (a marked `has_many`).

  The core invariant — a borrowed record can neither be hard-deleted nor
  archived while live borrowers exist — is enforced by the database foreign
  key (deletes are restricted) and by a runtime guard on archive
  (`AshBorrow.Changes.EnsureNotBorrowed`).
  """
end
