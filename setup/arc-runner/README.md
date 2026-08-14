# ARC runner image

This image extends GitHub's official Actions Runner image with the tools used
by the PingFederate workflows:

- AWS CLI v2
- Terraform
- Vault CLI
- Python 3, pip, and venv
- Bash, Git, curl, jq, OpenSSH, CA certificates, unzip, and checksum utilities

Build and push an immutable image tag:

```bash
docker build --pull \
  --tag darkedges/pingfeddeploy-arc-runner:test \
  setup/arc-runner

docker push darkedges/pingfeddeploy-arc-runner:test
```

Override tool versions with build arguments when required:

```bash
docker build \
  --build-arg TERRAFORM_VERSION=1.15.8 \
  --build-arg VAULT_VERSION=2.0.3 \
  --build-arg AWSCLI_VERSION=2.31.22 \
  --tag darkedges/pingfeddeploy-arc-runner:test \
  setup/arc-runner
```

Copy `values.example.yaml`, replace the image reference with the pushed
immutable tag or digest, and use it when installing/upgrading the ARC runner
scale set. The runner container name and `/home/runner/run.sh` command are
required by ARC.

For an internal CA, derive another image and install the certificate before
returning to the `runner` user:

```dockerfile
FROM darkedges/pingfeddeploy-arc-runner:test
USER root
COPY darkedges-root-ca.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates
USER runner
```

Do not bake Vault tokens, AWS credentials, PingFederate credentials, GitHub
tokens, or private keys into the image. The workflows obtain short-lived AWS
and Vault credentials from GitHub OIDC.
