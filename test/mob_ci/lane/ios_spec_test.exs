defmodule MobCi.Lane.Ios.SpecTest do
  use ExUnit.Case, async: true

  alias MobCi.Lane.Ios.Spec

  @sha String.duplicate("b", 40)

  @resolved %{
    row: {:rc, :mob_camera, "bbbbbbb"},
    repos: %{
      mob: %{version: "0.9.15", sha: nil, source: :hex, dir: nil},
      mob_dev: %{version: "0.7.17", sha: nil, source: :hex, dir: nil},
      mob_new: %{version: "0.6.7", sha: nil, source: :hex, dir: "/nuc/hex/mob_new-0.6.7"},
      mob_location: %{version: "0.1.6", sha: nil, source: :hex, dir: "/nuc/hex/mob_location-0.1.6"},
      mob_camera: %{
        version: "0.1.13",
        sha: @sha,
        source: {:git, "https://github.com/GenericJam/mob_camera"},
        dir: "/nuc/src/mob_camera/#{@sha}"
      }
    }
  }

  @cell %{set: "pairwise:2", plugins: [:mob_camera, :mob_location], resolved: @resolved}

  defp spec!(path, opts \\ []) do
    {:ok, spec} = Spec.from_cell(@cell, path, [stamp: "T1", udid: "UDID-1", mob_ci_sha: "abc1234"] ++ opts)
    spec
  end

  describe "JSON" do
    test "a spec survives the ssh hop unchanged, for every path" do
      for path <- Spec.paths() do
        spec = spec!(path)
        assert {:ok, ^spec} = Spec.from_json(Spec.to_json(spec))
      end
    end

    test "the round trip keeps the exact pins, plugins as atoms, the minimum runtime and the device only where it is used" do
      {:ok, back} = Spec.from_json(Spec.to_json(spec!("deploy:ios_sim", min_runtime: "27.1")))
      assert back.plugins == [:mob_camera, :mob_location]
      assert back.versions.row == "rc:mob_camera@bbbbbbb"
      assert back.versions.repos.mob_camera.source == "git:https://github.com/GenericJam/mob_camera@#{@sha}"
      assert back.udid == "UDID-1"
      assert back.min_runtime == "27.1"

      assert spec!("release:ios").udid == nil
    end

    test "anything but a schema-1 spec is refused with a reason" do
      good = JSON.decode!(Spec.to_json(spec!("deploy:ios_device")))

      for {doc, msg} <- [
            {"not json", "not JSON"},
            {JSON.encode!(%{good | "schema" => 2}), "unsupported spec schema 2"},
            {JSON.encode!(Map.delete(good, "schema")), "no schema"},
            {JSON.encode!(%{good | "path" => "deploy:android"}), "unknown path"},
            {JSON.encode!(%{good | "udid" => nil}), "needs a udid"},
            {JSON.encode!(%{good | "min_runtime" => "latest"}), "min_runtime must look like 27.0"},
            # The cell id names the dir teardown deletes: never a path or empty.
            {JSON.encode!(%{good | "cell_id" => "../../.."}), "bad cell_id"},
            {JSON.encode!(%{good | "cell_id" => ""}), "bad cell_id"},
            {JSON.encode!(%{good | "versions" => %{"row" => "hex"}}), "versions must be a record"}
          ] do
        assert {:error, reason} = Spec.from_json(doc)
        assert reason =~ msg
      end
    end
  end

  describe "from_cell/3" do
    test "names the cell after set, row, path and stamp, in characters safe for a file name" do
      assert spec!("deploy:ios_sim").cell_id == "pairwise_2-rc_mob_camera_bbbbbbb-deploy_ios_sim-t1"
    end

    test "the iPhone path needs its udid; a simulator is optional (the worker picks); bad input is refused" do
      assert {:error, "deploy:ios_device needs a device udid"} =
               Spec.from_cell(@cell, "deploy:ios_device", stamp: "T1")

      assert {:ok, %Spec{udid: nil, min_runtime: "27.0"}} =
               Spec.from_cell(@cell, "deploy:ios_sim", stamp: "T1")

      assert {:error, "unknown iOS path" <> _} = Spec.from_cell(@cell, "deploy:ios", udid: "U")

      assert {:error, "min runtime must look like 27.0" <> _} =
               Spec.from_cell(@cell, "deploy:ios_sim", min_runtime: "iOS 27")
    end
  end

  describe "resolved/2 (worker side)" do
    test "re-materialises the pins on this machine: mob_new's tarball, a checkout per git pin, nothing for Hex deps" do
      test = self()

      remote = %{
        hex_unpack: fn name, v, cache ->
          send(test, {:unpack, name, v})
          {:ok, "#{cache}/hex/#{name}-#{v}"}
        end,
        checkout: fn name, url, sha, cache ->
          send(test, {:checkout, name, url, sha})
          {:ok, %{dir: "#{cache}/src/#{name}/#{sha}", sha: sha}}
        end
      }

      {:ok, back} = Spec.from_json(Spec.to_json(spec!("deploy:ios_sim")))
      {:ok, local} = Spec.resolved(back, remote: remote, cache_dir: "/mac")

      assert local.row == {:rc, :mob_camera, "bbbbbbb"}
      assert local.repos.mob_new == %{version: "0.6.7", sha: nil, source: :hex, dir: "/mac/hex/mob_new-0.6.7"}
      assert local.repos.mob_location.dir == nil
      assert local.repos.mob == %{version: "0.9.15", sha: nil, source: :hex, dir: nil}

      assert local.repos.mob_camera == %{
               version: "0.1.13",
               sha: @sha,
               source: {:git, "https://github.com/GenericJam/mob_camera"},
               dir: "/mac/src/mob_camera/#{@sha}"
             }

      assert_received {:unpack, :mob_new, "0.6.7"}
      refute_received {:unpack, :mob_location, _}
      assert_received {:checkout, :mob_camera, "https://github.com/GenericJam/mob_camera", @sha}

      # The host pins come out the same as on the NUC.
      assert MobCi.Versions.plugin_deps(local, [:mob_location]) == [{:mob_location, "== 0.1.6"}]
    end

    test "a pin that cannot be materialised names the repo" do
      remote = %{
        hex_unpack: fn _, _, _ -> {:ok, "/x"} end,
        checkout: fn _, _, _, _ -> {:error, :offline} end
      }

      assert {:error, {:mob_camera, :offline}} = Spec.resolved(spec!("release:ios"), remote: remote)
    end
  end
end
