#!/usr/bin/env bash

set -e

# This is exported in the deployment. Only one multi-arch image may be saved to a single archive.
DOCKER_ZEEK_IMAGE="activecm/zeek:4.2.0"
DOCKER_MULTIARCH_IMAGES=("$DOCKER_ZEEK_IMAGE")

# Store the absolute path of the script's dir and switch to the top dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pushd "$SCRIPT_DIR/.." > /dev/null

__help() {
  cat <<HEREDOC
This script generates an installer for Zeek.
Usage:
  ${_NAME} [<arguments>]
Options:
  -h|--help     Show this help message.
  --no-pull     Do not pull the latest base images from the container
                repository during the build process.
HEREDOC
}

# Parse through command args
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      # Display help and exit
      __help
      exit 0
      ;;
    --no-pull)
      NO_PULL="--no-pull"
      ;;
    *)
    ;;
  esac
  shift
done

# File/ Directory Names
DOCKER_MULTIARCH_IMAGE_OUT_DIR="images"
ZEEK_ARCHIVE=ACH-Zeek

STAGE_DIR="$SCRIPT_DIR/stage/$ZEEK_ARCHIVE"

# Make sure we can use docker-compose
shell-lib/docker/check_docker.sh || {
        echo -e "\e[93mWARNING\e[0m: The generator did not detect a supported version of Docker."
        echo "         A supported version of Docker can be installed by running"
        echo "         the install_docker.sh script in the scripts directory."

        echo
        echo -n "Press enter to continue..."
        read
        echo
}

shell-lib/docker/check_docker-compose.sh || {
        echo -e "\e[93mWARNING\e[0m: The generator did not detect a supported version of Docker-Compose."
        echo "         A supported version of Docker-Compose can be installed by running"
        echo "         the install_docker.sh script in the scripts directory."

        echo
        echo -n "Press enter to continue..."
        read
        echo
}

# If the current user doesn't have docker permissions run with sudo
SUDO=
if [ ! -w "/var/run/docker.sock" ]; then
	SUDO="sudo -E"
fi

# Save out multi-architecture Docker images
for DOCKER_MULTIARCH_IMAGE in "${DOCKER_MULTIARCH_IMAGES[@]}"; do 

  DOCKER_MULTIARCH_IMAGE_ARCHITECTURES=(`
    ${SUDO} docker run --rm -i -u "$(id -u)":"$(id -g)" quay.io/containers/skopeo:latest \
    inspect --raw docker://docker.io/${DOCKER_MULTIARCH_IMAGE} | \
    grep "architecture" | cut -d: -f2 | cut -d\" -f2`)

  for DOCKER_MULTIARCH_IMAGE_ARCH in "${DOCKER_MULTIARCH_IMAGE_ARCHITECTURES[@]}"; do 
    DOCKER_MULTIARCH_IMAGE_NAME="$(echo ${DOCKER_MULTIARCH_IMAGE} | sed 's|[^a-zA-Z0-9]|_|g')_${DOCKER_MULTIARCH_IMAGE_ARCH}.tar"
    DOCKER_MULTIARCH_IMAGE_PATH="${STAGE_DIR}/${DOCKER_MULTIARCH_IMAGE_OUT_DIR}/${DOCKER_MULTIARCH_IMAGE_NAME}"

    if [ "$NO_PULL" -a -f "$DOCKER_MULTIARCH_IMAGE_PATH" ]; then
      echo "The latest images will *not* be pulled from DockerHub for ${DOCKER_MULTIARCH_IMAGE_NAME}."
    else
      echo "The latest images will be pulled from DockerHub for ${DOCKER_MULTIARCH_IMAGE_NAME}."
      mkdir -p "${STAGE_DIR}/${DOCKER_MULTIARCH_IMAGE_OUT_DIR}"

      $SUDO docker run --rm -i -v "${STAGE_DIR}/${DOCKER_MULTIARCH_IMAGE_OUT_DIR}":/host -u "$(id -u)":"$(id -g)" quay.io/containers/skopeo:latest \
        --override-arch ${DOCKER_MULTIARCH_IMAGE_ARCH} copy --multi-arch system docker://docker.io/${DOCKER_MULTIARCH_IMAGE} \
        --additional-tag ${DOCKER_MULTIARCH_IMAGE} \
        docker-archive:/host/"${DOCKER_MULTIARCH_IMAGE_NAME}"
      gzip -f "${DOCKER_MULTIARCH_IMAGE_PATH}"
    fi
  done 
done

echo "Updating VERSION file..."
[[ "$DOCKER_ZEEK_IMAGE" =~ :(.*)$ ]]
echo "${BASH_REMATCH[1]}" > "$STAGE_DIR/VERSION"

# Copy in the zeek script which runs the docker image
wget -O "$STAGE_DIR/scripts/zeek" \
    https://raw.githubusercontent.com/activecm/docker-zeek/master/zeek
chmod +x "$STAGE_DIR"/scripts/zeek

# Copy in zeek-open-connections zeek script
wget -O "$STAGE_DIR/zeek_scripts/site/zeek_open_connections.zeek" \
    https://raw.githubusercontent.com/activecm/zeek-open-connections/v1.1.0/scripts/zeek_open_connections.zeek

echo "Creating Zeek installer archive..."
# This has the result of only including the files we want
# but putting them in a single directory so they extract nicely
tar -C "$STAGE_DIR/.."  --exclude '.*' -chf "$SCRIPT_DIR/${ZEEK_ARCHIVE}.tar" $ZEEK_ARCHIVE

popd > /dev/null
