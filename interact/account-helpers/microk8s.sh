#!/bin/bash

AXIOM_PATH="$HOME/.axiom"
source "$AXIOM_PATH/interact/includes/vars.sh"

token=""
region=""
provider=""
size=""

BASEOS="$(uname)"
case $BASEOS in
'Linux')
    BASEOS='Linux'
    ;;
'FreeBSD')
    BASEOS='FreeBSD'
    alias ls='ls -G'
    ;;
'WindowsNT')
    BASEOS='Windows'
    ;;
'Darwin')
    BASEOS='Mac'
    ;;
'SunOS')
    BASEOS='Solaris'
    ;;
'AIX') ;;
*) ;;
esac

# Check if microk8s is installed and running
check_microk8s() {
    if ! command -v microk8s &> /dev/null; then
        echo -e "${BRed}microk8s is not installed. Please install it first.${Color_Off}"
        echo -e "${BYellow}On Ubuntu/Debian: sudo snap install microk8s --classic${Color_Off}"
        echo -e "${BYellow}On other systems: https://microk8s.io/docs/getting-started${Color_Off}"
        return 1
    fi

    if ! microk8s status --wait-ready --timeout 30 >/dev/null 2>&1; then
        echo -e "${BRed}microk8s is not running or not ready.${Color_Off}"
        echo -e "${BYellow}Try: microk8s start${Color_Off}"
        return 1
    fi

    return 0
}

# Check if kubectl is configured for microk8s
check_kubectl() {
    # Always use microk8s kubectl directly in scripts
    if ! microk8s kubectl get nodes >/dev/null 2>&1; then
        echo -e "${BYellow}Setting up kubectl config for microk8s...${Color_Off}"
        microk8s config > ~/.kube/config 2>/dev/null || {
            mkdir -p ~/.kube
            microk8s config > ~/.kube/config
        }
    fi
    
    # Set up alias for interactive use
    if ! command -v kubectl &> /dev/null; then
        echo -e "${BYellow}kubectl not found. Setting up microk8s kubectl alias...${Color_Off}"
        echo "alias kubectl='microk8s kubectl'" >> ~/.bashrc
        echo "alias kubectl='microk8s kubectl'" >> ~/.zshrc 2>/dev/null || true
    fi
}

# Enable required microk8s addons
enable_addons() {
    echo -e "${BGreen}Enabling required microk8s addons...${Color_Off}"
    
    # Enable storage addon for persistent volumes
    if ! microk8s is-enabled storage >/dev/null 2>&1; then
        echo -e "${BYellow}Enabling storage addon...${Color_Off}"
        microk8s enable storage
    fi

    # Enable DNS addon
    if ! microk8s is-enabled dns >/dev/null 2>&1; then
        echo -e "${BYellow}Enabling DNS addon...${Color_Off}"
        microk8s enable dns
    fi

    # Enable registry addon (optional, for local image storage)
    if ! microk8s is-enabled registry >/dev/null 2>&1; then
        echo -e "${BYellow}Enabling registry addon for local image storage...${Color_Off}"
        microk8s enable registry
    fi

    echo -e "${BGreen}Addons enabled successfully!${Color_Off}"
}

# Setup Docker for image building
setup_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${BRed}Docker is not installed. Docker is required for building axiom images.${Color_Off}"
        echo -e "${BYellow}Please install Docker: https://docs.docker.com/get-docker/${Color_Off}"
        return 1
    fi

    # Check if user can run docker without sudo
    if ! docker ps >/dev/null 2>&1; then
        echo -e "${BYellow}Adding user to docker group...${Color_Off}"
        sudo usermod -aG docker $USER
        echo -e "${BYellow}Please log out and log back in for docker group changes to take effect.${Color_Off}"
        echo -e "${BYellow}Or run: newgrp docker${Color_Off}"
    fi
}

# Clean up existing axiom images
cleanup_images() {
    echo -e "${BYellow}Cleaning up existing axiom images...${Color_Off}"
    
    # Get all axiom-related images
    local images=$(sudo docker images --format "table {{.Repository}}:{{.Tag}}" | grep axiom | grep -v REPOSITORY || true)
    
    if [[ -n "$images" ]]; then
        echo -e "${BYellow}Found existing axiom images:${Color_Off}"
        echo "$images"
        echo -e "${BYellow}Removing existing images...${Color_Off}"
        echo "$images" | xargs -r sudo docker rmi -f
        echo -e "${BGreen}Existing images cleaned up!${Color_Off}"
    else
        echo -e "${BGreen}No existing axiom images found.${Color_Off}"
    fi
}

function microk8ssetup(){

echo -e "${BGreen}Setting up microk8s provider for Axiom...${Color_Off}"

# Check prerequisites
if ! check_microk8s; then
    exit 1
fi

check_kubectl
enable_addons
setup_docker

# Get configuration parameters
default_namespace="axiom"
echo -e -n "${Green}Please enter your default namespace (default: '$default_namespace'): \n>> ${Color_Off}"
read namespace
if [[ "$namespace" == "" ]]; then
    echo -e "${Blue}Selected default option '$default_namespace'${Color_Off}"
    namespace="$default_namespace"
fi

default_storage_class="microk8s-hostpath"
echo -e -n "${Green}Please enter your storage class (default: '$default_storage_class'): \n>> ${Color_Off}"
read storage_class
if [[ "$storage_class" == "" ]]; then
    echo -e "${Blue}Selected default option '$default_storage_class'${Color_Off}"
    storage_class="$default_storage_class"
fi

default_size="medium"
echo -e -n "${Green}Please enter your default instance size (nano/micro/small/medium/large/xlarge, default: '$default_size'): \n>> ${Color_Off}"
read size
if [[ "$size" == "" ]]; then
    echo -e "${Blue}Selected default option '$default_size'${Color_Off}"
    size="$default_size"
fi

default_disk_size="20"
echo -e -n "${Green}Please enter your default disk size in GB (default: '$default_disk_size'): \n>> ${Color_Off}"
read disk_size
if [[ "$disk_size" == "" ]]; then
    disk_size="$default_disk_size"
    echo -e "${Blue}Selected default option '$default_disk_size'${Color_Off}"
fi

default_ssh_port_base="30000"
echo -e -n "${Green}Please enter the base SSH port for NodePort services (default: '$default_ssh_port_base'): \n>> ${Color_Off}"
read ssh_port_base
if [[ "$ssh_port_base" == "" ]]; then
    ssh_port_base="$default_ssh_port_base"
    echo -e "${Blue}Selected default option '$default_ssh_port_base'${Color_Off}"
fi

default_base_image="localhost:32000/axiom-base:latest"
echo -e -n "${Green}Please enter the base Docker image for axiom instances (default: '$default_base_image'): \n>> ${Color_Off}"
read base_image
if [[ "$base_image" == "" ]]; then
    base_image="$default_base_image"
    echo -e "${Blue}Selected default option '$default_base_image'${Color_Off}"
fi

# Create namespace
echo -e "${BGreen}Creating namespace '$namespace'...${Color_Off}"
microk8s kubectl create namespace "$namespace" 2>/dev/null || echo -e "${BYellow}Namespace '$namespace' already exists.${Color_Off}"

# Verify storage class exists
if ! microk8s kubectl get storageclass "$storage_class" >/dev/null 2>&1; then
    echo -e "${BRed}Warning: Storage class '$storage_class' not found.${Color_Off}"
    echo -e "${BYellow}Available storage classes:${Color_Off}"
    microk8s kubectl get storageclass
    
    # Get the first available storage class as fallback
    available_sc=$(microk8s kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$available_sc" ]]; then
        echo -e "${BYellow}Using available storage class: $available_sc${Color_Off}"
        storage_class="$available_sc"
    fi
fi

# Create configuration data
data="$(echo "{\"provider\":\"microk8s\",\"namespace\":\"$namespace\",\"storage_class\":\"$storage_class\",\"default_size\":\"$size\",\"default_disk_size\":\"$disk_size\",\"ssh_port_base\":\"$ssh_port_base\",\"base_image\":\"$base_image\",\"region\":\"$namespace\"}")"

echo -e "${BGreen}Profile settings:${Color_Off}"
echo "$data" | jq '.'

echo -e "${BWhite}Press enter if you want to save these to a new profile, type 'r' if you wish to start again.${Color_Off}"
read ans

if [[ "$ans" == "r" ]]; then
    $0
    exit
fi

echo -e -n "${BWhite}Please enter your profile name (e.g 'microk8s', must be all lowercase/no specials)\n>> ${Color_Off}"
read title

if [[ "$title" == "" ]]; then
    title="microk8s"
    echo -e "${BGreen}Named profile 'microk8s'${Color_Off}"
fi

echo "$data" | jq > "$AXIOM_PATH/accounts/$title.json"
echo -e "${BGreen}Saved profile '$title' successfully!${Color_Off}"

# Create a basic axiom base image if it doesn't exist
if ! docker image inspect "$base_image" >/dev/null 2>&1; then
    echo -e "${BYellow}Base image '$base_image' not found. Would you like to create a basic one? (y/N)${Color_Off}"
    read create_image
    if [[ "$create_image" == "y" || "$create_image" == "Y" ]]; then
        # Clean up existing images first
        cleanup_images
        
        # Extract the image name without registry prefix for building
        local build_image_name=$(echo "$base_image" | sed 's|localhost:32000/||')
        
        create_base_image "$build_image_name"
        
        # Tag and push to microk8s registry
        if [[ $? -eq 0 ]]; then
            push_image_to_registry "$build_image_name"
        fi
    fi
fi

$AXIOM_PATH/interact/axiom-account "$title"
}

# Create a basic axiom base image
create_base_image() {
    local image_name="$1"
    local registry_tag="localhost:32000/$image_name"
    
    echo -e "${BGreen}Creating basic axiom base image...${Color_Off}"
    
    # Create a temporary directory for Docker build context
    local build_dir=$(mktemp -d)
    
    # Create Dockerfile in the build directory
    cat > "$build_dir/Dockerfile" << 'EOF'
FROM ubuntu:22.04

# Install basic packages and SSH server
RUN apt-get update && apt-get install -y \
    openssh-server \
    sudo \
    curl \
    wget \
    git \
    vim \
    htop \
    net-tools \
    iputils-ping \
    dnsutils \
    nmap \
    && rm -rf /var/lib/apt/lists/*

# Create op user
RUN useradd -m -s /bin/bash op && \
    echo 'op:axiom' | chpasswd && \
    usermod -aG sudo op && \
    echo 'op ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Configure SSH
RUN mkdir /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#Port 22/Port 2266/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Create SSH directory for op user
RUN mkdir -p /home/op/.ssh && \
    chown op:op /home/op/.ssh && \
    chmod 700 /home/op/.ssh

# Create startup script that ensures SSH keys exist and starts SSH daemon
RUN echo '#!/bin/bash' > /start-ssh.sh && \
    echo 'set -e' >> /start-ssh.sh && \
    echo 'echo "Generating SSH host keys..."' >> /start-ssh.sh && \
    echo 'ssh-keygen -A' >> /start-ssh.sh && \
    echo 'echo "SSH host keys generated successfully"' >> /start-ssh.sh && \
    echo 'ls -la /etc/ssh/ssh_host_*' >> /start-ssh.sh && \
    echo 'echo "Starting SSH daemon..."' >> /start-ssh.sh && \
    echo 'exec /usr/sbin/sshd -D -p 2266' >> /start-ssh.sh && \
    chmod +x /start-ssh.sh

# Expose SSH port
EXPOSE 2266

# Start SSH service with key generation
CMD ["/start-ssh.sh"]
EOF

    # Build the image with both local and registry tags
    echo -e "${BYellow}Building Docker image with tags: $image_name and $registry_tag${Color_Off}"
    sudo docker build -t "$image_name" -t "$registry_tag" "$build_dir"
    
    if [[ $? -eq 0 ]]; then
        echo -e "${BGreen}Base image created successfully with both tags!${Color_Off}"
        echo -e "${BGreen}Local tag: $image_name${Color_Off}"
        echo -e "${BGreen}Registry tag: $registry_tag${Color_Off}"
    else
        echo -e "${BRed}Failed to create base image.${Color_Off}"
        rm -rf "$build_dir"
        return 1
    fi
    
    # Clean up
    rm -rf "$build_dir"
}

# Push image to microk8s registry with proper tagging
push_image_to_registry() {
    local image_name="$1"
    local registry_host="localhost:32000"
    local registry_tag="$registry_host/$image_name"
    
    echo -e "${BGreen}Pushing image to MicroK8s registry...${Color_Off}"
    
    # Check if registry is available
    if ! curl -s "http://$registry_host/v2/" >/dev/null 2>&1; then
        echo -e "${BYellow}MicroK8s registry not accessible at $registry_host${Color_Off}"
        echo -e "${BYellow}Make sure registry addon is enabled: microk8s enable registry${Color_Off}"
        echo -e "${BYellow}Falling back to direct containerd import...${Color_Off}"
        
        # Import directly to microk8s containerd with registry tag
        if sudo docker tag "$image_name" "$registry_tag" && sudo docker save "$registry_tag" | microk8s ctr image import -; then
            echo -e "${BGreen}Image imported successfully to MicroK8s containerd as $registry_tag!${Color_Off}"
            return 0
        else
            echo -e "${BRed}Failed to import image to MicroK8s containerd.${Color_Off}"
            return 1
        fi
    fi
    
    # Tag image for registry with proper localhost:32000 prefix
    echo -e "${BYellow}Tagging image as: $registry_tag${Color_Off}"
    
    if sudo docker tag "$image_name" "$registry_tag"; then
        echo -e "${BGreen}Image tagged successfully!${Color_Off}"
        
        # Push to registry
        echo -e "${BYellow}Pushing to MicroK8s registry...${Color_Off}"
        if sudo docker push "$registry_tag"; then
            echo -e "${BGreen}Image pushed successfully to MicroK8s registry!${Color_Off}"
            return 0
        else
            echo -e "${BRed}Failed to push image to registry.${Color_Off}"
            echo -e "${BYellow}Falling back to direct import...${Color_Off}"
            
            # Fallback to direct import
            if sudo docker save "$registry_tag" | microk8s ctr image import -; then
                echo -e "${BGreen}Image imported successfully to MicroK8s containerd!${Color_Off}"
                return 0
            else
                echo -e "${BRed}Failed to import image.${Color_Off}"
                return 1
            fi
        fi
    else
        echo -e "${BRed}Failed to tag image.${Color_Off}"
        return 1
    fi
}

microk8ssetup