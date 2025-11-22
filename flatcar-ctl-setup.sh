#!/bin/bash

# Check if hostname parameter is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <hostname>"
    exit 1
fi

HOSTNAME=$1
BUTANE_VERSION="v0.25.1"
BUTANE_BINARY="butane"
FLATCAR_YAML="flatcar.yaml"
FLATCAR_IGN="flatcar.ign"

# Create directory for generated files
mkdir -p generated

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to download Butane if not present
download_butane() {
    local arch="x86_64"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        arch="arm64"
    fi
    
    echo "Downloading Butane ${BUTANE_VERSION}..."
    curl -L "https://github.com/coreos/butane/releases/download/${BUTANE_VERSION}/butane-${arch}-unknown-linux-gnu" -o "${BUTANE_BINARY}"
    chmod +x "${BUTANE_BINARY}"
}

# Generate Flatcar configuration YAML
generate_flatcar_yaml() {
    cat > "${FLATCAR_YAML}" << EOF
version: 1.0.0
variant: flatcar
storage:
  links:
    - target: /opt/extensions/kubernetes/kubernetes-v1.33.2-x86-64.raw
      path: /etc/extensions/kubernetes.raw
      hard: false
  files:
    - path: /etc/sysupdate.kubernetes.d/kubernetes-v1.33.conf
      contents:
        source: https://extensions.flatcar.org/extensions/kubernetes/kubernetes-v1.33.conf
    - path: /etc/sysupdate.d/noop.conf
      contents:
        source: https://extensions.flatcar.org/extensions/noop.conf
    - path: /opt/extensions/kubernetes/kubernetes-v1.33.2-x86-64.raw
      contents:
        source: https://extensions.flatcar.org/extensions/kubernetes-v1.33.2-x86-64.raw
    - path: /etc/hostname
      contents:
        inline: "${HOSTNAME}"
systemd:
  units:
    - name: systemd-sysupdate.timer
      enabled: true
    - name: systemd-sysupdate.service
      dropins:
        - name: kubernetes.conf
          contents: |
            [Service]
            ExecStartPre=/usr/bin/sh -c "readlink --canonicalize /etc/extensions/kubernetes.raw > /tmp/kubernetes"
            ExecStartPre=/usr/lib/systemd/systemd-sysupdate -C kubernetes update
            ExecStartPost=/usr/bin/sh -c "readlink --canonicalize /etc/extensions/kubernetes.raw > /tmp/kubernetes-new"
            ExecStartPost=/usr/bin/sh -c "if ! cmp --silent /tmp/kubernetes /tmp/kubernetes-new; then touch /run/reboot-required; fi"
    - name: locksmithd.service
      # NOTE: To coordinate the node reboot in this context, we recommend to use Kured.
      mask: true
    - name: kubeadm.service
      enabled: true
      contents: |
        [Unit]
        Description=Kubeadm service
        Requires=containerd.service
        After=containerd.service
        After=network-online.target
        ConditionPathExists=!/etc/kubernetes/kubelet.conf
        [Service]
        ExecStartPre=/usr/bin/kubeadm init
        ExecStartPre=/usr/bin/mkdir /home/core/.kube
        ExecStartPre=/usr/bin/cp /etc/kubernetes/admin.conf /home/core/.kube/config
        ExecStart=/usr/bin/chown -R core:core /home/core/.kube
        [Install]
        WantedBy=multi-user.target
EOF
}

# Convert YAML to IGN using Butane
convert_to_ign() {
    if ! command_exists "./${BUTANE_BINARY}"; then
        download_butane
    fi
    
    echo "Converting YAML to IGN format..."
    ./${BUTANE_BINARY} -p -d . "${FLATCAR_YAML}" > "${FLATCAR_IGN}"
}

# Install Flatcar Linux
install_flatcar() {
    if ! command_exists flatcar-install; then
        echo "Error: flatcar-install command not found"
        exit 1
    }
    
    echo "Installing Flatcar Linux..."
    sudo flatcar-install -d /dev/sda -i "${FLATCAR_IGN}"
}

# Main execution
echo "Setting up Flatcar Linux Kubernetes controller node: ${HOSTNAME}"
generate_flatcar_yaml
convert_to_ign
install_flatcar

echo "Setup complete!"