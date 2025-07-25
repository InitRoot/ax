provisioner "file" {
    source      = "./configs"
    destination = "/tmp/configs"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    inline = [
        "echo 'Starting Docker-compatible provisioning for microk8s...'",

        # Basic package updates and essential tools
        "apt update -qq",
        "DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew install -y net-tools zsh zsh-syntax-highlighting zsh-autosuggestions jq build-essential python3-pip unzip git p7zip libpcap-dev rubygems ruby-dev grc alien rsync -qq",
        
        # Skip firewall configuration in containers (not supported)
        "echo 'Skipping firewall configuration in container environment'",

        "echo 'Creating OP user'",
        "useradd -G sudo -s /usr/bin/zsh -m op || true",
        "mkdir -p /home/op/.ssh /home/op/c2 /home/op/recon/ /home/op/lists /home/op/go /home/op/bin /home/op/.config/ /home/op/.cache /home/op/work/ /home/op/.config/amass",
        "rm -rf /etc/update-motd.d/* || true",
        "/bin/su -l op -c 'wget -q https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O - | sh'",
        "chown -R op:op /home/op",
        "touch /home/op/.sudo_as_admin_successful",
        "touch /home/op/.cache/motd.legal-displayed",
        "chown -R op:op /home/op",
        "echo 'op:${var.op_random_password}' | chpasswd",
        "echo 'root:${var.op_random_password}' | chpasswd",

        "echo 'Moving Config files (container-compatible)'",
        "mv /tmp/configs/sudoers /etc/sudoers || cp /tmp/configs/sudoers /etc/sudoers",
        "chown root:root /etc/sudoers /etc/sudoers.d -R || true",
        "mv /tmp/configs/bashrc /home/op/.bashrc",
        "mv /tmp/configs/zshrc /home/op/.zshrc",
        # Skip SSH config replacement to keep working setup
        "echo 'Keeping existing SSH configuration for container compatibility'",
        "mv /tmp/configs/00-header /etc/update-motd.d/00-header",
        "mv /tmp/configs/authorized_keys /home/op/.ssh/authorized_keys",
        "mv /tmp/configs/tmux-splash.sh /home/op/bin/tmux-splash.sh",
        "/bin/su -l op -c 'sudo chmod 600 /home/op/.ssh/authorized_keys'",
        "chown -R op:op /home/op",
        # Skip SSH restart since we're not changing config
        "chmod +x /etc/update-motd.d/00-header",

        "echo 'Installing Golang ${var.golang_version}'",
        "wget -q https://golang.org/dl/go${var.golang_version}.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go${var.golang_version}.linux-amd64.tar.gz && rm go${var.golang_version}.linux-amd64.tar.gz",
        "export GOPATH=/home/op/go",

        "echo 'Installing Docker'",
        "curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh && rm get-docker.sh",
        "sudo usermod -aG docker op",

        "echo 'Installing Interlace'",
        "git clone https://github.com/codingo/Interlace.git /home/op/recon/interlace && cd /home/op/recon/interlace/ && python3 setup.py install",

        "echo 'Skipping SSH and network optimizations for container compatibility'",
        # Skip SSH config modifications to preserve working setup
        # Skip sysctl modifications as they don't work in containers
        "echo 'Installing assetfinder'",
        "/bin/su -l op -c '/usr/local/go/bin/go install github.com/tomnomnom/assetfinder@latest'",
        "echo 'Downloading Files and Lists'",

        "echo 'Downloading axiom-dockerfiles'",
        "git clone https://github.com/attacksurge/dockerfiles.git /home/op/lists/axiom-dockerfiles",

        "echo 'Downloading cent'",
        "git clone https://github.com/xm1k3/cent.git /home/op/lists/cent",

        "echo 'Downloading permutations'",
        "wget -q -O /home/op/lists/permutations.txt https://gist.github.com/six2dez/ffc2b14d283e8f8eff6ac83e20a3c4b4/raw",

        "echo 'Downloading Trickest resolvers'",
        "wget -q -O /home/op/lists/resolvers.txt https://raw.githubusercontent.com/trickest/resolvers/master/resolvers.txt",

        "echo 'Downloading SecLists'",
        "#git clone https://github.com/danielmiessler/SecLists.git /home/op/lists/seclists",

        "echo 'Installing ax framework'",
        "/bin/su -l op -c 'git clone https://github.com/attacksurge/ax.git /home/op/.axiom && cd /home/op/.axiom/interact && ./axiom-configure --setup --shell zsh --unattended'",


        "echo 'Installing anew'",
        "/bin/su -l op -c '/usr/local/go/bin/go install -v github.com/tomnomnom/anew@latest'",


        "echo 'Installing puredns'",
        "/bin/su -l op -c 'GO111MODULE=on /usr/local/go/bin/go install github.com/d3mondev/puredns/v2@latest'",

        "echo 'Installing s3scanner'",
        "/bin/su -l op -c '/usr/local/go/bin/go install -v github.com/sa7mon/s3scanner@latest'",

        "echo 'Installing shuffledns'",
        "/bin/su -l op -c 'GO111MODULE=on /usr/local/go/bin/go install github.com/projectdiscovery/shuffledns/cmd/shuffledns@latest'",

        "echo 'Installing httpx'",
        "/bin/su -l op -c 'GO111MODULE=on /usr/local/go/bin/go install github.com/projectdiscovery/httpx/cmd/httpx@latest'",
        
        "echo 'Installing katana'",
        "/bin/su -l op -c '/usr/local/go/bin/go install github.com/projectdiscovery/katana/cmd/katana@latest'",

        "echo 'Installing nmap'",
        "apt install nmap -y -qq",

        "echo 'Installing sqlmap'",
        "git clone --depth 1 https://github.com/sqlmapproject/sqlmap.git /home/op/recon/sqlmap-dev",

        "echo 'Installing gobuster'",
        "cd /tmp && wget -q -O /tmp/gobuster.7z https://github.com/OJ/gobuster/releases/download/v3.1.0/gobuster-linux-amd64.7z && p7zip -d /tmp/gobuster.7z && sudo mv /tmp/gobuster-linux-amd64/gobuster /usr/bin/gobuster && sudo chmod +x /usr/bin/gobuster",

        "echo 'Installing google-chrome'",
        "wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && cd /tmp/ && sudo apt install -y /tmp/chrome.deb -qq && apt --fix-broken install -qq",

        "echo 'Installing subfinder'",
        "/bin/su -l op -c 'GO111MODULE=on /usr/local/go/bin/go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest'",

        "echo 'Installing nuclei'",
        "/bin/su -l op -c 'GO111MODULE=on /usr/local/go/bin/go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest && /home/op/go/bin/nuclei'",


        "echo 'Installing testssl'",
        "git clone --depth 1 https://github.com/drwetter/testssl.sh.git /home/op/recon/testssl.sh",

        "echo 'Installing tlsx'",
        "/bin/su -l op -c 'GO111MODULE=on /usr/local/go/bin/go install github.com/projectdiscovery/tlsx/cmd/tlsx@latest'",

        "echo 'Installing trufflehog'",
        "/bin/su -l op -c 'curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/master/scripts/install.sh | sudo sh -s -- -b /usr/local/bin'",

        "echo 'Installing waybackurls'",
        "/bin/su -l op -c '/usr/local/go/bin/go install github.com/tomnomnom/waybackurls@latest'",

        "echo 'Installing webscreenshot'",
        "/bin/su -l op -c 'pip3 install webscreenshot'",

        "echo 'Installing masscan'",
        "apt install masscan -y -qq",

        "echo 'Removing unneeded Docker images'",
        "/bin/su -l op -c 'docker image prune -f'",

        "/bin/su -l op -c '/usr/local/go/bin/go  clean -modcache'",
        "/bin/su -l op -c 'wget -q -O gf-completion.zsh https://raw.githubusercontent.com/tomnomnom/gf/master/gf-completion.zsh && cat gf-completion.zsh >> /home/op/.zshrc && rm gf-completion.zsh && cd'",
        "/bin/su -l root -c 'apt-get clean'",
        "echo \"CkNvbmdyYXR1bGF0aW9ucywgeW91ciBidWlsZCBpcyBhbG1vc3QgZG9uZSEKCiDilojilojilojilojilojilZcg4paI4paI4pWXICDilojilojilZcgICAg4paI4paI4paI4paI4paI4paI4pWXIOKWiOKWiOKVlyAgIOKWiOKWiOKVl+KWiOKWiOKVl+KWiOKWiOKVlyAgICAg4paI4paI4paI4paI4paI4paI4pWXCuKWiOKWiOKVlOKVkOKVkOKWiOKWiOKVl+KVmuKWiOKWiOKVl+KWiOKWiOKVlOKVnSAgICDilojilojilZTilZDilZDilojilojilZfilojilojilZEgICDilojilojilZHilojilojilZHilojilojilZEgICAgIOKWiOKWiOKVlOKVkOKVkOKWiOKWiOKVlwrilojilojilojilojilojilojilojilZEg4pWa4paI4paI4paI4pWU4pWdICAgICDilojilojilojilojilojilojilZTilZ3ilojilojilZEgICDilojilojilZHilojilojilZHilojilojilZEgICAgIOKWiOKWiOKVkSAg4paI4paI4pWRCuKWiOKWiOKVlOKVkOKVkOKWiOKWiOKVkSDilojilojilZTilojilojilZcgICAgIOKWiOKWiOKVlOKVkOKVkOKWiOKWiOKVl+KWiOKWiOKVkSAgIOKWiOKWiOKVkeKWiOKWiOKVkeKWiOKWiOKVkSAgICAg4paI4paI4pWRICDilojilojilZEK4paI4paI4pWRICDilojilojilZHilojilojilZTilZ0g4paI4paI4pWXICAgIOKWiOKWiOKWiOKWiOKWiOKWiOKVlOKVneKVmuKWiOKWiOKWiOKWiOKWiOKWiOKVlOKVneKWiOKWiOKVkeKWiOKWiOKWiOKWiOKWiOKWiOKWiOKVl+KWiOKWiOKWiOKWiOKWiOKWiOKVlOKVnQrilZrilZDilZ0gIOKVmuKVkOKVneKVmuKVkOKVnSAg4pWa4pWQ4pWdICAgIOKVmuKVkOKVkOKVkOKVkOKVkOKVnSAg4pWa4pWQ4pWQ4pWQ4pWQ4pWQ4pWdIOKVmuKVkOKVneKVmuKVkOKVkOKVkOKVkOKVkOKVkOKVneKVmuKVkOKVkOKVkOKVkOKVkOKVnQoKTWFpbnRhaW5lcjogMHh0YXZpYW4KCvCdk7LwnZO38J2TvPCdk7nwnZOy8J2Tu/Cdk67wnZOtIPCdk6vwnZSCIPCdk6rwnZSB8J2TsvCdk7jwnZO2OiDwnZO98J2TsfCdk64g8J2TrfCdlILwnZO38J2TqvCdk7bwnZOy8J2TrCDwnZOy8J2Tt/Cdk6/wnZO78J2TqvCdk7zwnZO98J2Tu/Cdk77wnZOs8J2TvfCdk77wnZO78J2TriDwnZOv8J2Tu/Cdk6rwnZO28J2TrvCdlIDwnZO48J2Tu/Cdk7Qg8J2Tr/Cdk7jwnZO7IPCdk67wnZO/8J2TrvCdk7vwnZSC8J2Tq/Cdk7jwnZOt8J2UgiEgLSBA8J2TufCdk7vwnZSCMPCdk6zwnZOsIEAw8J2UgfCdk73wnZOq8J2Tv/Cdk7LwnZOq8J2TtwoKUmVhZCB0aGVzZSB3aGlsZSB5b3UncmUgd2FpdGluZyB0byBnZXQgc3RhcnRlZCA6KQoKICAgIC0gTmV3IFdpa2k6IGh0dHBzOi8vYXgtZnJhbWV3b3JrLmdpdGJvb2suaW8vd2lraS8KICAgIC0gRXhpc3RpbmcgVXNlcnM6IGh0dHBzOi8vYXgtZnJhbWV3b3JrLmdpdGJvb2suaW8vd2lraS9vdmVydmlldy9leGlzdGluZy11c2VycwogICAgLSBCcmluZyBZb3VyIE93biBQcm92aXNpb25lcjogaHR0cHM6Ly9heC1mcmFtZXdvcmsuZ2l0Ym9vay5pby93aWtpL2Z1bmRhbWVudGFscy9icmluZy15b3VyLW93bi1wcm92aXNpb25lciAKICAgIC0gRmlsZXN5c3RlbSBVdGlsaXRpZXM6IGh0dHBzOi8vYXgtZnJhbWV3b3JrLmdpdGJvb2suaW8vd2lraS9mdW5kYW1lbnRhbHMvZmlsZXN5c3RlbS11dGlsaXRpZXMKICAgIC0gRmxlZXRzOiBodHRwczovL2F4LWZyYW1ld29yay5naXRib29rLmlvL3dpa2kvZnVuZGFtZW50YWxzL2ZsZWV0cwogICAgLSBTY2FuczogaHR0cHM6Ly9heC1mcmFtZXdvcmsuZ2l0Ym9vay5pby93aWtpL2Z1bmRhbWVudGFscy9zY2FuCg==\" | base64 -d",
        "touch /home/op/.z",
        "chown -R op:op /home/op",
        "chown root:root /etc/sudoers /etc/sudoers.d -R"
    ]
    inline_shebang = "/bin/sh -x"
  }
}
