#!/usr/bin/env bash
set -euo pipefail

# --- Settings ---
K8S_VERSION="${K8S_VERSION:-1.34}"             # default minor version
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"          # Flannel default
USER_NAME="${SUDO_USER:-${USER:-root}}"        # user to configure kubectl for
# ----------------

log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (use sudo)."

# 1) Update + basics
log "Updating system and installing prerequisites…"
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg lsb-release \
  gnupg software-properties-common socat conntrack ipset ebtables ethtool

# 2) Disable swap
log "Disabling swap…"
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# 3) Kernel modules & sysctl
log "Configuring kernel modules and sysctl…"
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 4) Install containerd
log "Installing containerd…"
apt-get install -y containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml

# Use systemd cgroups
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -ri 's#sandbox_image = ".*"#sandbox_image = "registry.k8s.io/pause:3.9"#' /etc/containerd/config.toml

systemctl enable --now containerd

# 5) Kubernetes repo (v1.34)
log "Adding Kubernetes apt repo v${K8S_VERSION}…"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

apt-get update -y

# 6) Install kubeadm/kubelet/kubectl
log "Installing kubeadm, kubelet, kubectl…"
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# 7) kubeadm init
if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  log "Initializing control-plane with pod CIDR ${POD_CIDR}…"
  kubeadm init --pod-network-cidr="${POD_CIDR}" --cri-socket unix:///run/containerd/containerd.sock
else
  warn "Kubernetes already initialized; skipping kubeadm init."
fi

# 8) Configure kubectl for the user
USER_HOME="$(eval echo ~${USER_NAME})"
mkdir -p "${USER_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
chown -R "${USER_NAME}":"${USER_NAME}" "${USER_HOME}/.kube"

# 9) Flannel CNI
log "Installing Flannel CNI…"
sudo -u "${USER_NAME}" kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/v0.25.5/Documentation/kube-flannel.yml

# 10) Allow scheduling on control-plane
sudo -u "${USER_NAME}" kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# 11) Add alias k=kubectl to Zsh
ZSHRC="${USER_HOME}/.zshrc"
if ! grep -q "alias k=kubectl" "$ZSHRC" 2>/dev/null; then
  log "Adding alias 'k=kubectl' into ${ZSHRC}…"
  echo "alias k=kubectl" >> "$ZSHRC"
  chown "${USER_NAME}":"${USER_NAME}" "$ZSHRC"
fi

# 12) Show cluster info
log "All done! Cluster info:"
sudo -u "${USER_NAME}" kubectl version --short || true
sudo -u "${USER_NAME}" kubectl get nodes -o wide || true
echo "Tip: Open new Zsh or run 'source ~/.zshrc' to use alias k=kubectl."
