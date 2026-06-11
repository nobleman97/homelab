# k3s-upgrade

Upgrades k3s across the cluster in the correct order: control plane first, then workers one at a time to maintain workload availability. Nodes already on the target version are skipped.

## Usage

```bash
cd ansible
source .venv/bin/activate

ansible-playbook playbooks/upgrade-k3s.yml \
  -e k3s_version=v1.35.4+k3s1 \
  -e k3s_token=<token> \
  -u debian \
  --private-key ~/.ssh/lab
```

Get the token from the control plane:

```bash
ssh debian@192.168.100.25 "sudo cat /var/lib/rancher/k3s/server/node-token"
```

To upgrade workers only:

```bash
ansible-playbook playbooks/upgrade-k3s.yml \
  -e k3s_version=v1.35.4+k3s1 \
  -e k3s_token=<token> \
  --limit k8s_workers
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `k3s_version` | — | **Required.** Target version, e.g. `v1.35.4+k3s1` |
| `k3s_token` | — | **Required.** Node join token from the control plane |
| `k3s_server_ip` | `192.168.100.25` | Control plane IP (used by agent installer) |
| `drain_timeout` | `120s` | How long to wait for pods to evict before failing |
