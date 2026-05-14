# Ansible

Playbooks and inventory for configuring k8s VMs provisioned by Terraform.

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

## Directory Structure

```
ansible/
├── ansible.cfg                  # SSH key, remote user, inventory plugin config
├── inventory/
│   ├── static.ini               # Hardcoded IPs — no external dependencies
│   └── dynamic/
│       └── proxmox.yml          # Queries Proxmox API at runtime
└── playbooks/
    └── install-blkid.yml
```

---

## Inventory

### Static (`inventory/static.ini`)

Hardcoded hostnames and IPs. Use this when you don't want any API dependency
or are working offline.

**Groups defined:**

| Group               | Members                    |
|---------------------|----------------------------|
| `k8s_nodes`         | control plane + workers    |
| `k8s_control_plane` | k8s-control-plane-01       |
| `k8s_workers`       | k8s-worker-node-01         |

Update this file manually when adding or changing nodes.

**Test connectivity:**
```bash
ansible -i inventory/static.ini k8s_nodes -m ping
```

---

### Dynamic (`inventory/dynamic/proxmox.yml`)

Queries the Proxmox API and builds groups from VM tags. VMs are automatically
discovered — no manual updates needed when nodes are added via Terraform.

**How groups are built:**

Tags set in `proxmox/terraform.tfvars` become Ansible groups automatically.
The current tag layout maps to the same group names as the static inventory:

| VM                   | Tags (Proxmox)                              | Ansible Groups                            |
|----------------------|---------------------------------------------|-------------------------------------------|
| k8s-control-plane-01 | `k8s_nodes`, `k8s_control_plane`            | `@k8s_nodes`, `@k8s_control_plane`        |
| k8s-worker-node-01   | `k8s_nodes`, `k8s_workers`                  | `@k8s_nodes`, `@k8s_workers`              |

The plugin also auto-creates groups for all running VMs (`proxmox_all_running`),
by node (`proxmox_proxmox_qemu`), and by type (`proxmox_all_lxc` / `proxmox_all_qemu`).

**Authentication:**

The plugin reuses the same Proxmox API token used by Terraform. Export the
secret before running any dynamic inventory commands:

```bash
export PROXMOX_TOKEN_SECRET="$TF_VAR_proxmox_api_token_secret"
```

**Test and explore the inventory:**
```bash
# Show all groups and their members
PROXMOX_TOKEN_SECRET="$TF_VAR_proxmox_api_token_secret" \
  ansible-inventory -i inventory/dynamic/proxmox.yml --graph

# Show all vars for a specific host
PROXMOX_TOKEN_SECRET="$TF_VAR_proxmox_api_token_secret" \
  ansible-inventory -i inventory/dynamic/proxmox.yml --host k8s-control-plane-01

# Ping the k8s nodes group
PROXMOX_TOKEN_SECRET="$TF_VAR_proxmox_api_token_secret" \
  ansible -i inventory/dynamic/proxmox.yml k8s_nodes -m ping
```

---

## Running Playbooks

Both inventories expose the same group names (`k8s_nodes`, `k8s_control_plane`,
`k8s_workers`), so playbooks work with either — just swap the `-i` flag.

```bash
# Static inventory
ansible-playbook -i inventory/static.ini playbooks/install-blkid.yml

# Dynamic inventory
PROXMOX_TOKEN_SECRET="$TF_VAR_proxmox_api_token_secret" \
  ansible-playbook -i inventory/dynamic/proxmox.yml playbooks/install-blkid.yml

# Dry run (check mode)
ansible-playbook -i inventory/static.ini playbooks/install-blkid.yml --check

# Limit to a single host
ansible-playbook -i inventory/static.ini playbooks/install-blkid.yml \
  --limit k8s-control-plane-01

# Verbose output
ansible-playbook -i inventory/static.ini playbooks/install-blkid.yml -v
```

---

## Adding a New Node

1. Add an entry to `proxmox/terraform.tfvars` with the appropriate tags
2. Run `terraform apply` from the `proxmox/` directory
3. The dynamic inventory picks it up automatically on the next run
4. To add it to the static inventory too, append a line to `inventory/static.ini`
