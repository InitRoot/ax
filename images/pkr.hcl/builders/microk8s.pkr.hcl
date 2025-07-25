packer {
  required_plugins {
    docker = {
      version = ">= 1.0.8"
      source  = "github.com/hashicorp/docker"
    }
  }
}

variable "golang_version" {
  type = string
}

variable "variant" {
  type = string
}

variable "op_random_password" {
  type = string
}

variable "snapshot_name" {
  type = string
}

variable "base_image" {
  type    = string
  default = "ubuntu:22.04"
}

variable "image_name" {
  type    = string
  default = "axiom-base"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

source "docker" "microk8s" {
  image  = var.base_image
  commit = true
  changes = [
    "EXPOSE 2266",
    "CMD [\"/start-ssh.sh\"]"
  ]
}

build {
  sources = ["source.docker.microk8s"]

  # Basic SSH setup for container compatibility
  provisioner "shell" {
    inline = [
      "apt-get update -qq",
      "DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server sudo curl wget git vim htop net-tools iputils-ping dnsutils nmap",
      "rm -rf /var/lib/apt/lists/*",
      
      # Create op user if it doesn't exist
      "id -u op >/dev/null 2>&1 || useradd -m -s /bin/bash op",
      "echo 'op:${var.op_random_password}' | chpasswd",
      "usermod -aG sudo op",
      "echo 'op ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers",
      
      # SSH configuration
      "mkdir -p /var/run/sshd",
      "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config",
      "sed -i 's/#Port 22/Port 2266/' /etc/ssh/sshd_config",
      "sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config",
      "sed -i 's/#HostKey \\/etc\\/ssh\\/ssh_host_rsa_key/HostKey \\/etc\\/ssh\\/ssh_host_rsa_key/' /etc/ssh/sshd_config",
      "sed -i 's/#HostKey \\/etc\\/ssh\\/ssh_host_ecdsa_key/HostKey \\/etc\\/ssh\\/ssh_host_ecdsa_key/' /etc/ssh/sshd_config",
      "sed -i 's/#HostKey \\/etc\\/ssh\\/ssh_host_ed25519_key/HostKey \\/etc\\/ssh\\/ssh_host_ed25519_key/' /etc/ssh/sshd_config",
      
      # Create SSH directory for op user
      "mkdir -p /home/op/.ssh",
      "chown op:op /home/op/.ssh",
      "chmod 700 /home/op/.ssh",
      
      # Create enhanced startup script for SSH daemon with user data processing
      "cat > /start-ssh.sh << 'SCRIPT_EOF'",
      "#!/bin/bash",
      "set -e",
      "echo 'Generating SSH host keys...'",
      "ssh-keygen -A",
      "echo 'SSH host keys generated successfully'",
      "",
      "# Process SSH_USER_DATA environment variable",
      "if [ -n \"$SSH_USER_DATA\" ]; then",
      "    echo 'Processing SSH user data...'",
      "    # Extract SSH public key from cloud-init data",
      "    SSH_KEY=$(echo \"$SSH_USER_DATA\" | grep -A 10 'ssh-authorized-keys:' | grep 'ssh-rsa\\|ssh-ed25519\\|ecdsa-sha2' | head -1 | sed 's/^[[:space:]]*-[[:space:]]*//')",
      "    if [ -n \"$SSH_KEY\" ]; then",
      "        echo 'Setting up SSH key for op user...'",
      "        # Fix home directory ownership and permissions for SSH",
      "        chown op:op /home/op",
      "        chmod 755 /home/op",
      "        mkdir -p /home/op/.ssh",
      "        echo \"$SSH_KEY\" > /home/op/.ssh/authorized_keys",
      "        chmod 600 /home/op/.ssh/authorized_keys",
      "        chmod 700 /home/op/.ssh",
      "        chown -R op:op /home/op/.ssh",
      "        echo 'SSH key setup completed'",
      "    else",
      "        echo 'No SSH key found in user data'",
      "    fi",
      "else",
      "    echo 'No SSH_USER_DATA environment variable found'",
      "fi",
      "",
      "echo 'Starting SSH daemon...'",
      "exec /usr/sbin/sshd -D -p 2266",
      "SCRIPT_EOF",
      "chmod +x /start-ssh.sh"
    ]
  }

  post-processor "docker-tag" {
    repository = "localhost:32000/axiom-base"
    tags       = ["latest", var.snapshot_name]
  }
