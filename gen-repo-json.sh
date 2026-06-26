#!/usr/bin/env bash
set -euo pipefail

REPO="luarvique/openwebrx"
ICON_URL="https://www.receiverbook.de/static/img/openwebrx-avatar.png"
DEPLOY_DIR="deploy"

declare -A LABEL=( [64bit]="64-bit" [32bit]="32-bit" )
declare -A DEVICES=(
  [64bit]='["pi5-64bit","pi4-64bit","pi3-64bit"]'
  [32bit]='["pi5-32bit","pi4-32bit","pi3-32bit"]'
)

found=0

for bits in 64bit 32bit; do
  zipfile=$(find "$DEPLOY_DIR" -maxdepth 1 -name "image_*-OpenWebRX+-${bits}-v*.zip" -print -quit)
  [[ -z "$zipfile" ]] && continue

  fname=$(basename "$zipfile")
  if [[ ! "$fname" =~ ^image_([0-9]{4}-[0-9]{2}-[0-9]{2})-OpenWebRX\+-${bits}-v(.+)\.zip$ ]]; then
    echo "WARNING: $fname doesn't match the expected naming pattern, skipping" >&2
    continue
  fi
  date="${BASH_REMATCH[1]}"
  ver="${BASH_REMATCH[2]}"

  echo "Found ${bits} image: $fname (v${ver}, ${date})"

  member=$(unzip -Z1 "$zipfile" | head -n1)
  tmpimg=$(mktemp -p "$(dirname "$zipfile")" .extract.XXXXXX)
  echo "Extracting $member to compute extract_sha256/extract_size..."
  unzip -p "$zipfile" "$member" > "$tmpimg"
  extract_size=$(stat -c%s "$tmpimg")
  extract_sha256=$(sha256sum "$tmpimg" | cut -d' ' -f1)
  rm -f "$tmpimg"

  download_size=$(stat -c%s "$zipfile")

  # the release tag is assumed to equal $ver, matching the upload convention used for past releases
  url="https://github.com/${REPO}/releases/download/${ver}/${fname//+/%2B}"

  # same name as the .zip/.info pair, minus the "image_" prefix
  outfile="${DEPLOY_DIR}/${fname#image_}"
  outfile="${outfile%.zip}.json"

  jq -n \
    --arg name "OpenWebRX+ ${ver} (${LABEL[$bits]})" \
    --arg desc "OpenWebRX+ preconfigured Raspberry Pi image (${LABEL[$bits]}). Supported: Raspberry Pi 3 / 4 / 5." \
    --arg icon "$ICON_URL" \
    --arg date "$date" \
    --arg url "$url" \
    --arg extract_sha256 "$extract_sha256" \
    --argjson extract_size "$extract_size" \
    --argjson image_download_size "$download_size" \
    --argjson devices "${DEVICES[$bits]}" \
    '{os_list: [{
      name: $name,
      description: $desc,
      icon: $icon,
      release_date: $date,
      url: $url,
      extract_sha256: $extract_sha256,
      extract_size: $extract_size,
      image_download_size: $image_download_size,
      supports_customization: true,
      init_format: "cloudinit-rpi",
      devices: $devices,
      capabilities: [ "rpi_connect" ]
    }]}' > "$outfile"

  echo "Generated $outfile"
  found=$((found + 1))
done

if [[ "$found" -eq 0 ]]; then
  echo "ERROR: no build artifacts found in $DEPLOY_DIR (expected image_*-OpenWebRX+-64bit-v*.zip / -32bit-v*.zip)" >&2
  exit 1
fi
