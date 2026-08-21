defmodule AshReferentialActions.LifecycleTest do
  use ExUnit.Case, async: true

  alias AshReferentialActions.Test.Resources

  test "cascade archives related records" do
    parent = create!(Resources.CascadeParent)
    _child = create!(Resources.CascadeChild, %{parent_id: parent.id})

    Ash.destroy!(parent, authorize?: false)

    assert Ash.read!(Resources.CascadeParent, authorize?: false) == []
    assert Ash.read!(Resources.CascadeChild, authorize?: false) == []
  end

  test "cascade rejects a new child pointing at an archived parent" do
    parent = create!(Resources.CascadeParent)
    Ash.destroy!(parent, authorize?: false)

    assert_raise Ash.Error.Invalid, fn ->
      create!(Resources.CascadeChild, %{parent_id: parent.id})
    end
  end

  test "restrict blocks target archive while a live referrer exists" do
    target = create!(Resources.RestrictTarget)
    locker = create!(Resources.RestrictLocker, %{target_id: target.id})

    assert_raise Ash.Error.Invalid, fn -> Ash.destroy!(target, authorize?: false) end

    Ash.destroy!(locker, authorize?: false)
    Ash.destroy!(target, authorize?: false)

    assert Ash.read!(Resources.RestrictTarget, authorize?: false) == []
  end

  test "nilify clears the foreign key and keeps the referrer live" do
    target = create!(Resources.NilifyTarget)
    referrer = create!(Resources.NilifyReferrer, %{target_id: target.id})

    Ash.destroy!(target, authorize?: false)

    updated = Ash.get!(Resources.NilifyReferrer, referrer.id, authorize?: false)
    assert updated.target_id == nil
  end

  test "generated nilify action is private" do
    action_name = AshReferentialActions.Info.nilify_action_name(:target_id)
    action = Ash.Resource.Info.action(Resources.NilifyReferrer, action_name)

    assert action.type == :update
    refute action.public?
  end

  defp create!(resource, attrs \\ %{}) do
    resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end
end
