# Removing a VM

Use this runbook whenever decommissioning a VM that was provisioned by Terraform and monitored by the VictoriaMetrics stack. Skipping the monitoring cleanup step will cause `TooManyScrapeErrors` alerts to fire for 15+ minutes after the VM is gone.

---

## 1. Remove monitoring scrapes

Edit `k8s/manifest/monitoring/vm-static-scrapes.yaml` and delete the IP entries for the VM being removed from any `VMStaticScrape` targets (`node-exporter`, `nginx-exporter`, `postgres-exporter`, etc.).

If the VM was the only target in a scrape block, delete the entire `VMStaticScrape` object.

Apply the change:

```bash
kubectl apply -f k8s/manifest/monitoring/vm-static-scrapes.yaml
```

Verify the target is gone from vmagent:

```bash
kubectl port-forward -n monitoring svc/vmagent-monitoring-victoria-metrics-k8s-stack 8429:8429
# Open http://localhost:8429/targets — the VM's entries should no longer appear
```

---

## 2. Remove the VM from Terraform

Open `terraform/proxmox/main.tf` and delete the `proxmox_vm_qemu` resource block for the VM.

If the VM has a matching entry in `variables.tf` or `terraform.tfvars`, remove those too.

Preview and apply:

```bash
cd terraform/proxmox
terraform plan    # confirm only the target VM shows as destroyed
terraform apply
```

---

## 3. Remove from Ansible inventory

Remove the host entry from `ansible/inventory/static.ini` and any group it belongs to.

---

## 4. Verify

```bash
# Confirm the VM no longer appears in state
terraform state list

# Confirm no stale scrape targets remain
kubectl get vmstaticscrape -n monitoring -o yaml | grep <vm-ip>
```

The `TooManyScrapeErrors` alert will self-resolve within 15 minutes once vmagent stops seeing errors from the removed targets.
