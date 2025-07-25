# MicroK8s Provider for Axiom

This document describes how to use the MicroK8s provider with the Axiom framework. The MicroK8s provider allows you to run Axiom instances as Kubernetes pods locally instead of cloud VMs, while maintaining full compatibility with all existing Axiom commands and workflows.

## Overview

The MicroK8s provider creates SSH-enabled Kubernetes pods that behave exactly like cloud VMs. Each "instance" is a pod running:
- SSH server on port 2266 (matching Axiom's standard)
- All Axiom tools and configurations
- Persistent storage for data
- Network access for security testing

## Prerequisites

### 1. Install MicroK8s

**Ubuntu/Debian:**
```bash
sudo snap install microk8s --classic
sudo usermod -a -G microk8s $USER
sudo chown -f -R $USER ~/.kube
newgrp microk8s
```

**Other systems:**
Follow the installation guide at https://microk8s.io/docs/getting-started

### 2. Install Docker

Docker is required for building Axiom images:
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install docker.io
sudo usermod -aG docker $USER
newgrp docker

# Or follow: https://docs.docker.com/get-docker/
```

### 3. Start MicroK8s

```bash
microk8s start
microk8s status --wait-ready
```

## Setup

### 1. Configure MicroK8s Provider

Run the account setup helper:
```bash
$AXIOM_PATH/interact/account-helpers/microk8s.sh
```

This will:
- Check MicroK8s installation and status
- Enable required addons (storage, DNS, registry)
- Configure kubectl for MicroK8s
- Set up provider configuration
- Create a basic Axiom base image

### 2. Set MicroK8s as Active Provider

```bash
axiom-provider microk8s
```

### 3. Select MicroK8s Account

```bash
axiom-account microk8s
```

## Configuration

The MicroK8s provider uses the following configuration parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Kubernetes namespace for Axiom instances | `axiom` |
| `storage_class` | Storage class for persistent volumes | `microk8s-hostpath` |
| `default_size` | Default resource allocation | `medium` |
| `default_disk_size` | Default PVC size in GB | `20` |
| `ssh_port_base` | Base port for SSH NodePort services | `30000` |
| `base_image` | Docker image for Axiom instances | `axiom-base:latest` |

### Resource Sizes

| Size | CPU | Memory | Description |
|------|-----|--------|-------------|
| nano | 0.1 | 128Mi | Minimal resources |
| micro | 0.25 | 256Mi | Very small |
| small | 0.5 | 512Mi | Small instance |
| medium | 1 | 1Gi | Medium instance |
| large | 2 | 2Gi | Large instance |
| xlarge | 4 | 4Gi | Extra large instance |

## Usage

All standard Axiom commands work with the MicroK8s provider:

### Create Single Instance
```bash
axiom-init test01
axiom-init --run  # Random name
axiom-init test02 --size large --disk 50
```

### Create Fleet
```bash
axiom-fleet test 5  # Creates test01-test05
axiom-fleet2 test 10  # Parallel creation
```

### List Instances
```bash
axiom-ls
```

### SSH to Instance
```bash
axiom-ssh test01
```

### Run Commands
```bash
axiom-exec "whoami" test01
axiom-exec "nmap -sn 192.168.1.0/24" test*
```

### File Transfer
```bash
axiom-scp file.txt test01:~/
axiom-scp test01:~/results.txt ./
```

### Scanning
```bash
axiom-scan targets.txt -m nmap -o results/
```

### Delete Instances
```bash
axiom-rm test01
axiom-rm test*  # Delete multiple
```

## Networking

### SSH Access

Each instance gets a unique NodePort service for SSH access:
- Base port: 30000 (configurable)
- Instance ports: base + hash(instance_name) % 1000
- Access via: `ssh -p <port> op@127.0.0.1`

### Pod Networking

Pods can communicate with:
- Other pods in the cluster
- External networks (for security testing)
- Host network (via services)

## Storage

### Persistent Volumes

Each instance gets a PersistentVolumeClaim (PVC) for data persistence:
- Storage class: `microk8s-hostpath` (default)
- Mount point: `/home/op`
- Data survives pod restarts

### Image Storage

Images are managed in multiple locations:

1. **MicroK8s Containerd**: Direct import for immediate use
2. **MicroK8s Registry**: Tagged and pushed for proper registry workflow
3. **Local Docker**: Source images for building

```bash
axiom-images ls      # List available images (shows both containerd and docker)
axiom-images rm name # Delete image
```

#### Image Tagging Strategy

The provider automatically handles proper image tagging:

- **Local image**: `axiom-base:latest`
- **Registry tagged**: `localhost:32000/axiom-base:latest`
- **Containerd import**: Direct import without registry

#### Manual Image Management

```bash
# Build and tag image
docker build -t axiom-base:latest .
docker tag axiom-base:latest localhost:32000/axiom-base:latest

# Push to MicroK8s registry (if enabled)
docker push localhost:32000/axiom-base:latest

# Or import directly to containerd
docker save axiom-base:latest | microk8s ctr image import -

# List images in containerd
microk8s ctr images list | grep axiom
```

## Building Images

### Using Packer

Build custom images with Packer:
```bash
axiom-build --setup  # Initial setup
axiom-build          # Build with default provisioner
axiom-build --provisioner reconftw  # Build with specific tools
```

### Manual Docker Build

Create custom images manually:
```bash
# Create Dockerfile
cat > Dockerfile << 'EOF'
FROM axiom-base:latest
RUN apt-get update && apt-get install -y your-tools
EOF

# Build image
docker build -t axiom-custom:latest .
```

## Troubleshooting

### Common Issues

1. **MicroK8s not ready**
   ```bash
   microk8s status
   microk8s start
   ```

2. **Storage issues**
   ```bash
   microk8s enable storage
   kubectl get storageclass
   ```

3. **SSH connection fails**
   ```bash
   kubectl get svc -n axiom  # Check services
   kubectl get pods -n axiom  # Check pod status
   ```

4. **Image not found**
   ```bash
   docker images | grep axiom
   # Rebuild base image if needed
   ```

### Debugging

Check pod logs:
```bash
kubectl logs axiom-<instance-name> -n axiom
```

Check pod status:
```bash
kubectl describe pod axiom-<instance-name> -n axiom
```

Check services:
```bash
kubectl get svc -n axiom
```

## Limitations

1. **Power Management**: Pods cannot be "powered off" like VMs, only deleted
2. **Regions**: Concept mapped to namespaces, limited compared to cloud regions
3. **Networking**: Limited to cluster networking capabilities
4. **Resources**: Constrained by local machine resources

## Advanced Configuration

### Custom Storage Class

Create custom storage class:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: axiom-fast
provisioner: microk8s.io/hostpath
parameters:
  pvDir: /var/snap/microk8s/common/default-storage
```

### Network Policies

Restrict pod networking:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: axiom-policy
  namespace: axiom
spec:
  podSelector:
    matchLabels:
      app: axiom-instance
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from: []
    ports:
    - protocol: TCP
      port: 2266
  egress:
  - {}
```

### Resource Quotas

Limit resource usage:
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: axiom-quota
  namespace: axiom
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    persistentvolumeclaims: "50"
```

## Migration from Cloud Providers

To migrate from cloud providers to MicroK8s:

1. Export existing configurations
2. Set up MicroK8s provider
3. Rebuild images for Docker
4. Test workflows locally
5. Update any provider-specific scripts

The MicroK8s provider maintains full compatibility with existing Axiom workflows, making migration seamless.