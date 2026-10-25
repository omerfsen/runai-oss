# https://k3d.io/v5.9.0/usage/advanced/cuda/
# https://k3d.io/v5.9.0/usage/advanced/cuda/#building-a-customized-k3s-image
# For Kubernetes versions https://docs.k3s.io/release-notes/v1.37.X
# For CUDA:  https://hub.docker.com/r/nvidia/cuda/tags

# Define ARGs for build-time variables
# CUDA 13.4 needs an R615 host driver for its new features (13.x runs on >=580)
# https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html
# The driver itself stays on the host: docker --gpus injects its libraries and nvidia-smi.

# Define ARGs early so they're accessible in all FROM stages
ARG K3S_TAG="v1.37.1-k3s1"
ARG CUDA_TAG="13.4.3-base-ubuntu24.04"
ARG NVIDIA_CTK_VERSION="1.20.1-1"

# Stage 1: Pull k3s base image
FROM rancher/k3s:${K3S_TAG} AS k3s
# Nothing else needed here except the base

# Stage 2: CUDA + NVIDIA Toolkit layer
FROM nvcr.io/nvidia/cuda:${CUDA_TAG}

# Re-declare all ARGs you want to use in this stage
ARG NVIDIA_CTK_VERSION

ENV PAGER=less

# Install the NVIDIA container toolkit only. No nvidia-utils here: driver
# libraries baked into the image would clash with the host driver's.
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    less \
    ca-certificates \
    software-properties-common \
    lsb-release \
    less \
    && curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
       gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
       sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
       tee /etc/apt/sources.list.d/nvidia-container-toolkit.list \
    && apt-get update \
    && apt-get install -y \
       nvidia-container-toolkit=${NVIDIA_CTK_VERSION} \
       nvidia-container-toolkit-base=${NVIDIA_CTK_VERSION} \
       libnvidia-container-tools=${NVIDIA_CTK_VERSION} \
       libnvidia-container1=${NVIDIA_CTK_VERSION} \
    && nvidia-ctk runtime configure --runtime=containerd \
    && apt-get autoremove -y && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy full K3s filesystem, split /bin for layering purposes
COPY --from=k3s / / --exclude=/bin
COPY --from=k3s /bin /bin

# Inject NVIDIA plugin manifest
COPY device-plugin-daemonset.yaml /var/lib/rancher/k3s/server/manifests/nvidia-device-plugin-daemonset.yaml

# Define required volumes for K3s runtime
VOLUME /var/lib/kubelet
VOLUME /var/lib/rancher/k3s
VOLUME /var/lib/cni
VOLUME /var/log

# Set path and defaults
ENV PATH="$PATH:/bin/aux"
ENTRYPOINT ["/bin/k3s"]
CMD ["agent"]
