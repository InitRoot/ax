provisioner "file" {
    source      = "./configs"
    destination = "/tmp/configs"
  }

  provisioner "shell" {
    inline = [
      "echo 'Starting Docker-compatible provisioning for microk8s...'",
      
      # Basic package updates (skip dist-upgrade to avoid issues)
      "apt-get update -qq",
      "DEBIAN_FRONTEND=noninteractive apt-get install -y zsh zsh-syntax-highlighting zsh-autosuggestions jq build-essential python3-pip unzip git p7zip libpcap-dev rubygems ruby-dev grc",
      
      # Create OP user (conditional)
      "id -u op >/dev/null 2>&1 || useradd -G sudo -s /usr/bin/zsh -m op",
      "mkdir -p /home/op/.ssh /home/op/c2 /home/op/recon/ /home/op/lists /home/op/go /home/op/bin /home/op/.config/ /home/op/.cache /home/op/work/ /home/op/.config/amass",
      
      # Install Oh My Zsh for op user
      "/bin/su -l op -c 'wget -q https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O - | sh'",
      "chown -R op:op /home/op",
      "touch /home/op/.sudo_as_admin_successful",
      "touch /home/op/.cache/motd.legal-displayed",
      
      # Set passwords
      "echo 'op:${var.op_random_password}' | chpasswd",
      "echo 'root:${var.op_random_password}' | chpasswd",
      
      # Move config files (avoid pkexec and problematic operations)
      "echo 'Moving Config files'",
      "cp /tmp/configs/bashrc /home/op/.bashrc",
      "cp /tmp/configs/zshrc /home/op/.zshrc", 
      "cp /tmp/configs/00-header /etc/update-motd.d/00-header",
      "cp /tmp/configs/authorized_keys /home/op/.ssh/authorized_keys",
      "cp /tmp/configs/tmux-splash.sh /home/op/bin/tmux-splash.sh",
      "chmod 600 /home/op/.ssh/authorized_keys",
      "chmod +x /etc/update-motd.d/00-header",
      "chmod +x /home/op/bin/tmux-splash.sh",
      "chown -R op:op /home/op",
      
      # Install Golang
      "echo 'Installing Golang ${var.golang_version}'",
      "wget -q https://golang.org/dl/go${var.golang_version}.linux-amd64.tar.gz && tar -C /usr/local -xzf go${var.golang_version}.linux-amd64.tar.gz && rm go${var.golang_version}.linux-amd64.tar.gz",
      "export GOPATH=/home/op/go",
      
      # Install Docker (skip if already installed)
      "echo 'Installing Docker'",
      "which docker || (curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh && rm get-docker.sh)",
      "usermod -aG docker op || true",
      
      # Install Interlace
      "echo 'Installing Interlace'",
      "git clone https://github.com/codingo/Interlace.git /home/op/recon/interlace && cd /home/op/recon/interlace/ && python3 setup.py install",
      
      # SSH optimizations (container-compatible)
      "echo 'Optimizing SSH Connections'",
      "echo 'ClientAliveInterval 60' >> /etc/ssh/sshd_config",
      "echo 'ClientAliveCountMax 60' >> /etc/ssh/sshd_config", 
      "echo 'MaxSessions 100' >> /etc/ssh/sshd_config",
      
      # Install nmap (simplified approach)
      "echo 'Installing nmap'",
      "apt-get install -y nmap",
      
      # Final cleanup and permissions
      "chown -R op:op /home/op",
      "apt-get clean",
      
      "echo 'Docker-compatible provisioning completed successfully!'"
    ]
    inline_shebang = "/bin/bash -e"
  }
}