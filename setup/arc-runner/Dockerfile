# syntax=docker/dockerfile:1.7
FROM ghcr.io/actions/actions-runner:latest

ARG TERRAFORM_VERSION=1.15.8
ARG VAULT_VERSION=2.0.3
ARG AWSCLI_VERSION=2.31.22
ARG YAMLLINT_VERSION=1.35.1

USER root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      bash \
      ca-certificates \
      coreutils \
      curl \
      gh \
      git \
      jq \
      openssh-client \
      python3 \
      python3-pip \
      python3-venv \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# BuildKit secrets are required so a runner image cannot be published without
# the private PKI trust chain. The certificates are public, but secret mounts
# keep temporary host paths and build inputs out of the image metadata.
RUN --mount=type=secret,id=darkedges_idam_root_ca,required=true \
    --mount=type=secret,id=darkedges_idam_intermediate_ca,required=true \
    install -m 0644 /run/secrets/darkedges_idam_root_ca \
      /usr/local/share/ca-certificates/darkedges-idam-root.crt \
    && install -m 0644 /run/secrets/darkedges_idam_intermediate_ca \
      /usr/local/share/ca-certificates/darkedges-idam-intermediate.crt \
    && update-ca-certificates \
    && test -s /usr/local/share/ca-certificates/darkedges-idam-root.crt \
    && test -s /usr/local/share/ca-certificates/darkedges-idam-intermediate.crt

COPY oauth2/tools/requirements.txt /tmp/pingfeddeploy-requirements.txt

RUN python3 -m venv /opt/pingfeddeploy-python \
    && /opt/pingfeddeploy-python/bin/python -m pip install --disable-pip-version-check --no-cache-dir \
      --requirement /tmp/pingfeddeploy-requirements.txt \
      "yamllint==${YAMLLINT_VERSION}" \
    && rm -f /tmp/pingfeddeploy-requirements.txt

ENV PATH="/opt/pingfeddeploy-python/bin:${PATH}"

RUN machine_arch="$(dpkg --print-architecture)" \
    && case "$machine_arch" in \
      amd64) hashicorp_arch="amd64"; aws_arch="x86_64" ;; \
      arm64) hashicorp_arch="arm64"; aws_arch="aarch64" ;; \
      *) echo "Unsupported architecture: $machine_arch" >&2; exit 1 ;; \
    esac \
    && terraform_zip="terraform_${TERRAFORM_VERSION}_linux_${hashicorp_arch}.zip" \
    && curl --fail --silent --show-error --location --output "/tmp/${terraform_zip}" \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${terraform_zip}" \
    && curl --fail --silent --show-error --location --output /tmp/terraform_SHA256SUMS \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
    && grep " ${terraform_zip}$" /tmp/terraform_SHA256SUMS | sed 's#  #  /tmp/#' | sha256sum --check --strict \
    && unzip -q "/tmp/${terraform_zip}" terraform -d /usr/local/bin \
    && vault_zip="vault_${VAULT_VERSION}_linux_${hashicorp_arch}.zip" \
    && curl --fail --silent --show-error --location --output "/tmp/${vault_zip}" \
      "https://releases.hashicorp.com/vault/${VAULT_VERSION}/${vault_zip}" \
    && curl --fail --silent --show-error --location --output /tmp/vault_SHA256SUMS \
      "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS" \
    && grep " ${vault_zip}$" /tmp/vault_SHA256SUMS | sed 's#  #  /tmp/#' | sha256sum --check --strict \
    && unzip -q "/tmp/${vault_zip}" vault -d /usr/local/bin \
    && aws_zip="awscli-exe-linux-${aws_arch}-${AWSCLI_VERSION}.zip" \
    && curl --fail --silent --show-error --location --output "/tmp/${aws_zip}" \
      "https://awscli.amazonaws.com/${aws_zip}" \
    && unzip -q "/tmp/${aws_zip}" -d /tmp \
    && /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli \
    && rm -rf /tmp/aws /tmp/*.zip /tmp/*_SHA256SUMS

RUN terraform version \
    && vault version \
    && aws --version \
    && python3 --version \
    && python3 -m pip --version \
    && python3 -c "import jsonschema, yaml" \
    && yamllint --version \
    && gh --version \
    && jq --version \
    && git --version \
    && test -L /etc/ssl/certs/darkedges-idam-root.pem \
    && test -L /etc/ssl/certs/darkedges-idam-intermediate.pem

USER runner

WORKDIR /home/runner

ENTRYPOINT ["/home/runner/run.sh"]
