# Quick Setup Guide for MicroK8s Provider

This guide will help you quickly set up the MicroK8s provider for Axiom.

## Prerequisites

1. **Install MicroK8s**:
   ```bash
   sudo snap install microk8s --classic
   sudo usermod -a -G microk8s $USER
   newgrp microk8s
   ```

2. **Install Docker**:
   ```bash
   sudo apt update && sudo apt install docker.io
   sudo usermod -aG docker $USER
   newgrp docker
   ```

3. **Start MicroK8s**:
   ```bash
   microk8s start
   microk8s status --wait-ready
   ```

## Setup Steps

1. **Run the account setup**:
   ```bash
   $HOME/.axiom/interact/account-helpers/microk8s.sh
   ```

2. **Set MicroK8s as the active provider**:
   ```bash
   axiom-provider microk8s
   ```

3. **Select the MicroK8s account**:
   ```bash
   axiom-account microk8s
   ```

4. **Test the setup**:
   ```bash
   ./test_microk8s_provider.sh
   ```

## Image Management

The setup automatically handles proper registry workflow:

1. **Builds base image**: `sudo docker build -t axiom-base:latest .`
2. **Builds registry-tagged image**: `sudo docker build -t localhost:32000/axiom-base:latest .`
3. **Pushes to MicroK8s registry**: `sudo docker push localhost:32000/axiom-base:latest`
4. **Updates account configuration** to use `localhost:32000/axiom-base:latest`
5. **Fallback to containerd import** if registry is not available

### Manual Registry Workflow
```bash
# Build with registry tag
sudo docker build -t localhost:32000/axiom-base:latest .

# Push to MicroK8s registry
sudo docker push localhost:32000/axiom-base:latest

# Verify in registry
curl -X GET http://localhost:32000/v2/_catalog
```

## Quick Test

Once setup is complete, test with:

```bash
# Create a test instance
axiom-init test01

# List instances
axiom-ls

# SSH to the instance
axiom-ssh test01

# Clean up
axiom-rm test01
```

## Troubleshooting

- **MicroK8s not ready**: Run `microk8s status` and `microk8s start`
- **Docker permission denied**: Run `newgrp docker` or log out/in
- **No base image**: The setup script will create one automatically
- **SSH connection fails**: Check `kubectl get pods -n axiom` and `kubectl get svc -n axiom`

For detailed documentation, see [MICROK8S_PROVIDER.md](MICROK8S_PROVIDER.md).