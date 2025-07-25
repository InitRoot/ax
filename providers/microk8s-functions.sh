#!/bin/bash

AXIOM_PATH="$HOME/.axiom"

###################################################################
#  Create Instance - creates a Kubernetes pod as an axiom instance
#  needed for init and fleet
#
create_instance() {
    name="$1"
    image_id="$2"
    size="$3"
    region="$4"  # For microk8s, this could be namespace
    user_data="$5"
    disk="$6"

    # VPN is always enabled for microk8s - get VPN configuration
    vpn_provider="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.vpn.provider')"
    vpn_username="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.vpn.username')"
    vpn_password="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.vpn.password')"
    vpn_countries="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.vpn.countries')"
    
    # Get standard configuration
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    storage_class="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.storage_class // "microk8s-hostpath"')"
    ssh_port_base="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.ssh_port_base // "30000"')"

    # Default disk size
    if [[ -z "$disk" || "$disk" == "null" ]]; then
        disk="20"
    fi

    # Create namespace if it doesn't exist
    microk8s kubectl create namespace "$namespace" 2>/dev/null || true

    # Generate unique SSH port for this instance
    instance_hash=$(echo -n "$name" | md5sum | cut -c1-4)
    ssh_port=$((ssh_port_base + 0x$instance_hash % 1000))

    # Create PVC for persistent storage
    cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: axiom-$name-pvc
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $storage_class
  resources:
    requests:
      storage: ${disk}Gi
EOF

    # Create SSH service for the pod
    cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: axiom-$name-ssh
  namespace: $namespace
spec:
  type: NodePort
  ports:
  - port: 2266
    targetPort: 2266
    nodePort: $ssh_port
  selector:
    app: axiom-instance
    instance: $name
EOF

    # Create the VPN-enabled pod (always enabled)
    cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: axiom-$name
  namespace: $namespace
  labels:
    app: axiom-instance
    instance: $name
    axiom-size: $size
    vpn-enabled: "true"
spec:
  containers:
  - name: vpn
    image: qmcgaw/gluetun:v3.39.0
    securityContext:
      privileged: true
      capabilities:
        add:
          - NET_ADMIN
    env:
    - name: VPN_SERVICE_PROVIDER
      value: "$vpn_provider"
    - name: VPN_TYPE
      value: "openvpn"
    - name: SERVER_COUNTRIES
      value: "$vpn_countries"
    - name: OPENVPN_USER
      value: "$vpn_username"
    - name: OPENVPN_PASSWORD
      value: "$vpn_password"
    - name: DNS_UPDATE_PERIOD
      value: "0"
    - name: DNS_KEEP_NAMESERVER
      value: "on"
    - name: FIREWALL_OUTBOUND_SUBNETS
      value: "10.42.0.0/15,192.168.1.0/24,10.152.183.0/24"
    - name: FIREWALL_INPUT_PORTS
      value: "2266"
    - name: FIREWALL
      value: "on"
  - name: axiom
    image: $image_id
    ports:
    - containerPort: 2266
    env:
    - name: SSH_USER_DATA
      value: |
$(echo "$user_data" | sed 's/^/        /')
    - name: VPN_ENABLED
      value: "true"
    volumeMounts:
    - name: axiom-data
      mountPath: /home/op/data
    - name: ssh-keys
      mountPath: /home/op/.ssh
    command: ["/bin/bash", "-c"]
    args:
    - |
      echo "Waiting for VPN to be ready..."
      until curl -s https://ipinfo.io/ip > /dev/null 2>&1; do
        sleep 5
      done
      echo "VPN is ready, current IP:"
      curl -s https://ipinfo.io/ip
      echo "Starting SSH server..."
      exec /start-ssh.sh
  volumes:
  - name: axiom-data
    persistentVolumeClaim:
      claimName: axiom-$name-pvc
  - name: ssh-keys
    emptyDir: {}
  restartPolicy: Always
EOF

    # Wait for pod to be ready
    microk8s kubectl wait --for=condition=Ready pod/axiom-$name -n "$namespace" --timeout=600s
    
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to create VPN-enabled instance '$name' in namespace '$namespace'."
        return 1
    fi

    # Allow extra time for VPN connection and SSH server to start
    sleep 60
}

###################################################################
# deletes an instance. if the second argument is "true", will not prompt.
# used by axiom-rm
#
delete_instance() {
    local name="$1"
    local force="$2"
    
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"

    # Check if pod exists
    if ! microk8s kubectl get pod "axiom-$name" -n "$namespace" >/dev/null 2>&1; then
        echo "Instance not found."
        return 1
    fi

    if [[ "$force" != "true" ]]; then
        read -p "Delete '$name' in namespace $namespace? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Aborted."
            return 1
        fi
    fi

    # Delete pod, service, and PVC
    microk8s kubectl delete pod "axiom-$name" -n "$namespace" >/dev/null 2>&1
    microk8s kubectl delete service "axiom-$name-ssh" -n "$namespace" >/dev/null 2>&1
    microk8s kubectl delete pvc "axiom-$name-pvc" -n "$namespace" >/dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        echo "Deleted '$name' from namespace $namespace."
    else
        echo "Failed to delete '$name'."
    fi
}

###################################################################
# Instances functions
# used by many functions in this file
instances() {
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    
    # Get all axiom pods and convert to JSON format similar to cloud providers
    microk8s kubectl get pods -n "$namespace" -l app=axiom-instance -o json | jq '.items | map({
        name: (.metadata.labels.instance // .metadata.name | sub("^axiom-"; "")),
        status: .status.phase,
        ip: .status.podIP,
        node: .spec.nodeName,
        size: (.metadata.labels."axiom-size" // "unknown"),
        namespace: .metadata.namespace,
        created: .metadata.creationTimestamp,
        labels: .metadata.labels
    })'
}

# takes one argument, name of instance, returns raw IP address
# used by axiom-ls axiom-init
instance_ip() {
    name="$1"
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    
    # For microk8s, we need to return localhost with the NodePort
    ssh_port_base="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.ssh_port_base // "30000"')"
    instance_hash=$(echo -n "$name" | md5sum | cut -c1-4)
    ssh_port=$((ssh_port_base + 0x$instance_hash % 1000))
    
    # Check if pod exists and is running
    if microk8s kubectl get pod "axiom-$name" -n "$namespace" >/dev/null 2>&1; then
        echo "127.0.0.1:$ssh_port"
    fi
}

# used by axiom-select axiom-ls
instance_list() {
    instances | jq -r '.[].name'
}

# used by axiom-ls
instance_pretty() {
    local data costs header fields numInstances totalCost

    data=$(instances)
    header="Instance,IP,Status,Node,Size,VPN,Namespace"
    
    fields='.[] | [
        .name,
        (.ip // "N/A"),
        .status,
        (.node // "N/A"),
        .size,
        (if .labels."vpn-enabled" == "true" then "Yes" else "No" end),
        .namespace
    ] | @csv'

    numInstances=$(echo "$data" | jq -r '. | length')
    
    if [[ $numInstances -gt 0 ]]; then
        data=$(echo "$data" | jq -r "$fields" | sort -k1)
    else
        data=""
    fi

    footer="_,_,_,_,_,Instances,$numInstances"

    (echo "$header"; echo "$data"; echo "$footer") \
        | sed 's/"//g' \
        | column -t -s,
}

###################################################################
# VPN Status Verification Function
# Check VPN status for an instance
#
check_vpn_status() {
    name="$1"
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    
    # Check if instance has VPN enabled
    vpn_enabled=$(microk8s kubectl get pod "axiom-$name" -n "$namespace" -o jsonpath='{.metadata.labels.vpn-enabled}' 2>/dev/null)
    
    if [[ "$vpn_enabled" == "true" ]]; then
        echo "Checking VPN status for $name..."
        
        # Get current IP through the instance
        current_ip=$(microk8s kubectl exec "axiom-$name" -n "$namespace" -c axiom -- curl -s https://ipinfo.io/ip 2>/dev/null)
        
        if [[ -n "$current_ip" ]]; then
            echo "Instance $name VPN IP: $current_ip"
            
            # Get location info
            location=$(microk8s kubectl exec "axiom-$name" -n "$namespace" -c axiom -- curl -s https://ipinfo.io/json 2>/dev/null | jq -r '.country + " - " + .city')
            echo "Instance $name VPN Location: $location"
        else
            echo "Warning: Could not determine VPN IP for $name"
        fi
    else
        echo "Instance $name does not have VPN enabled"
    fi
}

###################################################################
#  Dynamically generates axiom's SSH config based on your pod inventory
#  Used for axiom-exec axiom-fleet axiom-ssh
#
generate_sshconfig() {
    sshnew="$AXIOM_PATH/.sshconfig.new$RANDOM"
    sshkey=$(jq -r '.sshkey' < "$AXIOM_PATH/axiom.json")
    generate_sshconfig=$(jq -r '.generate_sshconfig' < "$AXIOM_PATH/axiom.json")
    ssh_port_base="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.ssh_port_base // "30000"')"
    pods="$(instances)"

    # handle lock/cache mode
    if [[ "$generate_sshconfig" == "lock" ]] || [[ "$generate_sshconfig" == "cache" ]] ; then
        echo -e "${BYellow}Using cached SSH config. No regeneration performed. To revert run:${Color_Off} ax ssh --just-generate"
        return 0
    fi

    # create empty SSH config
    echo -n "" > "$sshnew"
    {
        echo -e "ServerAliveInterval 60"
        echo -e "IdentityFile $HOME/.ssh/$sshkey"
    } >> "$sshnew"

    name_count_str=""

    # Helper to get the current count for a given name
    get_count() {
        local key="$1"
        echo "$name_count_str" | grep -oE "$key:[0-9]+" | cut -d: -f2 | tail -n1
    }

    # Helper to set/update the current count for a given name
    set_count() {
        local key="$1"
        local new_count="$2"
        name_count_str="$(echo "$name_count_str" | sed "s/$key:[0-9]*//g")"
        name_count_str="$name_count_str $key:$new_count"
    }

    echo "$pods" | jq -c '.[]?' 2>/dev/null | while read -r pod; do
        # extract fields
        name=$(echo "$pod" | jq -r '.name? // empty' 2>/dev/null)
        status=$(echo "$pod" | jq -r '.status? // empty' 2>/dev/null)

        # skip if name is empty or pod not running
        if [[ -z "$name" ]] || [[ "$status" != "Running" ]]; then
            continue
        fi

        # Calculate SSH port for this instance
        instance_hash=$(echo -n "$name" | md5sum | cut -c1-4)
        ssh_port=$((ssh_port_base + 0x$instance_hash % 1000))

        current_count="$(get_count "$name")"
        if [[ -n "$current_count" ]]; then
            hostname="${name}-${current_count}"
            new_count=$((current_count + 1))
            set_count "$name" "$new_count"
        else
            hostname="$name"
            set_count "$name" 2
        fi

        # add SSH config entry with localhost and calculated port
        echo -e "Host $hostname\n\tHostName 127.0.0.1\n\tUser op\n\tPort $ssh_port\n" >> "$sshnew"
    done

    # validate and apply the new SSH config
    if ssh -F "$sshnew" null -G > /dev/null 2>&1; then
        mv "$sshnew" "$AXIOM_PATH/.sshconfig"
    else
        echo -e "${BRed}Error: Generated SSH config is invalid. Details:${Color_Off}"
        ssh -F "$sshnew" null -G
        cat "$sshnew"
        rm -f "$sshnew"
        return 1
    fi
}

###################################################################
# takes any number of arguments, each argument should be an instance or a glob
# used by axiom-ls axiom-select axiom-fleet axiom-rm axiom-power
#
query_instances() {
    pods="$(instances)"
    selected=""

    for var in "$@"; do
        if [[ "$var" == "\\*" ]]; then
            var="*"
        fi

        if [[ "$var" == *"*"* ]]; then
            var=$(echo "$var" | sed 's/*/.*/g')
            matches=$(echo "$pods" | jq -r '.[].name' | grep -E "^${var}$")
        else
            matches=$(echo "$pods" | jq -r '.[].name' | grep -w -E "^${var}$")
        fi

        if [[ -n "$matches" ]]; then
            selected="$selected $matches"
        fi
    done

    if [[ -z "$selected" ]]; then
        return 1
    fi

    selected=$(echo "$selected" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    echo -n "${selected}" | xargs
}

###################################################################
# used by axiom-fleet, axiom-init, axiom-images
#
get_image_id() {
    query="$1"
    region="${2:-default}"
    all_regions="$3"

    # For microk8s, check images in this order (prioritize registry images):
    # 1. Registry images with axiom-base repository and query as tag (Packer-built images)
    # 2. Registry images (localhost:32000/...)
    # 3. Local docker images
    # 4. Direct containerd images (imported via ctr)
    
    # Check for axiom-base repository with query as tag (this is how Packer creates images)
    local axiom_base_tag="localhost:32000/axiom-base:$query"
    if docker image inspect "$axiom_base_tag" >/dev/null 2>&1; then
        echo "$axiom_base_tag"
        return 0
    fi
    
    # Check registry-tagged version
    local registry_image="localhost:32000/$query"
    if microk8s ctr images list | grep -q "$registry_image"; then
        echo "$registry_image"
        return 0
    fi
    
    # Check if image exists locally in docker
    if docker image inspect "$query" >/dev/null 2>&1; then
        echo "$query"
        return 0
    fi
    
    # Check if image exists in microk8s containerd (but avoid docker.io/library images)
    if microk8s ctr images list | grep -q "^$query" && ! echo "$query" | grep -q "docker.io/library"; then
        echo "$query"
        return 0
    fi
    
    # Try to find image with axiom prefix
    if docker image inspect "axiom-$query" >/dev/null 2>&1; then
        echo "axiom-$query"
        return 0
    fi
    
    # Check axiom prefix in containerd
    if microk8s ctr images list | grep -q "axiom-$query"; then
        echo "axiom-$query"
        return 0
    fi
    
    echo ""
}

# Manage snapshots (Docker images for microk8s)
get_snapshots() {
    echo "Available images for axiom:"
    echo
    
    # Get all available images and extract selectable names
    echo "=== Selectable Images ==="
    printf "%-40s %-10s %-s\n" "Name" "Size" "Location"
    
    # Check Docker images with axiom-base repository and extract tags
    docker images localhost:32000/axiom-base --format "{{.Tag}}\t{{.Size}}" 2>/dev/null | while IFS=$'\t' read -r tag size; do
        if [[ "$tag" != "latest" && "$tag" != "<none>" ]]; then
            printf "%-40s %-10s %-s\n" "$tag" "$size" "Registry"
        fi
    done
    
    # Check local Docker images with axiom prefix
    docker images --filter "reference=axiom-*" --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" 2>/dev/null | while IFS=$'\t' read -r image size; do
        # Extract just the image name without localhost:32000/ prefix
        image_name=$(echo "$image" | sed 's|localhost:32000/||')
        printf "%-40s %-10s %-s\n" "$image_name" "$size" "Local"
    done
    
    # Check containerd images
    microk8s ctr images list 2>/dev/null | grep -E "axiom-.*-[0-9]+" | awk '{print $1 "\t" $4}' | while IFS=$'\t' read -r image size; do
        # Extract just the image name without localhost:32000/ prefix
        image_name=$(echo "$image" | sed 's|localhost:32000/axiom-base:||' | sed 's|localhost:32000/||')
        if [[ "$image_name" =~ axiom-.*-[0-9]+ ]]; then
            printf "%-40s %-10s %-s\n" "$image_name" "$size" "Containerd"
        fi
    done
    
    echo
    echo "=== All Available Images (for reference) ==="
    echo "MicroK8s Containerd Images:"
    microk8s ctr images list | grep -E "(axiom|localhost:32000)" | awk '{print "  " $1 "\t" $4}' | column -t
    echo
    echo "Local Docker Images:"
    docker images --filter "reference=axiom-*" --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" 2>/dev/null || echo "  Docker not accessible or no axiom images found"
}

# axiom-images
delete_snapshot() {
    name="$1"
    docker rmi "$name" -f 2>/dev/null || docker rmi "axiom-$name" -f 2>/dev/null
}

# axiom-images - create Docker image from running pod
create_snapshot() {
    instance="$1"
    snapshot_name="$2"
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    
    # Commit the running pod to a new Docker image
    container_id=$(microk8s kubectl get pod "axiom-$instance" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/docker:\/\///')
    docker commit "$container_id" "$snapshot_name"
}

###################################################################
# Get data about regions (namespaces for microk8s)
# used by axiom-regions
list_regions() {
    microk8s kubectl get namespaces -o name | sed 's/namespace\///'
}

# used by axiom-regions
regions() {
    microk8s kubectl get namespaces -o json | jq -r '.items[].metadata.name'
}

###################################################################
#  Manage power state of instances (pod lifecycle)
#  Used for axiom-power
#
poweron() {
    instance_name="$1"
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    
    # Scale up the pod (if it was scaled down)
    microk8s kubectl patch pod "axiom-$instance_name" -n "$namespace" -p '{"spec":{"containers":[{"name":"axiom","image":"'$(microk8s kubectl get pod "axiom-$instance_name" -n "$namespace" -o jsonpath='{.spec.containers[0].image}')'"}]}}'
}

# axiom-power
poweroff() {
    instance_name="$1"
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    
    # For pods, we can't really "power off", but we can delete and recreate
    # This is a limitation of the Kubernetes model
    echo "Warning: Kubernetes pods cannot be powered off. Use axiom-rm to delete."
    return 1
}

# axiom-power
reboot() {
    instance_name="$1"
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    
    microk8s kubectl delete pod "axiom-$instance_name" -n "$namespace" --grace-period=0 --force
    # The pod should be recreated automatically if it's part of a deployment
    # For standalone pods, this will just delete it
}

# axiom-power axiom-images
instance_id() {
    name="$1"
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    
    microk8s kubectl get pod "axiom-$name" -n "$namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null
}

###################################################################
#  List available instance sizes (resource configurations)
#  Used by ax sizes
#
sizes_list() {
    echo "Available sizes for microk8s instances:"
    echo "Size        CPU    Memory    Description"
    echo "nano        0.1    128Mi     Minimal resources"
    echo "micro       0.25   256Mi     Very small"
    echo "small       0.5    512Mi     Small instance"
    echo "medium      1      1Gi       Medium instance"
    echo "large       2      2Gi       Large instance"
    echo "xlarge      4      4Gi       Extra large instance"
}

###################################################################
# experimental v2 function
# deletes multiple instances at the same time by name
# used by axiom-rm --multi
#
delete_instances() {
    names="$1"
    force="$2"
    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"

    name_array=($names)
    
    if [ "$force" == "true" ]; then
        echo -e "${Red}Deleting: ${name_array[@]}...${Color_Off}"
        for name in "${name_array[@]}"; do
            microk8s kubectl delete pod "axiom-$name" -n "$namespace" >/dev/null 2>&1 &
            microk8s kubectl delete service "axiom-$name-ssh" -n "$namespace" >/dev/null 2>&1 &
            microk8s kubectl delete pvc "axiom-$name-pvc" -n "$namespace" >/dev/null 2>&1 &
        done
        wait
    else
        for name in "${name_array[@]}"; do
            echo -e -n "Are you sure you want to delete $name? (y/N): "
            read ans
            if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
                microk8s kubectl delete pod "axiom-$name" -n "$namespace" >/dev/null 2>&1
                microk8s kubectl delete service "axiom-$name-ssh" -n "$namespace" >/dev/null 2>&1
                microk8s kubectl delete pvc "axiom-$name-pvc" -n "$namespace" >/dev/null 2>&1
            else
                echo "Deletion aborted for $name."
            fi
        done
    fi
}

###################################################################
# experimental v2 function
# create multiple instances at the same time
# used by axiom-fleet2
#
create_instances() {
    image_id="$1"
    size="$2"
    region="$3"  # namespace for microk8s
    user_data="$4"
    timeout="$5"
    disk="$6"

    shift 6
    names=("$@")

    namespace="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.namespace // "axiom"')"
    storage_class="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.storage_class // "microk8s-hostpath"')"
    ssh_port_base="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.ssh_port_base // "30000"')"

    # VPN-aware fleet creation with geographic distribution
    vpn_countries="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.vpn.countries')"
    
    if [[ -n "$vpn_countries" && "$vpn_countries" != "null" ]]; then
        echo "Creating VPN-enabled fleet with geographic distribution..."
        
        # Split countries for distribution
        IFS=',' read -ra COUNTRIES <<< "$vpn_countries"
        country_count=${#COUNTRIES[@]}
        
        echo "Distributing instances across VPN countries: ${COUNTRIES[*]}"
    fi

    # Create namespace if it doesn't exist
    microk8s kubectl create namespace "$namespace" 2>/dev/null || true

    # Create all instances in parallel with country distribution
    for i in "${!names[@]}"; do
        name="${names[$i]}"
        
        if [[ -n "$vpn_countries" && "$vpn_countries" != "null" ]]; then
            # Select country for this instance (round-robin)
            country_index=$((i % country_count))
            selected_country="${COUNTRIES[$country_index]}"
            
            echo "Creating $name with VPN exit in $selected_country"
            
            # Temporarily modify the config for this instance
            temp_config=$(mktemp)
            jq --arg country "$selected_country" '.vpn.countries = $country' "$AXIOM_PATH/axiom.json" > "$temp_config"
            cp "$temp_config" "$AXIOM_PATH/axiom.json"
            rm "$temp_config"
        fi
        
        (
            create_instance "$name" "$image_id" "$size" "$region" "$user_data" "$disk"
        ) &
        
        # Restore original config after starting instance creation
        if [[ -n "$vpn_countries" && "$vpn_countries" != "null" ]]; then
            temp_config=$(mktemp)
            jq --arg countries "$vpn_countries" '.vpn.countries = $countries' "$AXIOM_PATH/axiom.json" > "$temp_config"
            cp "$temp_config" "$AXIOM_PATH/axiom.json"
            rm "$temp_config"
        fi
    done

    # Monitor instance creation
    processed_file=$(mktemp)
    interval=10
    elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        all_ready=true

        for name in "${names[@]}"; do
            if microk8s kubectl get pod "axiom-$name" -n "$namespace" >/dev/null 2>&1; then
                status=$(microk8s kubectl get pod "axiom-$name" -n "$namespace" -o jsonpath='{.status.phase}')
                if [[ "$status" == "Running" ]]; then
                    if ! grep -q "^$name\$" "$processed_file"; then
                        echo "$name" >> "$processed_file"
                        instance_hash=$(echo -n "$name" | md5sum | cut -c1-4)
                        ssh_port=$((ssh_port_base + 0x$instance_hash % 1000))
                        >&2 echo -e "${BWhite}Initialized instance '${BGreen}$name${Color_Off}${BWhite}' at '${BGreen}127.0.0.1:$ssh_port${BWhite}'!"
                    fi
                else
                    all_ready=false
                fi
            else
                all_ready=false
            fi
        done

        if $all_ready; then
            rm -f "$processed_file"
            sleep 30
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    rm -f "$processed_file"
    return 1
}