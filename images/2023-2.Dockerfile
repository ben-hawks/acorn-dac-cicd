FROM xilinx-ubuntu-20.04.4-user:v2023.2 AS build

# Install Miniforge
USER root
RUN curl -L -O "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh" \
    && bash Miniforge3-$(uname)-$(uname -m).sh -b -p /opt/conda \
    && source "/opt/conda/etc/profile.d/conda.sh" \
    && echo "export PATH=/opt/conda/bin:$PATH" > /etc/profile.d/conda.sh \
USER runner
ENV PATH=/opt/conda/bin:$PATH
#setups stuff
RUN echo "source activate base" > ~/.bashrc
#install packages
COPY images/include/acord-dac-cicd.yml /tmp/acord-dac-cicd.yml
RUN conda env create --name acord-dac-cicd --file /tmp/acord-dac-cicd.yml

RUN conda install -y -c conda-forge conda-pack

RUN conda-pack -n acord-dac-cicd -o /tmp/env.tar && \
  mkdir /venv && cd /venv && tar xf /tmp/env.tar && \
  rm /tmp/env.tar

RUN /venv/bin/conda-unpack

FROM xilinx-ubuntu-20.04.4-user:v2023.2 AS deploy

LABEL org.opencontainers.image.source https://github.com/ben-hawks/acord-dac-cicd
LABEL org.opencontainers.image.path "images/2023-2.Dockerfile"
LABEL org.opencontainers.image.title "acord-dac-cicd"
LABEL org.opencontainers.image.version "v2023.2"
LABEL org.opencontainers.image.description "A runner image for GitHub Actions with Vitis 2023.2 and related tools."
LABEL org.opencontainers.image.authors "Ben Hawks (@ben-hawks)"
LABEL org.opencontainers.image.licenses "MIT"
LABEL org.opencontainers.image.documentation https://github.com/ben-hawks/acord-dac-cicd/README.md

USER root
COPY --from=build --chown=runner /venv /venv

# Arguments
ARG TARGETPLATFORM=amd64
ARG RUNNER_VERSION=2.320.0
ARG RUNNER_CONTAINER_HOOKS_VERSION=0.6.1

SHELL ["/bin/bash", "-o", "pipefail", "-c", "-l"]

# The UID env var should be used in child Containerfile.
ENV UID=1000
ENV GID=0
ENV USERNAME="runner"

# Vivado/Vitis Variables
ENV LIBRARY_PATH=/usr/lib/x86_64-linux-gnu
ENV XILINXD_LICENSE_FILE=2100@

# Make and set the working directory
RUN useradd -G 0 $USERNAME
ENV HOME /home/${USERNAME}


RUN mkdir -p /home/${USERNAME} \
  && chown -R $USERNAME:$GID /home/${USERNAME}

WORKDIR /home/${USERNAME}


RUN echo "source /venv/bin/activate" >> ~/.bashrc
RUN echo "source /opt/Xilinx/Petalinux/2023.2/settings.sh" >> ~/.bashrc
RUN echo "source /opt/Xilinx/Vitis/2023.2/settings64.sh" >> ~/.bashrc
RUN echo "source /opt/Xilinx/Vivado/2023.2/settings64.sh" >> ~/.bashrc
RUN cat ~/.bashrc


RUN sudo apt-get update -y && \
    sudo apt-get install --no-install-recommends -y \
    git-lfs

#Build + Install GHDL 3.0.0
RUN echo 'Installing GHDL ...' && \
    sudo apt update && \
    sudo apt install -y git make gnat zlib1g-dev && \
    git clone https://github.com/ghdl/ghdl ghdl-build -b v3.0.0 && \
    cd ghdl-build && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    sudo make install && \
    cd ../ && \
    sudo apt-get clean && \
    sudo rm -rf /var/lib/apt/lists/* && \
    echo 'Done!'

#create symlink for tclsh
RUN ln -s /usr/bin/tclsh8.6 /usr/bin/tclsh

# Install GitHub CLI
COPY images/software/gh-cli.sh gh-cli.sh
RUN bash gh-cli.sh && rm gh-cli.sh

# Install kubectl
COPY images/software/kubectl.sh kubectl.sh
RUN bash kubectl.sh && rm kubectl.sh

# Install helm
RUN curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

RUN test -n "$TARGETPLATFORM" || (echo "TARGETPLATFORM must be set" && false)

# Runner download supports amd64 as x64
RUN export ARCH=$(echo ${TARGETPLATFORM} | cut -d / -f2) \
  && if [ "$ARCH" = "amd64" ]; then export ARCH=x64 ; fi \
  && curl -L -o runner.tar.gz https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz \
  && tar xzf ./runner.tar.gz \
  && rm runner.tar.gz \
  && ./bin/installdependencies.sh

# Install container hooks
RUN curl -f -L -o runner-container-hooks.zip https://github.com/actions/runner-container-hooks/releases/download/v${RUNNER_CONTAINER_HOOKS_VERSION}/actions-runner-hooks-k8s-${RUNNER_CONTAINER_HOOKS_VERSION}.zip \
  && unzip ./runner-container-hooks.zip -d ./k8s \
  && ls -la . \
  && rm runner-container-hooks.zip

# Add Tini - https://stackoverflow.com/questions/55733058/vivado-synthesis-hangs-in-docker-container-spawned-by-jenkins
ENV TINI_VERSION="v0.19.0"
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN sudo chmod +x /tini

USER $USERNAME

SHELL ["/bin/bash", "-o", "pipefail", "-c", "-l"]
ENTRYPOINT source /venv/bin/activate &&