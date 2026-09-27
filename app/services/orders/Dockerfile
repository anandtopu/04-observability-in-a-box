# The binary is built on the host (app/build-images.sh): golang:* on Docker Hub is
# rate-limited from the cloud VM and gcr.io (distroless) is not on the allowlist.
# See DEVIATIONS D-05. A static CGO-free binary needs nothing else at runtime.
FROM scratch
COPY bin/orders /orders
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/orders"]
