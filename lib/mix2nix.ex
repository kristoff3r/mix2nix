defmodule Mix2nix do
  def process(filename) do
    filename
    |> read
    |> expression_set
  end

  def expression_set(deps) do
    deps
    |> Map.to_list()
    |> Enum.sort(:asc)
    |> Enum.map(fn {k, v} -> nix_expression(deps, k, v) end)
    |> Enum.reject(fn x -> x == "" end)
    |> Enum.join("\n")
    |> String.trim("\n")
    |> wrap
  end

  defp read(filename) do
    opts = [
      emit_warnings: false,
      file: filename,
      warn_on_unnecessary_quotes: false
    ]

    with {:ok, contents} <- File.read(filename),
         {:ok, quoted} <- Code.string_to_quoted(contents, opts),
         {%{} = lock, _} <- Code.eval_quoted(quoted, opts) do
      lock
    else
      {:error, posix} when is_atom(posix) ->
        :file.format_error(posix) |> to_string() |> IO.puts()
        System.halt(1)

      {:error, {line, error, token}} when is_integer(line) ->
        IO.puts("Error on line #{line}: #{error} (" <> inspect(token) <> ")")
        System.halt(1)
    end
  end

  def is_required(allpkgs, hex: name, repo: _, optional: optional) do
    Map.has_key?(allpkgs, name) or !optional
  end

  def dep_string(allpkgs, deps) do
    depString =
      deps
      |> Enum.filter(fn x -> is_required(allpkgs, elem(x, 2)) end)
      |> Enum.map(fn x -> Atom.to_string(elem(x, 0)) end)
      |> Enum.join(" ")

    if String.length(depString) > 0 do
      "[ " <> depString <> " ]"
    else
      "[]"
    end
  end

  def specific_workaround(pkg) do
    case pkg do
      "cowboy" -> "buildErlangMk"
      "ssl_verify_fun" -> "buildRebar3"
      "jose" -> "buildMix"
      _ -> false
    end
  end

  def get_build_env(builders, pkgname) do
    cond do
      specific_workaround(pkgname) ->
        specific_workaround(pkgname)

      Enum.member?(builders, :mix) ->
        "buildMix"

      Enum.member?(builders, :rebar3) or Enum.member?(builders, :rebar) ->
        "buildRebar3"

      Enum.member?(builders, :make) ->
        "buildErlangMk"

      true ->
        "buildMix"
    end
  end

  def get_hash(name, version) do
    url = "https://repo.hex.pm/tarballs/#{name}-#{version}.tar"
    {result, status} = System.cmd("nix-prefetch-url", [url])

    case status do
      0 ->
        String.trim(result)

      _ ->
        IO.puts("Use of nix-prefetch-url failed.")
        System.halt(1)
    end
  end

  def nix_expression(
        allpkgs,
        name,
        {:hex, hex_name, version, _hash, builders, deps, "hexpm", hash2}
      ),
      do: get_hexpm_expression(allpkgs, name, hex_name, version, builders, deps, hash2)

  def nix_expression(
        allpkgs,
        name,
        {:hex, hex_name, version, _hash, builders, deps, "hexpm"}
      ),
      do: get_hexpm_expression(allpkgs, name, hex_name, version, builders, deps)

  def nix_expression(_allpkgs, _name, _pkg) do
    ""
  end

  defp get_hexpm_expression(allpkgs, name, hex_name, version, builders, deps, sha256 \\ nil) do
    name = Atom.to_string(name)
    hex_name = Atom.to_string(hex_name)
    buildEnv = get_build_env(builders, name)
    sha256 = sha256 || get_hash(hex_name, version)
    deps = dep_string(allpkgs, deps)

    postBuild =
      case name do
        "db_connection" ->
          "genPltDBConnection"

        _ ->
          case buildEnv do
            "buildMix" ->
              "genPltMix"

            "buildRebar3" ->
              "genPltRebar"

            "buildErlangMk" ->
              "genPltRebar"

            _ ->
              raise "Could not generate postBuild for package=#{name} builder=#{buildEnv}"
          end
      end

    postInstall =
      case name do
        "db_connection" ->
          "installPltDBConnection"

        _ ->
          case buildEnv do
            "buildMix" ->
              "installPlt"

            "buildRebar3" ->
              "installPltRebar"

            "buildErlangMk" ->
              "installPltErlang"

            _ ->
              raise "Could not generate postInstall for package=#{name} builder=#{buildEnv}"
          end
      end

    """
        #{name} = #{buildEnv} rec {
          name = "#{name}";
          version = "#{version}";

          src = fetchHex {
            pkg = "#{hex_name}";
            version = "${version}";
            sha256 = "#{sha256}";
          };

          postBuild = #{postBuild} name;
          postInstall = #{postInstall} name version;

          beamDeps = #{deps};
    """ <>
      hexpm_expression_extras(name) <>
      "    };\n"
  end

  defp wrap(pkgs) do
    """
    { lib, beamPackages, genPltDBConnection, installPltDBConnection, genPltMix, genPltRebar, installPlt, installPltRebar, installPltErlang, overrides ? (x: y: {}) }:

    let
      buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
      buildMix = lib.makeOverridable beamPackages.buildMix;
      buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

      self = packages // (overrides self packages);

      packages = with beamPackages; with self; {
    #{pkgs}
      };
    in self
    """
  end

  @override_src_root ["grpcbox", "png"]
  defp hexpm_expression_extras(pkg_name) when pkg_name in @override_src_root do
    """

          unpackPhase = ''
            runHook preUnpack
            unpackFile "$src"
            chmod -R u+w -- hex-source-#{pkg_name}-${version}
            mv hex-source-#{pkg_name}-${version} #{pkg_name}
            sourceRoot=#{pkg_name}
            runHook postUnpack
          '';
    """
  end

  defp hexpm_expression_extras(_), do: ""
end
