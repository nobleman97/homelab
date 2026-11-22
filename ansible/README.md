# Ansible

Playbooks and inventory for the k3s nodes provisioned by Terraform: OS dependencies, joining workers, and rolling k3s upgrades.

## Requirements

```bash
./setup-venv.sh
source .venv/bin/activate
```

> **Every session**: activate the venv before running any Ansible or
> `ansible-inventory` command:
> ```bash
> source .venv/bin/activate
> ```

`ansible.cfg` sets the remote user (`debian`), the SSH key (`~/.ssh/lab`), `roles_path`, and the **static inventory as the default**, so `-i` is only needed for the dynamic inventory.

## Directory Structure

```
ansible/
├── ansible.cfg                  # user, SSH key, default inventory, roles_path
├── setup-venv.sh                # creates .venv with ansible + community.proxmox
├── inventory/
│   ├── static.ini               # Hardcoded IPs — no external dependencies (default)
│   └── dynamic/
│       └── proxmox.yml          # Queries the Proxmox API at runtime
├── playbooks/
│   ├── install-deps.yml         # OS packages k3s/Longhorn need (open-iscsi, iscsid, ...)
│   ├── join-k3s-worker.yml      # install-deps + join k8s_workers to the cluster
│   └── upgrade-k3s.yml          # control plane first, then workers one at a time
└── roles/
    ├── k3s-worker/              # installs the k3s agent and joins k3s-server
    └── k3s-upgrade/             # upgrades k3s; drains/uncordons the server (agent drain is commented out)
```

---

## Inventory

### Static (`inventory/static.ini`)

Hardcoded hostnames and IPs. Each host also sets `k3s_node_name`, the node's name inside Kubernetes.

| Host | IP | k3s node | Groups |
|---|---|---|---|
| k8s-control-plane-01 | 192.168.100.25 | k3s-server | `k8s_nodes`, `k8s_control_plane` |
| k8s-worker-node-01 | 192.168.100.26 | k3s-worker-1 | `k8s_nodes`, `k8s_workers` |
| k8s-worker-node-02 | 192.168.100.27 | k3s-worker-2 | `k8s_nodes`, `k8s_workers` |
| k8s-worker-node-03 | 192.168.100.28 | k3s-worker-3 | `k8s_nodes`, `k8s_workers` |

Update this file manually when adding or changing nodes.

**Test connectivity:**
```bash
ansible k8s_nodes -m ping
```

---

### Dynamic (`inventory/dynamic/proxmox.yml`)

Queries the Proxmox API and builds groups from VM tags (`keyed_groups` on `proxmox_tags_parsed`), so nodes added via Terraform are discovered without editing a file. Only running VMs are included, and `ansible_host` comes from the VM's cloud-init `ipconfig0`.

The tags are set per VM in `terraform/proxmox/terraform.tfvars` and map to the same group names as the static inventory: every VM is tagged `k8s_nodes`, plus `k8s_control_plane` or `k8s_workers`.

**Authentication:** the plugin uses the same Proxmox API token as Terraform. Export the secret before any dynamic-inventory command:

```bash
export PROXMOX_TOKEN_SECRET="$TF_VAR_proxmox_api_token_secret"
```

**Test and explore the inventory:**
```bash
ansible-inventory -i inventory/dynamic/proxmox.yml --graph
ansible-inventory -i inventory/dynamic/proxmox.yml --host k8s-control-plane-01
ansible -i inventory/dynamic/proxmox.yml k8s_nodes -m ping
```

---

## Running Playbooks

Both inventories expose the same groups (`k8s_nodes`, `k8s_control_plane`, `k8s_workers`), so every playbook works with either.

```bash
# OS dependencies on all nodes (safe to re-run)
ansible-playbook playbooks/install-deps.yml
ansible-playbook playbooks/install-deps.yml --check          # dry run

# Join worker nodes (needs the cluster join token)
ansible-playbook playbooks/join-k3s-worker.yml -e k3s_token=<token>
ansible-playbook playbooks/join-k3s-worker.yml -e k3s_token=<token> --limit k8s-worker-node-03

# Rolling k3s upgrade: control plane first, then workers serial: 1
ansible-playbook playbooks/upgrade-k3s.yml -e k3s_version=v1.36.5+k3s1 -e k3s_token=<token>
ansible-playbook playbooks/upgrade-k3s.yml -e k3s_version=v1.36.5+k3s1 -e k3s_token=<token> --limit k8s_workers

# Same thing against the dynamic inventory
ansible-playbook -i inventory/dynamic/proxmox.yml playbooks/install-deps.yml
```

The join token is on the server at `/var/lib/rancher/k3s/server/token`. Pass it with `-e` or Ansible Vault; never commit it.

---

## Adding a New Node

1. Add an entry to the `vms` map in `terraform/proxmox/terraform.tfvars` with the `k8s_nodes` and `k8s_workers` tags
2. `terraform apply -target='module.vms["<key>"]'` from `terraform/proxmox/`
3. Add the host to `inventory/static.ini` (with `k3s_node_name`). The dynamic inventory picks it up automatically
4. `ansible-playbook playbooks/join-k3s-worker.yml -e k3s_token=<token> --limit <new-host>`
