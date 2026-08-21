defmodule AshOwnership.GuardTest do
  use ExUnit.Case, async: true

  alias AshOwnership.Test.Support.GuardResources.{
    Doc,
    FilteredDoc,
    FilteredSnapshot,
    NaDoc,
    NaSnapshot,
    Snapshot
  }

  defp create!(resource, attrs \\ %{}) do
    resource |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!()
  end

  describe "destroy guard (archival lockable)" do
    test "archiving a locked snapshot is rejected" do
      snapshot = create!(Snapshot)
      _doc = create!(Doc, %{snapshot_id: snapshot.id})

      error = assert_raise Ash.Error.Invalid, fn -> Ash.destroy!(snapshot) end

      assert Exception.message(error) =~
               "still locked by AshOwnership.Test.Support.GuardResources.Doc via :docs"
    end

    test "archiving succeeds once every locker is archived" do
      snapshot = create!(Snapshot)
      doc = create!(Doc, %{snapshot_id: snapshot.id})

      Ash.destroy!(doc)

      assert :ok = Ash.destroy!(snapshot)
      assert [] = Ash.read!(Snapshot)
    end

    test "an unlocked snapshot archives freely" do
      snapshot = create!(Snapshot)

      assert :ok = Ash.destroy!(snapshot)
    end
  end

  describe "destroy guard (non-archival lockable, no foreign key)" do
    test "hard-deleting a locked target is rejected even on ETS" do
      target = create!(NaSnapshot)
      _locker = create!(NaDoc, %{na_snapshot_id: target.id})

      error = assert_raise Ash.Error.Invalid, fn -> Ash.destroy!(target) end

      assert Exception.message(error) =~
               "NaSnapshot is still in use"
    end

    test "hard delete succeeds once the locker is gone" do
      target = create!(NaSnapshot)
      locker = create!(NaDoc, %{na_snapshot_id: target.id})

      Ash.destroy!(locker)

      assert :ok = Ash.destroy!(target)
    end
  end

  describe "destroy guard vs locker read filters" do
    test "a locker hidden by its primary read filter still blocks the destroy" do
      snapshot = create!(FilteredSnapshot)
      _hidden_doc = create!(FilteredDoc, %{filtered_snapshot_id: snapshot.id, active: false})

      assert [] = Ash.read!(FilteredDoc)

      error = assert_raise Ash.Error.Invalid, fn -> Ash.destroy!(snapshot) end

      assert Exception.message(error) =~
               "still locked by AshOwnership.Test.Support.GuardResources.FilteredDoc via :filtered_docs"
    end
  end

  describe "target-live guard on the locker side" do
    test "locking an archived target is rejected at create" do
      snapshot = create!(Snapshot)
      Ash.destroy!(snapshot)

      error =
        assert_raise Ash.Error.Invalid, fn ->
          create!(Doc, %{snapshot_id: snapshot.id})
        end

      assert Exception.message(error) =~ "does not exist or is not live"
    end

    test "locking a missing target is rejected at create" do
      error =
        assert_raise Ash.Error.Invalid, fn ->
          create!(Doc, %{snapshot_id: Ash.UUID.generate()})
        end

      assert Exception.message(error) =~ "does not exist or is not live"
    end

    test "updating the foreign key to an archived target is rejected" do
      live_snapshot = create!(Snapshot)
      archived_snapshot = create!(Snapshot)
      Ash.destroy!(archived_snapshot)

      doc = create!(Doc, %{snapshot_id: live_snapshot.id})

      error =
        assert_raise Ash.Error.Invalid, fn ->
          doc
          |> Ash.Changeset.for_update(:update, %{snapshot_id: archived_snapshot.id})
          |> Ash.update!()
        end

      assert Exception.message(error) =~ "does not exist or is not live"
    end

    test "locking a live target succeeds and a nil foreign key is ignored" do
      snapshot = create!(Snapshot)

      assert %Doc{} = create!(Doc, %{snapshot_id: snapshot.id})
      assert %Doc{} = create!(Doc, %{})
    end

    test "manage_relationship cannot relate an archived target" do
      snapshot = create!(Snapshot)
      Ash.destroy!(snapshot)

      error =
        assert_raise Ash.Error.Invalid, fn ->
          Doc
          |> Ash.Changeset.for_create(:create, %{})
          |> Ash.Changeset.manage_relationship(:snapshot, snapshot, on_lookup: :relate)
          |> Ash.create!()
        end

      assert Exception.message(error) =~ "does not exist or is not live"
    end

    test "manage_relationship cannot re-point an update at an archived target" do
      live_snapshot = create!(Snapshot)
      archived_snapshot = create!(Snapshot)
      Ash.destroy!(archived_snapshot)

      doc = create!(Doc, %{snapshot_id: live_snapshot.id})

      error =
        assert_raise Ash.Error.Invalid, fn ->
          doc
          |> Ash.Changeset.for_update(:update, %{})
          |> Ash.Changeset.manage_relationship(:snapshot, archived_snapshot, on_lookup: :relate)
          |> Ash.update!()
        end

      assert Exception.message(error) =~ "does not exist or is not live"
    end

    test "manage_relationship with a live target succeeds" do
      snapshot = create!(Snapshot)

      doc =
        Doc
        |> Ash.Changeset.for_create(:create, %{})
        |> Ash.Changeset.manage_relationship(:snapshot, snapshot, on_lookup: :relate)
        |> Ash.create!()

      assert doc.snapshot_id == snapshot.id
    end
  end

  describe "atomic foreign key updates" do
    test "an atomic bulk update cannot re-point at an archived target" do
      alias AshOwnership.Test.Support.GuardResources.{Doc, Snapshot}

      live_snapshot = create!(Snapshot)
      archived_snapshot = create!(Snapshot)
      Ash.destroy!(archived_snapshot)

      doc = create!(Doc, %{snapshot_id: live_snapshot.id})

      result =
        Ash.bulk_update([doc], :atomic_retarget, %{new_snapshot_id: archived_snapshot.id},
          strategy: [:atomic],
          return_errors?: true
        )

      assert result.status == :error

      assert Ash.get!(Doc, doc.id).snapshot_id == live_snapshot.id
    end
  end

  describe "destroy guard vs global preparations" do
    alias AshOwnership.Test.Support.GuardResources.{PrepDoc, PrepSnapshot}

    test "a locker hidden by a flag-aware global preparation still blocks the destroy" do
      snapshot = create!(PrepSnapshot)
      _hidden = create!(PrepDoc, %{prep_snapshot_id: snapshot.id, active: false})

      assert [] = Ash.read!(PrepDoc)

      error = assert_raise Ash.Error.Invalid, fn -> Ash.destroy!(snapshot) end

      assert Exception.message(error) =~
               "still locked by AshOwnership.Test.Support.GuardResources.PrepDoc via :prep_docs"
    end

    test "a live target hidden from default reads can still be locked" do
      snapshot = create!(PrepSnapshot, %{active: false})

      assert [] = Ash.read!(PrepSnapshot)
      assert %PrepDoc{} = create!(PrepDoc, %{prep_snapshot_id: snapshot.id, active: true})
    end
  end

  describe "extension composition" do
    test "a resource using both Locker and Lockable compiles without extra actions" do
      defmodule MiddleLink do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          extensions: [AshOwnership, AshOwnership]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end
      end

      assert [%{name: :read}] =
               Ash.Resource.Info.actions(MiddleLink) |> Enum.filter(&(&1.type == :read))
    end

    test "a resource with no lock edges gets no guard changes" do
      defmodule Untouched do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          extensions: [AshOwnership, AshOwnership]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read, :destroy, create: :*, update: :*]
        end
      end

      guards =
        Untouched
        |> Ash.Resource.Info.actions()
        |> Enum.flat_map(fn action -> Map.get(action, :changes, []) end)
        |> Enum.filter(fn
          %Ash.Resource.Change{change: {module, _}} ->
            module in [
              AshOwnership.Changes.EnsureTargetLive,
              AshOwnership.Changes.EnsureNotLocked
            ]

          _ ->
            false
        end)

      assert guards == []
    end
  end
end
