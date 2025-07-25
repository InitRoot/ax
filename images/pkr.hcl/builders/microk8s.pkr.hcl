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
      
      # Create startup script for SSH daemon
      "echo '#!/bin/bash' > /start-ssh.sh",
      "echo 'set -e' >> /start-ssh.sh",
      "echo 'echo \"Generating SSH host keys...\"' >> /start-ssh.sh",
      "echo 'ssh-keygen -A' >> /start-ssh.sh",
      "echo 'echo \"SSH host keys generated successfully\"' >> /start-ssh.sh",
      "echo 'ls -la /etc/ssh/ssh_host_*' >> /start-ssh.sh",
      "echo 'echo \"Starting SSH daemon...\"' >> /start-ssh.sh",
      "echo 'exec /usr/sbin/sshd -D -p 2266' >> /start-ssh.sh",
      "chmod +x /start-ssh.sh"
    ]
  }

  post-processor "docker-tag" {
    repository = "localhost:32000/axiom-base"
    tags       = ["latest", var.snapshot_name]
  }
