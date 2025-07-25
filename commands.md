449  rm -rf ~/.axiom/
  450  cp -r . ~/.axiom/
  451  cd ../.axiom/
  452  sudo chmod u+x ~/.axiom/interact/account-helpers/microk8s.sh
  453  ~/.axiom/interact/account-helpers/microk8s.sh
  454  axiom-provider microk8s
  455  axiom-account microk8s
  456  axiom-init test01
  457  axiom-images ls

 ~/.axiom/interact/account-helpers/microk8s.sh
cp -r /home/runzero/ax/providers/microk8s-functions.sh /home/runzero/.axiom/providers/microk8s-functions.sh 


cp -r /home/runzero/ax/images/pkr.hcl/provisioners/microk8s.pkr.hcl /home/runzero/.axiom/images/pkr.hcl/provisioners/microk8s.pkr.hcl
cp -r /home/runzero/ax/images/pkr.hcl/builders/microk8s.pkr.hcl /home/runzero/.axiom/images/pkr.hcl/builders/microk8s.pkr.hcl
  Here are the commands to completely clear all microk8s and Docker images:

### Should we manually run this command, doesn't other providers packer builds after runnning axiom-build do this? Is ours aligned?
  docker push localhost:32000/axiom-base:axiom-microk8s-1753425366

## Docker Image Cleanup

```bash
# Remove all axiom-related Docker images
sudo docker images | grep axiom | awk '{print $1":"$2}' | xargs -r sudo docker rmi -f

# Remove all images from localhost:32000 registry
sudo docker images | grep localhost:32000 | awk '{print $1":"$2}' | xargs -r sudo docker rmi -f

# Remove all dangling/unused images
sudo docker image prune -af

# Remove all unused containers, networks, and build cache
sudo docker system prune -af
```

## MicroK8s Registry Cleanup

```bash
# Clear the microk8s registry storage
sudo rm -rf /var/snap/microk8s/common/var/lib/registry/*

# Restart the registry to clear any cached data
microk8s kubectl delete pod -n container-registry -l app=registry
```

## Kubernetes Resources Cleanup

```bash
# Delete all axiom-related pods
microk8s kubectl get pods --all-namespaces | grep axiom | awk '{print $1" "$2}' | xargs -r -n2 microk8s kubectl delete pod -n

# Delete all axiom-related services
microk8s kubectl get services --all-namespaces | grep axiom | awk '{print $1" "$2}' | xargs -r -n2 microk8s kubectl delete service -n

# Delete all axiom-related PVCs
microk8s kubectl get pvc --all-namespaces | grep axiom | awk '{print $1" "$2}' | xargs -r -n2 microk8s kubectl delete pvc -n

# Delete all axiom-related deployments
microk8s kubectl get deployments --all-namespaces | grep axiom | awk '{print $1" "$2}' | xargs -r -n2 microk8s kubectl delete deployment -n
```

## Complete Reset (Nuclear Option)

If you want to completely reset everything:

```bash
# Stop microk8s
sudo snap stop microk8s

# Remove all Docker data
sudo docker system prune -af --volumes

# Clear microk8s data
sudo rm -rf /var/snap/microk8s/common/var/lib/registry/*
sudo rm -rf /var/snap/microk8s/common/var/lib/containerd/*

# Restart microk8s
sudo snap start microk8s

# Wait for microk8s to be ready
microk8s status --wait-ready

# Re-enable required addons
microk8s enable storage dns registry
```

## Verification Commands

After cleanup, verify everything is cleared:

```bash
# Check Docker images
sudo docker images

# Check Kubernetes resources
microk8s kubectl get all --all-namespaces | grep axiom

# Check registry contents
curl -X GET http://localhost:32000/v2/_catalog
```

These commands will completely clean up all microk8s and Docker resources related to the axiom project, allowing you to start fresh with the image building process.