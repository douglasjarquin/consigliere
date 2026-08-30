defmodule Consigliere.RunnerLauncher do
  import Bitwise

  alias Consigliere.V0.Limits

  @protocol_version 1
  @max_frame_bytes Limits.frame_bytes()

  defstruct [
    :port,
    :socket,
    :manifest_path,
    :control_socket_path,
    :invocation_id,
    :identity,
    :secret_ref,
    :harness_pid,
    :runner_os_pid,
    :pgid,
    :manifest_digest,
    :runner_executable_sha256,
    :harness_executable_sha256,
    send_seq: 0,
    recv_seq: 0
  ]

  def cs_runner_source_dir do
    Path.expand("../../../runner/cs-runner", __DIR__)
  end

  def ensure_binary! do
    packaged = Path.join(:code.priv_dir(:consigliere_daemon), "cs-runner")
    source_dir = cs_runner_source_dir()
    source_binary = Path.join(source_dir, "cs-runner")

    cond do
      compatible_runner_binary?(packaged) ->
        packaged

      File.dir?(source_dir) and
          (not compatible_runner_binary?(source_binary) or
             source_newer_than_binary?(source_dir, source_binary)) ->
        {_, 0} = System.cmd("go", ["build", "-o", "cs-runner", "."], cd: source_dir)
        ensure_compatible_binary!(source_binary)

      compatible_runner_binary?(source_binary) ->
        source_binary

      true ->
        raise "no compatible cs-runner binary for this host"
    end
  end

  def cs_runner_bin_path do
    packaged = Path.join(:code.priv_dir(:consigliere_daemon), "cs-runner")
    source = Path.join(cs_runner_source_dir(), "cs-runner")

    if File.exists?(packaged) do
      if compatible_runner_binary?(packaged), do: packaged, else: source
    else
      source
    end
  end

  def launch(opts) do
    attempt_id = Keyword.fetch!(opts, :attempt_id)
    mission_id = Keyword.fetch!(opts, :mission_id)
    fencing_generation = Keyword.fetch!(opts, :fencing_token)
    manifest_path = Keyword.fetch!(opts, :manifest_path)
    control_socket_path = Keyword.fetch!(opts, :control_socket_path)
    harness_command = Keyword.fetch!(opts, :harness_command)
    invocation_id = Keyword.get(opts, :invocation_id, random_hex(16))
    workspace_path = Keyword.get(opts, :workspace_path, "unbound")
    workspace_generation = Keyword.get(opts, :workspace_generation, "unbound")
    binary_path = cs_runner_bin_path()
    runner_executable_sha256 = sha256_file(binary_path)

    identity = %{
      "protocol_version" => @protocol_version,
      "invocation_id" => invocation_id,
      "attempt_id" => attempt_id,
      "mission_id" => mission_id,
      "workspace_path" => workspace_path,
      "workspace_generation" => workspace_generation,
      "fencing_generation" => fencing_generation
    }

    secret = :crypto.strong_rand_bytes(32)

    bootstrap = %{
      "secret_hex" => Base.encode16(secret, case: :lower),
      "identity" => identity,
      "expected_runner_executable_sha256" => runner_executable_sha256
    }

    case ensure_private_parent(control_socket_path) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "control channel parent is unsafe: #{reason}"
    end

    secret_ref = store_secret(secret)

    args =
      [
        "--attempt-id",
        attempt_id,
        "--mission-id",
        mission_id,
        "--workspace-path",
        workspace_path,
        "--workspace-generation",
        workspace_generation,
        "--fencing-generation",
        fencing_generation,
        "--invocation-id",
        invocation_id,
        "--manifest",
        manifest_path,
        "--control-socket",
        control_socket_path,
        "--"
      ] ++ harness_command

    port =
      Port.open({:spawn_executable, binary_path}, [
        :binary,
        :exit_status,
        args: args,
        env: Keyword.get(opts, :env, [])
      ])

    _ = Port.command(port, JSON.encode!(bootstrap) <> "\n")

    result =
      with :ok <- wait_for_socket(control_socket_path, 5_000),
           {:ok, socket} <- connect(control_socket_path),
           :ok <-
             perform_daemon_handshake(
               socket,
               identity,
               secret,
               runner_executable_sha256,
               manifest_path,
               control_socket_path
             ),
           {:ok, started, 2} <- recv_verified(socket, identity, secret, 1, 5_000),
           :ok <- verify_started(started, identity, runner_executable_sha256) do
        {:ok,
         %__MODULE__{
           port: port,
           socket: socket,
           manifest_path: manifest_path,
           control_socket_path: control_socket_path,
           invocation_id: invocation_id,
           identity: identity,
           secret_ref: secret_ref,
           harness_pid: started["harness_pid"],
           runner_os_pid: started["runner_pid"],
           pgid: started["pgid"],
           manifest_digest: started["manifest_digest"],
           runner_executable_sha256: started["runner_executable_sha256"],
           harness_executable_sha256: started["harness_executable_sha256"],
           recv_seq: 1
         }}
      else
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        close_port(port)
        release_secret(secret_ref)
        {:error, reason}
    end
  end

  def release(%__MODULE__{secret_ref: secret_ref}), do: release_secret(secret_ref)

  def cancel(%__MODULE__{} = session), do: send_frame(session, %{"type" => "cancel"})

  def recv(%__MODULE__{} = session, timeout) do
    with {:ok, message, _next_seq} <-
           recv_verified(
             session.socket,
             session.identity,
             secret_for!(session),
             session.recv_seq + 1,
             timeout
           ) do
      {:ok, message}
    end
  end

  def recv_until(session, type, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_recv_until(session, type, deadline, session.recv_seq + 1)
  end

  def verify_frame(%__MODULE__{} = session, line) when is_binary(line) do
    with {:ok, message} <- decode_frame(line),
         {:ok, message, next_seq} <-
           verify_frame_message(
             message,
             session.identity,
             secret_for!(session),
             session.recv_seq + 1
           ) do
      {:ok, message, %{session | recv_seq: next_seq - 1}}
    end
  end

  def encode_frame(%__MODULE__{} = session, message, seq \\ nil) when is_map(message) do
    seq = seq || session.send_seq + 1

    message
    |> Map.merge(session.identity)
    |> Map.put("fencing_token", session.identity["fencing_generation"])
    |> Map.put("seq", seq)
    |> Map.put("mac", nil)
    |> put_mac(secret_for!(session))
  end

  defp do_recv_until(session, type, deadline, expected_seq) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case recv_verified(
             session.socket,
             session.identity,
             secret_for!(session),
             expected_seq,
             remaining
           ) do
        {:ok, %{"type" => ^type} = message, _next_seq} ->
          {:ok, message}

        {:ok, %{"type" => skip}, next_seq} when skip in ["stdout_chunk", "stderr_chunk"] ->
          do_recv_until(session, type, deadline, next_seq)

        other ->
          other
      end
    end
  end

  defp perform_daemon_handshake(
         socket,
         identity,
         secret,
         runner_executable_sha256,
         manifest_path,
         control_socket_path
       ) do
    daemon_nonce = random_hex(32)

    challenge =
      handshake_message(
        "daemon_challenge",
        identity,
        %{
          "runner_pid" => 0,
          "pgid" => 0,
          "manifest_digest" => "",
          "runner_executable_sha256" => runner_executable_sha256,
          "harness_executable_sha256" => ""
        },
        daemon_nonce,
        "",
        secret
      )

    with :ok <- send_line(socket, challenge),
         {:ok, hello} <- recv_message(socket, 5_000),
         :ok <- verify_handshake(hello, "runner_hello", identity, secret),
         :ok <- verify_runner_hello(hello, identity, runner_executable_sha256),
         :ok <- verify_manifest(hello, identity, manifest_path, control_socket_path),
         runner_nonce when is_binary(runner_nonce) <- hello["runner_nonce"],
         ack <-
           handshake_message(
             "daemon_ack",
             identity,
             runner_fields(hello),
             daemon_nonce,
             runner_nonce,
             secret
           ),
         :ok <- send_line(socket, ack) do
      :ok
    else
      nil -> {:error, :runner_nonce_missing}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :runner_handshake_invalid}
    end
  end

  defp verify_handshake(message, type, identity, secret) when is_map(message) do
    cond do
      byte_size(JSON.encode!(message)) > @max_frame_bytes -> {:error, :handshake_too_large}
      message["type"] != type -> {:error, :unexpected_handshake}
      Map.take(message, Map.keys(identity)) != identity -> {:error, :handshake_identity_mismatch}
      not secure_mac?(message, secret) -> {:error, :handshake_mac_mismatch}
      true -> :ok
    end
  end

  defp verify_runner_hello(message, identity, expected_runner_hash) do
    fields = runner_fields(message)

    cond do
      fields["protocol_version"] != @protocol_version ->
        {:error, :protocol_mismatch}

      fields["invocation_id"] != identity["invocation_id"] ->
        {:error, :invocation_mismatch}

      not is_integer(fields["runner_pid"]) or fields["runner_pid"] <= 1 ->
        {:error, :runner_pid_invalid}

      not is_integer(fields["pgid"]) or fields["pgid"] <= 1 ->
        {:error, :runner_pgid_invalid}

      not (is_binary(fields["manifest_digest"]) and
               fields["manifest_digest"] =~ ~r/\A[0-9a-f]{64}\z/) ->
        {:error, :manifest_digest_invalid}

      fields["runner_executable_sha256"] != expected_runner_hash ->
        {:error, :runner_executable_mismatch}

      not (is_binary(message["runner_nonce"]) and message["runner_nonce"] != "") ->
        {:error, :runner_nonce_invalid}

      true ->
        :ok
    end
  end

  defp verify_manifest(message, identity, manifest_path, control_socket_path) do
    digest = message["manifest_digest"]

    cond do
      not (is_binary(digest) and digest =~ ~r/\A[0-9a-f]{64}\z/) ->
        {:error, :manifest_digest_invalid}

      sha256_file(manifest_path) != digest ->
        {:error, :manifest_digest_mismatch}

      true ->
        case JSON.decode(File.read!(manifest_path)) do
          {:ok, manifest} when is_map(manifest) ->
            expected =
              Map.merge(identity, %{
                "schema_version" => 1,
                "state" => "running",
                "fencing_token" => identity["fencing_generation"],
                "runner_pid" => message["runner_pid"],
                "pgid" => message["pgid"],
                "runner_executable_sha256" => message["runner_executable_sha256"],
                "harness_executable_sha256" => message["harness_executable_sha256"],
                "control_socket_path" => control_socket_path
              })

            if Map.take(manifest, Map.keys(expected)) == expected do
              :ok
            else
              {:error, :manifest_identity_mismatch}
            end

          _ ->
            {:error, :manifest_invalid}
        end
    end
  end

  defp verify_started(message, identity, expected_runner_hash) do
    cond do
      message["type"] != "runner_started" ->
        {:error, :runner_started_missing}

      Map.take(message, Map.keys(identity)) != identity ->
        {:error, :runner_started_identity_mismatch}

      not is_integer(message["runner_pid"]) or message["runner_pid"] <= 1 ->
        {:error, :runner_started_process_invalid}

      not is_integer(message["pgid"]) or message["pgid"] <= 1 ->
        {:error, :runner_started_process_invalid}

      message["runner_executable_sha256"] != expected_runner_hash ->
        {:error, :runner_started_executable_mismatch}

      not nonempty_string?(message["runner_start_fingerprint"]) or
          not nonempty_string?(message["harness_start_fingerprint"]) ->
        {:error, :runner_started_process_identity_missing}

      not (is_binary(message["manifest_digest"]) and
               message["manifest_digest"] =~ ~r/\A[0-9a-f]{64}\z/) ->
        {:error, :runner_started_manifest_invalid}

      true ->
        :ok
    end
  end

  defp runner_fields(message) do
    Map.take(message, [
      "protocol_version",
      "invocation_id",
      "attempt_id",
      "mission_id",
      "workspace_path",
      "workspace_generation",
      "fencing_generation",
      "runner_pid",
      "pgid",
      "manifest_digest",
      "runner_executable_sha256",
      "harness_executable_sha256"
    ])
  end

  defp send_frame(%__MODULE__{} = session, message) do
    send_line(session.socket, encode_frame(session, message))
  end

  defp recv_verified(socket, identity, secret, expected_seq, timeout) do
    with {:ok, message} <- recv_message(socket, timeout),
         {:ok, message, next_seq} <- verify_frame_message(message, identity, secret, expected_seq) do
      {:ok, message, next_seq}
    end
  end

  defp verify_frame_message(message, identity, secret, expected_seq) when is_map(message) do
    seq = message["seq"]

    cond do
      Map.take(message, Map.keys(identity)) != identity ->
        {:error, :frame_identity_mismatch}

      message["fencing_token"] != identity["fencing_generation"] ->
        {:error, :frame_fencing_mismatch}

      message["type"] not in [
        "runner_started",
        "stdout_chunk",
        "stderr_chunk",
        "harness_exited",
        "termination_complete",
        "pong"
      ] ->
        {:error, :frame_type_invalid}

      not is_integer(seq) or seq != expected_seq ->
        {:error, :frame_sequence_mismatch}

      not secure_mac?(message, secret) ->
        {:error, :frame_mac_mismatch}

      true ->
        {:ok, message, seq + 1}
    end
  end

  defp recv_message(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        case Limits.validate_json_frame(line) do
          {:ok, trimmed} ->
            case JSON.decode(trimmed) do
              {:ok, message} when is_map(message) -> {:ok, message}
              _ -> {:error, :invalid_json_frame}
            end

          {:error, :frame_too_large} ->
            {:error, :frame_too_large}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_frame(line) do
    case Limits.validate_json_frame(line) do
      {:ok, trimmed} ->
        case JSON.decode(trimmed) do
          {:ok, message} when is_map(message) -> {:ok, message}
          _ -> {:error, :invalid_json_frame}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp secure_mac?(message, secret) do
    provided = message["mac"]
    expected = message |> Map.delete("mac") |> mac(secret)

    with true <- is_binary(provided),
         true <- byte_size(provided) == 64,
         {:ok, provided_bytes} <- Base.decode16(provided, case: :lower),
         {:ok, expected_bytes} <- Base.decode16(expected, case: :lower) do
      :crypto.hash_equals(provided_bytes, expected_bytes)
    else
      _ -> false
    end
  end

  defp put_mac(message, secret),
    do: Map.put(message, "mac", mac(Map.delete(message, "mac"), secret))

  defp mac(message, secret) do
    :crypto.mac(:hmac, :sha256, secret, canonical_json!(Map.delete(message, "mac")))
    |> Base.encode16(case: :lower)
  end

  defp handshake_message(type, identity, runner_fields, daemon_nonce, runner_nonce, secret) do
    %{}
    |> Map.merge(identity)
    |> Map.merge(runner_fields)
    |> Map.put("type", type)
    |> Map.put("daemon_nonce", daemon_nonce)
    |> Map.put("runner_nonce", runner_nonce)
    |> put_mac(secret)
  end

  defp canonical_json!(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), canonical_json!(nested)} end)
      |> Enum.sort_by(&elem(&1, 0))

    "{" <>
      Enum.map_join(entries, ",", fn {key, encoded} -> JSON.encode!(key) <> ":" <> encoded end) <>
      "}"
  end

  defp canonical_json!(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json!/1) <> "]"

  defp canonical_json!(value), do: JSON.encode!(value)

  defp connect(path) do
    :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])
  end

  defp send_line(socket, message) do
    :gen_tcp.send(socket, JSON.encode!(message) <> "\n")
  end

  defp wait_for_socket(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_socket(path, deadline)
  end

  defp do_wait_for_socket(path, deadline) do
    now = System.monotonic_time(:millisecond)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :control_socket_symlink}

      {:ok, %File.Stat{type: :other, mode: mode}} when band(mode, 0o170000) == 0o140000 ->
        :ok

      {:ok, _} ->
        {:error, :control_socket_not_socket}

      {:error, :enoent} when now <= deadline ->
        Process.sleep(20)
        do_wait_for_socket(path, deadline)

      {:error, :enoent} ->
        {:error, :control_socket_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_private_parent(path) do
    parent = Path.dirname(path)

    case File.lstat(parent) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :control_parent_symlink}

      {:ok, %File.Stat{type: :directory}} ->
        secure_parent(parent)

      {:error, :enoent} ->
        File.mkdir_p!(parent)
        secure_parent(parent)

      {:ok, _} ->
        {:error, :control_parent_not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp secure_parent(parent) do
    File.chmod!(parent, 0o700)

    case File.lstat(parent) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when band(mode, 0o077) == 0 -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :control_parent_symlink}
      _ -> {:error, :control_parent_not_private}
    end
  end

  defp sha256_file(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp random_hex(bytes), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  defp source_newer_than_binary?(source_dir, binary_path) do
    not File.exists?(binary_path) or
      Enum.any?(Path.wildcard(Path.join(source_dir, "*.go")), fn file ->
        File.stat!(file).mtime >= File.stat!(binary_path).mtime
      end)
  end

  defp compatible_runner_binary?(path) do
    with true <- File.regular?(path),
         {:ok, contents} <- File.read(path),
         true <- byte_size(contents) >= 8 do
      bytes = binary_part(contents, 0, min(byte_size(contents), 32))
      compatible_binary_bytes?(bytes, host_os(), host_cpu())
    else
      _ -> false
    end
  end

  defp compatible_binary_bytes?(
         <<0xCF, 0xFA, 0xED, 0xFE, cpu::little-signed-32, _rest::binary>>,
         :darwin,
         cpu_name
       ),
       do: mach_cpu(cpu) == cpu_name

  defp compatible_binary_bytes?(
         <<0xFE, 0xED, 0xFA, 0xCF, cpu::big-signed-32, _rest::binary>>,
         :darwin,
         cpu_name
       ),
       do: mach_cpu(cpu) == cpu_name

  defp compatible_binary_bytes?(<<0x7F, "ELF", _class, data, rest::binary>>, :linux, cpu_name)
       when data in [1, 2] do
    case rest do
      <<_ident_tail::binary-size(12), machine::little-unsigned-16, _remaining::binary>>
      when data == 1 ->
        elf_cpu(machine) == cpu_name

      <<_ident_tail::binary-size(12), machine::big-unsigned-16, _remaining::binary>>
      when data == 2 ->
        elf_cpu(machine) == cpu_name

      _ ->
        false
    end
  end

  defp compatible_binary_bytes?(_bytes, _os, _cpu), do: false

  defp mach_cpu(0x0100000C), do: :arm64
  defp mach_cpu(0x01000007), do: :amd64
  defp mach_cpu(_), do: :unknown

  defp elf_cpu(183), do: :arm64
  defp elf_cpu(62), do: :amd64
  defp elf_cpu(_), do: :unknown

  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, :linux} -> :linux
      _ -> :unknown
    end
  end

  defp host_cpu do
    architecture = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.contains?(architecture, "aarch64") or String.contains?(architecture, "arm64") ->
        :arm64

      String.contains?(architecture, "x86_64") or String.contains?(architecture, "amd64") ->
        :amd64

      true ->
        :unknown
    end
  end

  defp ensure_compatible_binary!(path) do
    if compatible_runner_binary?(path) do
      path
    else
      raise "built cs-runner is incompatible with this host"
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp store_secret(secret) do
    table = :ets.new(:runner_channel_secret, [:set, :protected, read_concurrency: true])
    :ets.insert(table, {:secret, secret})
    table
  end

  defp release_secret(secret_ref) do
    :ets.delete(secret_ref)
    :ok
  rescue
    _ -> :ok
  end

  defp secret_for!(%__MODULE__{secret_ref: secret_ref}) do
    case :ets.lookup(secret_ref, :secret) do
      [{:secret, secret}] -> secret
      [] -> raise ArgumentError, "runner channel secret is unavailable"
    end
  end
end
