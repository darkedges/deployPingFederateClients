# ARC runner image

This image extends GitHub's official Actions Runner image with the tools used
by the PingFederate workflows:

- AWS CLI v2
- Terraform
- Vault CLI
- Python 3 and a dedicated virtual environment containing the repository's
  pinned PyYAML, JSON Schema, and yamllint dependencies
- GitHub CLI
- Bash, Git, curl, jq, OpenSSH, CA certificates, unzip, and checksum utilities
- DarkEdges IDAM root and intermediate CAs installed in the system trust store

Authenticate to Vault, then use the build helper. It reads both public CA
certificates into a temporary directory, validates them, supplies them as
BuildKit secrets, and removes the temporary files after the build:

```powershell
vault login
./setup/arc-runner/build.ps1 -Image darkedges/pingfeddeploy-arc-runner:test
docker push darkedges/pingfeddeploy-arc-runner:test
```

The Dockerfile deliberately requires both CA inputs, so a direct build without
them fails. The equivalent direct build command is:

```bash
docker build --pull \
  --file setup/arc-runner/Dockerfile \
  --secret id=darkedges_idam_root_ca,src=/secure/path/darkedges-idam-root.crt \
  --secret id=darkedges_idam_intermediate_ca,src=/secure/path/darkedges-idam-intermediate.crt \
  --tag darkedges/pingfeddeploy-arc-runner:test \
  .

docker push darkedges/pingfeddeploy-arc-runner:test
```

Override tool versions with build arguments when required:

```bash
docker build \
  --file setup/arc-runner/Dockerfile \
  --secret id=darkedges_idam_root_ca,src=/secure/path/darkedges-idam-root.crt \
  --secret id=darkedges_idam_intermediate_ca,src=/secure/path/darkedges-idam-intermediate.crt \
  --build-arg TERRAFORM_VERSION=1.15.8 \
  --build-arg VAULT_VERSION=2.0.3 \
  --build-arg AWSCLI_VERSION=2.31.22 \
  --build-arg YAMLLINT_VERSION=1.35.1 \
  --tag darkedges/pingfeddeploy-arc-runner:test \
  .
```

Copy `values.example.yaml`, replace the image reference with a unique immutable
tag or digest, and use it when installing/upgrading the ARC runner scale set.
The example uses `Always` so reuse of the development `test` tag cannot leave
runner pods on a cached image. A digest is preferred for production.

Do not bake Vault tokens, AWS credentials, PingFederate credentials, GitHub
tokens, or private keys into the image. The workflows obtain short-lived AWS
and Vault credentials from GitHub OIDC.
