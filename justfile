set shell := ["bash", "-euo", "pipefail", "-c"]

magicdraw-image := "plexusna.jfrog.io/ep-oci-dev-local/plxs-pd/magicdraw:2024x-refresh2_1.2.0"
plugin-port := "18740"
docker-display := env_var_or_default("DOCKER_DISPLAY", env_var_or_default("DISPLAY", ":0"))
host-home := env_var("HOME")

# Launch MagicDraw GUI from the Docker image with host mounts.
launch-md:
  docker run --name magicdraw --rm -ti \
    -p '{{plugin-port}}:{{plugin-port}}' \
    -e DISPLAY='{{docker-display}}' \
    -e HOME='{{host-home}}' \
    -v '{{host-home}}:{{host-home}}' \
    -v '{{host-home}}/.magicdraw:/root/.magicdraw' \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    --ipc=host \
    '{{magicdraw-image}}'
