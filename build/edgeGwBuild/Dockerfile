# Edge gateway image with third-party modules baked into user-lib/modules.
#
# Modules are listed by URL in build/edgeGwBuild/modules.txt. The CI
# workflow (.github/workflows/build-image.yml) downloads them into this
# directory before `docker build`, then this Dockerfile globs them in.
#
# To build locally (after staging .modl files alongside this Dockerfile):
#   docker build \
#     -t edge-with-transmission:8.3.6 \
#     --build-arg IGNITION_VERSION=8.3.6 \
#     ./build/edgeGwBuild
#
# Then push to GHCR via scripts/push-image-to-ghcr.{sh,ps1}.

ARG IGNITION_VERSION
FROM inductiveautomation/ignition:${IGNITION_VERSION}

# Glob-copy every .modl from the build context. modules.txt is informational
# only (CI uses it to fetch the files); the actual baking is whatever .modl
# files end up here at build time.
COPY --chown=ignition:ignition ./*.modl /usr/local/bin/ignition/user-lib/modules/
