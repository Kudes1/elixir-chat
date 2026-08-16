defmodule Mix.Tasks.Orbit.AdminTest do
  use ElixirChat.DataCase

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  test "bootstrap and reset print only invitation paths" do
    Mix.Tasks.Orbit.Admin.run([
      "bootstrap",
      "--login",
      "command.admin",
      "--name",
      "Command Admin"
    ])

    assert_receive {:mix_shell, :info, [bootstrap_path]}
    assert_invitation_path(bootstrap_path)

    token = Path.basename(bootstrap_path)
    assert {:ok, _admin} = ElixirChat.Accounts.accept_invitation(token, "long-test-password")

    Mix.Tasks.Orbit.Admin.run(["reset"])

    assert_receive {:mix_shell, :info, [reset_path]}
    assert_invitation_path(reset_path)
  end

  defp assert_invitation_path(path) do
    assert String.starts_with?(path, "/invitation/")
    refute String.contains?(path, "://")
  end
end
