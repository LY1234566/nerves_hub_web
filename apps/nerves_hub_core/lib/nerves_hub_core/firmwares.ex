defmodule NervesHubCore.Firmwares do
  import Ecto.Query

  alias Ecto.Changeset
  alias NervesHubCore.Accounts.{OrgKey, Org}
  alias NervesHubCore.Firmwares.Firmware
  alias NervesHubCore.Products
  alias NervesHubCore.Repo

  @type upload_file_2 :: (filepath :: String.t(), filename :: String.t() -> :ok | {:error, any()})

  @uploader Application.fetch_env!(:nerves_hub_core, :firmware_upload)

  @spec get_firmwares_by_product(integer()) :: [Firmware.t()]
  def get_firmwares_by_product(product_id) do
    from(
      f in Firmware,
      where: f.product_id == ^product_id
    )
    |> Firmware.with_product()
    |> Repo.all()
  end

  @spec get_firmware(Org.t(), integer()) ::
          {:ok, Firmware.t()}
          | {:error, :not_found}
  def get_firmware(%Org{id: org_id}, id) do
    from(
      f in Firmware,
      where: f.id == ^id,
      join: p in assoc(f, :product),
      where: p.org_id == ^org_id
    )
    |> Firmware.with_product()
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      firmware -> {:ok, firmware}
    end
  end

  @spec get_firmware_by_product_and_version(Org.t(), String.t(), String.t()) ::
          {:ok, Firmware.t()}
          | {:error, :not_found}
  def get_firmware_by_product_and_version(%Org{} = org, product, version) do
    Firmware
    |> Repo.get_by(org_id: org.id, product: product, version: version)
    |> case do
      nil -> {:error, :not_found}
      firmware -> {:ok, firmware}
    end
  end

  @spec get_firmware_by_uuid(Org.t(), String.t()) ::
          {:ok, Firmware.t()}
          | {:error, :not_found}
  def get_firmware_by_uuid(%Org{id: t_id}, uuid) do
    from(
      f in Firmware,
      where: f.uuid == ^uuid,
      join: p in assoc(f, :product),
      preload: [product: p],
      where: p.org_id == ^t_id
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      firmware -> {:ok, firmware}
    end
  end

  @spec create_firmware(Org.t(), String.t(), opts :: [{:upload_file_2, upload_file_2()}]) ::
          {:ok, Firmware.t()}
          | {:error, Changeset.t() | :no_public_keys | :invalid_signature | any}
  def create_firmware(org, filepath, opts \\ []) do
    upload_file_2 = opts[:upload_file_2] || (&@uploader.upload_file/2)

    Repo.transaction(fn ->
      with {:ok, params} <- build_firmware_params(org, filepath),
           {:ok, firmware} <- insert_firmware(params),
           :ok <- upload_file_2.(filepath, firmware.upload_metadata) do
        firmware
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  def delete_firmware(%Firmware{} = firmware) do
    Repo.transaction(fn ->
      with {:ok, _} <- firmware |> Firmware.delete_changeset(%{}) |> Repo.delete(),
           :ok <- @uploader.delete_file(firmware) do
        :ok
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, _} -> :ok
      ret -> ret
    end
  end

  @spec verify_signature(String.t(), [OrgKey.t()]) ::
          {:ok, OrgKey.t()}
          | {:error, :invalid_signature}
          | {:error, :no_public_keys}
  def verify_signature(_filepath, []), do: {:error, :no_public_keys}

  def verify_signature(filepath, keys) when is_binary(filepath) do
    keys
    |> Enum.find(fn %{key: key} ->
      case System.cmd("fwup", ["--verify", "--public-key", key, "-i", filepath]) do
        {_, 0} ->
          true

        _ ->
          false
      end
    end)
    |> case do
      %OrgKey{} = key ->
        {:ok, key}

      nil ->
        {:error, :invalid_signature}
    end
  end

  @spec extract_metadata(String.t()) ::
          {:ok, String.t()}
          | {:error}
  def extract_metadata(filepath) do
    case System.cmd("fwup", ["-m", "-i", filepath]) do
      {metadata, 0} ->
        {:ok, metadata}

      _error ->
        {:error}
    end
  end

  defp insert_firmware(params) do
    %Firmware{}
    |> Firmware.changeset(params)
    |> Repo.insert()
  end

  defp build_firmware_params(%{id: org_id} = org, filepath) do
    org = NervesHubCore.Repo.preload(org, :org_keys)

    with {:ok, %{id: org_key_id}} <- verify_signature(filepath, org.org_keys),
         {:ok, metadata} <- extract_metadata(filepath),
         {:ok, architecture} <- Firmware.fetch_metadata_item(metadata, "meta-architecture"),
         {:ok, platform} <- Firmware.fetch_metadata_item(metadata, "meta-platform"),
         {:ok, product_name} <- Firmware.fetch_metadata_item(metadata, "meta-product"),
         {:ok, version} <- Firmware.fetch_metadata_item(metadata, "meta-version"),
         author <- Firmware.get_metadata_item(metadata, "meta-author"),
         description <- Firmware.get_metadata_item(metadata, "meta-description"),
         misc <- Firmware.get_metadata_item(metadata, "meta-misc"),
         uuid <- Firmware.get_metadata_item(metadata, "meta-uuid"),
         vcs_identifier <- Firmware.get_metadata_item(metadata, "meta-vcs-identifier") do
      filename = uuid <> ".fw"

      params =
        resolve_product(%{
          architecture: architecture,
          author: author,
          description: description,
          filename: filename,
          filepath: filepath,
          misc: misc,
          org_id: org_id,
          org_key_id: org_key_id,
          platform: platform,
          product_name: product_name,
          upload_metadata: @uploader.metadata(org_id, filename),
          size: :filelib.file_size(filepath),
          uuid: uuid,
          vcs_identifier: vcs_identifier,
          version: version
        })

      {:ok, params}
    end
  end

  defp resolve_product(params) do
    params.org_id
    |> Products.get_product_by_org_id_and_name(params.product_name)
    |> case do
      {:ok, product} -> Map.put(params, :product_id, product.id)
      _ -> params
    end

    with {:ok, product} <-
           Products.get_product_by_org_id_and_name(params.org_id, params.product_name) do
      Map.put(params, :product_id, product.id)
    else
      _ -> params
    end
  end
end
