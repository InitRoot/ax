# MicroK8s VPN Integration Design

## Overview

This document outlines the design for integrating Gluetun VPN sidecars into the existing axiom microk8s provider. **VPN is always enabled by default** for all microk8s instances, providing enhanced security and anonymity.

## Design Principles

1. **Always-On VPN**: VPN is enabled by default for all microk8s instances
2. **Simple Configuration**: Only VPN credentials are collected during setup
3. **Native Integration**: VPN functionality is built into the standard microk8s provider
4. **Transparent Operation**: VPN functionality is transparent to axiom scanning workflows

## Implementation Plan

### 1. Account Setup Enhancement

**File**: `interact/account-helpers/microk8s.sh`

Add VPN credential collection after the base image configuration (VPN is always enabled):

```bash
# VPN Configuration Section (add after line 190)
echo -e "${BGreen}VPN Configuration (required for microk8s)${Color_Off}"
echo -e "${BYellow}Available VPN providers: nordvpn, expressvpn, surfshark, protonvpn${Color_Off}"
echo -e -n "${Green}Please enter your VPN provider (default: 'nordvpn'): \n>> ${Color_Off}"
read vpn_provider
if [[ "$vpn_provider" == "" ]]; then
    vpn_provider="nordvpn"
    echo -e "${Blue}Selected default option 'nordvpn'${Color_Off}"
fi

echo -e -n "${Green}Please enter your VPN username: \n>> ${Color_Off}"
read vpn_username

echo -e -n "${Green}Please enter your VPN password: \n>> ${Color_Off}"
read -s vpn_password
echo

default_countries="Netherlands,United States,United Kingdom"
echo -e -n "${Green}Please enter preferred countries (comma-separated, default: '$default_countries'): \n>> ${Color_Off}"
read vpn_countries
if [[ "$vpn_countries" == "" ]]; then
    vpn_countries="$default_countries"
    echo -e "${Blue}Selected default option '$default_countries'${Color_Off}"
fi
```

Update the configuration data creation to include VPN settings (VPN always enabled):

```bash
# Update data creation (around line 211)
data="$(echo "{\"provider\":\"microk8s\",\"namespace\":\"$namespace\",\"storage_class\":\"$storage_class\",\"default_size\":\"$size\",\"default_disk_size\":\"$disk_size\",\"ssh_port_base\":\"$ssh_port_base\",\"base_image\":\"$base_image\",\"region\":\"$namespace\",\"vpn\":{\"provider\":\"$vpn_provider\",\"username\":\"$vpn_username\",\"password\":\"$vpn_password\",\"countries\":\"$vpn_countries\"}}")"
```

### 2. Provider Functions Enhancement

**File**: `providers/microk8s-functions.sh`

#### 2.1 Enhanced create_instance Function

Modify the `create_instance()` function to always use VPN sidecars (VPN always enabled):

```bash
create_instance() {
    name="$1"
    image_id="$2"
    size="$3"
    region="$4"
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
```

#### 2.2 Standard Instance Creation (Renamed)

The existing [`create_instance()`](providers/microk8s-functions.sh:9) function should be renamed to `create_standard_instance()` to maintain backward compatibility for non-VPN scenarios.

```bash
create_standard_instance() {
    # This is the existing create_instance function content
    # (lines 9-113 from current microk8s-functions.sh)
}
```

#### 2.4 Enhanced Instance Information Functions

Update `instance_pretty()` to show VPN status:

```bash
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
```

#### 2.5 VPN Status Verification Function

Add a new function to check VPN status:

```bash
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
```

### 3. Enhanced Instance Management

#### 3.1 VPN-Aware Fleet Creation

Update `create_instances()` function to handle VPN distribution:

```bash
create_instances() {
    image_id="$1"
    size="$2"
    region="$3"
    user_data="$4"
    timeout="$5"
    disk="$6"

    shift 6
    names=("$@")

    # Check if VPN is enabled
    vpn_enabled="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.vpn.enabled // false')"
    
    if [[ "$vpn_enabled" == "true" ]]; then
        echo "Creating VPN-enabled fleet..."
        vpn_countries="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.vpn.countries')"
        
        # Split countries for distribution
        IFS=',' read -ra COUNTRIES <<< "$vpn_countries"
        country_count=${#COUNTRIES[@]}
        
        echo "Distributing instances across VPN countries: ${COUNTRIES[*]}"
    fi

    # Create all instances in parallel with country distribution
    for i in "${!names[@]}"; do
        name="${names[$i]}"
        
        if [[ "$vpn_enabled" == "true" ]]; then
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
    done

    # Monitor instance creation (existing logic)
    # ... rest of the function remains the same
}
```

### 4. Documentation Updates

#### 4.1 Setup Instructions

Update `MICROK8S_SETUP.md` to include VPN setup instructions:

```markdown
## VPN Configuration (Optional)

The microk8s provider supports VPN integration using Gluetun sidecars. When enabled, all axiom instances will route their traffic through VPN connections.

### Supported VPN Providers
- NordVPN
- ExpressVPN
- Surfshark
- ProtonVPN

### Setup Process
During `axiom-account setup`, you'll be prompted for:
1. Enable VPN (y/N)
2. VPN provider selection
3. VPN username/password
4. Preferred countries for VPN exits

### VPN Features
- Automatic geographic distribution across specified countries
- Network isolation and security
- IP verification and monitoring
- Transparent integration with axiom workflows

### Usage
```bash
# Standard axiom commands work the same way
axiom-init test01
axiom-scan targets.txt -m masscan -p80,443

# Check VPN status
axiom-exec test01 "curl https://ipinfo.io/json"
```
```

#### 4.2 Provider Documentation

Update `MICROK8S_PROVIDER.md` to document VPN capabilities:

```markdown
## VPN Integration

The microk8s provider includes optional VPN integration using Gluetun sidecars.

### Architecture
- **VPN Container**: Gluetun sidecar handles VPN connection
- **Axiom Container**: Standard axiom instance shares network with VPN
- **Network Isolation**: All traffic routes through VPN tunnel
- **Geographic Distribution**: Instances distributed across VPN countries

### Configuration
VPN settings are stored in the axiom.json configuration:
```json
{
  "vpn": {
    "enabled": true,
    "provider": "nordvpn",
    "username": "your_username",
    "password": "your_password",
    "countries": "Netherlands,United States,United Kingdom"
  }
}
```

### Security Considerations
- VPN credentials are stored in axiom configuration
- Network traffic is isolated through VPN tunnel
- Firewall rules allow local cluster communication
- SSH access remains available through NodePort services
```

## Implementation Timeline

1. **Phase 1**: Account setup enhancement with VPN prompts
2. **Phase 2**: Provider function modifications for VPN support
3. **Phase 3**: Enhanced instance management and monitoring
4. **Phase 4**: Documentation and testing
5. **Phase 5**: Integration testing with axiom workflows

## Testing Strategy

1. **Unit Tests**: Individual function testing
2. **Integration Tests**: VPN connectivity and axiom workflow testing
3. **Performance Tests**: VPN overhead and connection stability
4. **Security Tests**: Network isolation and credential handling

## Benefits

1. **Enhanced Anonymity**: All scanning traffic routed through VPN
2. **Geographic Distribution**: Instances appear from different countries
3. **Network Security**: Isolated network environment
4. **Seamless Integration**: No changes to existing axiom workflows
5. **Provider Flexibility**: Support for multiple VPN providers

This design maintains axiom's native approach while adding powerful VPN capabilities that enhance security and geographic distribution for scanning operations.