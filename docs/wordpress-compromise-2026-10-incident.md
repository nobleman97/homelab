# Incident: `cognitaid.com` WordPress compromise — rogue admins, SEO spam, webshell

**Date detected:** 2026-10-05
**Date contained:** 2026-10-05
**Site:** `cognitaid.com` — WordPress 7.0 (`wordpress:7.0-php8.2-apache`) at compromise; patched to 7.1.2 on 2026-10-05 in namespace `wordpress` on the homelab k3s cluster
**Components:** `wordpress` Deployment, `mariadb-0` (DB `cognitaid_db`, table prefix `wpz7_`), `redis`, `cloudflared` tunnel. Manifests in `k8s/manifest/wordpress/`.
**Impact:** Attacker held WordPress administrator access from at least **2026-07-26** (and likely posting as the real admin from **2026-07-06**) until 2026-10-05 — about three months. Over that time they published 1,826 spam posts, planted hidden SEO links on the homepage, and on 2026-10-04 got PHP code execution as `www-data`. Search engines crawled and indexed the spam (Bingbot was served a casino post). The site degraded (PHP 500s/408s) from ~2026-10-04 21:44.
**Data loss:** None. Legitimate content is intact.
**Data exposure:** Likely. See [Exposure / data at risk](#exposure--data-at-risk). One credential with external blast radius, the **Brevo API key, has not been rotated yet**.
**Status:** Contained and cleaned. **The root cause is still under investigation.** Credential rotation and network isolation are outstanding.

---

## Summary

The site was fully compromised at the WordPress application layer. The attacker:

1. **Posted SEO spam as the real admin** (user 1, `nobleman`). There were 1,826 posts on casino, pharma/steroid and counterfeit-goods topics, starting 2026-07-06. 1,438 of them were published on 2026-09-01 alone.
2. **Created seven rogue administrator accounts** (`w2s_*@wp2shell.local`, `wp2_*@wp2shell.invalid`) between 2026-07-26 and 2026-10-04. Every creation left the same exploit fingerprint in `wp_posts`.
3. **Kept persistent API access** through an application password (`auto-job-89164c`) on user 1, created 2026-08-07 and last used 2026-10-03.
4. **Planted hidden backlinks** in the Home page (ID 64).
5. **Uploaded command-exec shells** disguised as media. They were renamed to `.jpg`, so they were probably never executable.
6. **Installed a working webshell** on 2026-10-04 04:51:57 by replacing the active theme's `functions.php` with an obfuscated file manager.

WordPress core, the server configuration and cron were clean. The persistence was all in the database, `wp-content`, and credentials.

The response removed every known foothold: users, app password, sessions, webshells, spam, hidden links and comments. It also updated all plugins and added Apache hardening that blocks `xmlrpc.php` and PHP execution under `uploads/`. Evidence was preserved before cleanup.

The attacker had admin plus code execution, so the working assumption is that **everything readable by WordPress was exposed**. That includes the Brevo API key, the DB credentials, user hashes and visitor form submissions. With no NetworkPolicies in place, the pod could also reach the rest of the cluster and the LAN.

---

## Timeline

All times UTC.

| Time | Event |
|---|---|
| ~2026-06 | Site migrated to the homelab from a cPanel host (stray nested `wp-content/wp-content/` copy dated Jun 12 is a migration leftover, benign) |
| **2026-07-06** | **First spam post** (authored as user 1 `nobleman`). 79 spam posts in July. |
| 2026-07-26 | First rogue admin `w2s_77fa376b0909@wp2shell.local` created |
| 2026-07-27 | `wp-content/temp-write-test-*` written (writability probe) |
| 2026-08-06 | Revision of page 64 containing hidden `казино онлайн` → `gaemt.ru` link |
| 2026-08-07 | Application password `auto-job-89164c` created on user 1 |
| 2026-08-17 | Page 64 modified: hidden off-screen `online pokies` → `theboxrentalcompany.com.au` link |
| 2026-08 | ~300 spam posts |
| **2026-09-01** | **1,438 spam posts in one day** |
| 2026-09-01 22:02 | Rogue admin `w2s_df9a5a762f35` created; shells `w2sxc32532.{php,php5,php7,pht,phtml}_.jpg` uploaded to `uploads/2026/09` |
| 2026-09-02 09:27 | Rogue admin `w2s_63d4d8e94b5a` created; shells `w2sxa5c36f.{php,phtml}_.jpg` uploaded |
| 2026-09-03 | Rogue admin `w2s_8cc7b7ce9f92` created |
| 2026-09-04 | Rogue admins `w2s_01a1b7b4fabf`, `w2s_d7f89279429a` created; last spam post |
| 2026-10-03 | App password `auto-job-89164c` last used, from `158.46.218.47` |
| 2026-10-04 04:50 | Rogue admin `wp2_df53f5@wp2shell.invalid` created |
| **2026-10-04 04:51:57** | **`themes/twentytwentyfive/functions.php` replaced with webshell** |
| 2026-10-04 04:52:00 | Webshell accessed from `2a11:6100:0:1f58::` (same source as `wp2_df53f5`'s login) |
| 2026-10-04 06:51 | `uploads/2026/10` touched |
| 2026-10-04 20:41–22:18 | Window of the access-log export: xmlrpc brute force, secrets scan, `/wp-json/batch/v1` 207, spam served to Bingbot |
| 2026-10-04 ~21:44 | Site degrades — PHP 500s / 408s |
| **2026-10-05** | **Owner notices the compromise** |
| 2026-10-05 ~10:35–10:40 | Owner deletes rogue users (plus users 2 `victor_akeni` and 9) with their content, which removes the uploaded shells; trashes 53 spam posts; sets posts 1, 30, 31 to draft |
| 2026-10-05 ~10:45 | Owner scales deployment 0 → 1 (pod restart). This interrupted the first evidence copy. |
| 2026-10-05 | Owner revokes `auto-job-89164c`, changes `nobleman` password |
| 2026-10-05 11:04–11:09 | Evidence captured: DB dump, `wp-content` tarball, log export, `SHA256SUMS` |
| 2026-10-05 | Webshell and temp-write-test removed; all spam, hidden links and spam comments deleted; 13 plugins updated |
| 2026-10-05 ~11:36 | Apache hardening ConfigMap deployed; xmlrpc and uploads-PHP blocks verified 403 |

---

## Detection

There was no alerting. The owner noticed the compromise on 2026-10-05 and exported the access log for 2026-10-04 20:41–22:18 (`docs/Logs-2026-10-05 11_07_01.txt`, also copied into the evidence directory). That window showed:

| Signal | Detail | Assessment |
|---|---|---|
| Spam served | Spam slugs returning 200, e.g. a casino post to `bingbot` | Spam was live and being indexed |
| `xmlrpc.php` brute force | 173 POSTs, 149 from `2406:99c0:7:e115:dcc1:4f8a:8953:d590`, fake Jetpack user agents | Responses all a uniform **446 B**, which means failures. Not the observed access path in this window. |
| Secrets scan | `35.205.88.64` requested `.env`, `.aws/credentials`, `.s3cfg`, `.git`, `.claude/settings.json` | Nothing served. Generic scanner. |
| REST batch | `POST /wp-json/batch/v1` → **207** from `79.127.138.69` | Successful multi-request batch; relevant to root cause |
| Degradation | PHP 500s and 408s from ~21:44 | Site unhealthy at the time of noticing |

The owner's home IP `102.88.169.20` appears in the log for wp-cron traffic. It is benign.

**The compromise ran for about three months without detection.** Nothing monitored new admin users, new PHP files under `wp-content`, or post volume. A 1,438-post day went unnoticed.

---

## Scope & findings

The investigation used three read-only agents in parallel, covering the database, the filesystem and logs/config.

### Spam content

- **1,826 spam posts**, IDs 580–4330, all authored as **user 1 `nobleman`** (the real admin), not as the rogue accounts.
- Created 2026-07-06 → 2026-09-04: 79 in July, ~300 in August, **1,438 on 2026-09-01**. Some had `post_date` backdated to 2025-05.
- Topics: casino/gambling (French, Portuguese, Lithuanian, Polish), steroids/pharma, counterfeit clothing.
- 1,814 contained external casino links. **None contained scripts**, so this was SEO spam, not visitor-targeting malware.
- **27 pending spam comments**, never approved.

### Hidden SEO links (Home page, ID 64)

| Anchor | Target | Introduced |
|---|---|---|
| `online pokies` (off-screen `div`) | `theboxrentalcompany.com.au` | modified 2026-08-17 |
| `казино онлайн` | `gaemt.ru` | revision dated 2026-08-06 |

### Rogue accounts and credentials

| Account | Email domain | Created | Notes |
|---|---|---|---|
| `w2s_77fa376b0909` | `@wp2shell.local` | 2026-07-26 | |
| `w2s_df9a5a762f35` | `@wp2shell.local` | 2026-09-01 22:02 | Same minute as first shell upload |
| `w2s_63d4d8e94b5a` | `@wp2shell.local` | 2026-09-02 09:27 | Same minute as second shell upload |
| `w2s_8cc7b7ce9f92` | `@wp2shell.local` | 2026-09-03 | |
| `w2s_01a1b7b4fabf` | `@wp2shell.local` | 2026-09-04 | |
| `w2s_d7f89279429a` | `@wp2shell.local` | 2026-09-04 | |
| `wp2_df53f5` | `@wp2shell.invalid` | 2026-10-04 04:50 | Last login 2026-10-04 from `2a11:6100:0:1f58::` |

All were **administrators**. `users_can_register` was `0`, so these were not self-registrations.

On the real admin, user 1 `nobleman`:
- **Application password `auto-job-89164c`**, created 2026-08-07 and last used 2026-10-03 from `158.46.218.47`. The name mimics an automation job. It gave REST API access that survives password changes until revoked.
- **Attacker login sessions** from `188.166.68.82` and `134.199.218.54`.

### Exploit fingerprint

Every admin-creation time has the same trio of rows in `wpz7_posts`:

- a `request` post (WordPress's user/privacy-request type), with an anomalous `post_status`, which suggests the payload is parsed through it
- a `customize_changeset` post
- an `oembed_cache` post

That gives **seven sets, one per rogue admin**. The shells are named `w2s*` and the accounts use `@wp2shell.*`, which points to an automated "wp2shell" kit. The rows were **kept as evidence** for the root-cause work.

### Code execution

**1. Theme webshell — confirmed execution.**

| | |
|---|---|
| File | `wp-content/themes/twentytwentyfive/functions.php` (active theme) |
| Replaced | 2026-10-04 04:51:57 |
| First access | 2026-10-04 04:52:00 from `2a11:6100:0:1f58::` |
| Behaviour | Obfuscated file manager disguised as a "Theme compatibility handler", function names `strrev`'d, gated by a GET key |
| SHA-256 | `1c1c18cdd650e0090de02929e740351413d08d75e96cd49e4709ce2e122dd61f` |

`functions.php` loads on every request, so this was full PHP execution as `www-data` from 04:51 on 2026-10-04 until removal on 2026-10-05.

The workflow is clear from the timing: rogue admin created at 04:50, theme file replaced at 04:51:57, shell used 3 s later from the same IP. The attacker used admin rights to write the shell, probably through the theme/plugin file editor or an upload.

**2. Uploaded command-exec shells — probably not executable.**

Seven files went to `uploads/2026/09/` as media attachments:
- `w2sxc32532.{php,php5,php7,pht,phtml}_.jpg` (2026-09-01 22:02)
- `w2sxa5c36f.{php,phtml}_.jpg` (2026-09-02 09:27)

Each was a token-gated `shell_exec` of a base64 GET parameter. WordPress's upload sanitisation renamed them to `*_.jpg`, so Apache would not have handed them to PHP. Uploading five extension variants looks like the kit probing for one that would execute. They were removed when the owner deleted the rogue users with their content.

### Other filesystem observations

| Item | Assessment |
|---|---|
| `wp-content/temp-write-test-*` (2026-07-27) | Attacker writability probe. **Removed.** |
| `uploads/2026/10` touched 2026-10-04 06:51 | Post-webshell activity; contents preserved in the evidence tarball |
| `wp-content/wp-content/` (Jun 12) | Nested copy from the cPanel migration. Benign but should be removed. |

### Verified clean

- WordPress core checksums (`wp core verify-checksums`). Core is ephemeral per pod anyway.
- No `mu-plugins`, no drop-ins (`db.php`, `object-cache.php`, `advanced-cache.php`, etc.)
- Root `.htaccess` is stock; no `auto_prepend_file`
- No malicious WP-cron events
- `siteurl` / `home` unchanged

### Plugin inventory at time of compromise

All plugins were outdated:

| Plugin | Version at compromise | Updated to |
|---|---|---|
| elementor | 4.1.2 | 4.3.3 |
| extendify | 3.0.6 | 3.2.2 |
| formidable | 6.31 | 6.35 |
| image-optimization | 1.7.5 | 1.7.7 |
| litespeed-cache | 7.8.1 | 7.9.1 |
| loginizer | 2.0.8 | 2.1.1 |
| popularfx-templates | 1.2.4 | 1.3.1 |
| responsive-menu | 4.7.2 | 4.7.4 |
| header-footer-elementor | 2.8.8 | 2.9.5 |
| wp-letsencrypt-ssl | 7.8.6.3 | 7.8.8.0 |
| wp-mail-smtp | 4.8.0 | 4.10.0 |
| nc-extendify-lc | 1.0.0 | — (no update) |
| akismet *(inactive)* | 5.7 | 5.7.2 |
| woocommerce *(inactive)* | 10.8.1 | 11.1.2 |

---

## Exposure / data at risk

The attacker had **WordPress admin** from at least 2026-07-26 and **arbitrary PHP execution as `www-data`** from 2026-10-04 04:51. Anything WordPress can read, through its database or environment, is treated as exposed. No exfiltration was directly observed, and none was ruled out.

| Asset | Exposure | Risk | Status |
|---|---|---|---|
| **Brevo (Sendinblue) API key** in WP Mail SMTP settings | Readable by admin and by the webshell | **High.** Can send mail as `hello@cognitaid.com` (phishing from a trusted domain) and may read contacts or send logs. | **NOT ROTATED** |
| MariaDB `wpuser` password (pod env var) | Readable via webshell (`getenv` / `wp-config.php`) | Medium. Scoped to `cognitaid_db` only; reachable only in-cluster. | Owner deferred rotation |
| User password hashes | Admin + DB access | Medium. Crackable offline. | `nobleman` password changed; other users not reset |
| **117 Formidable form submissions** | Admin UI + DB | Medium. Visitor PII. | Notification decision pending |
| User email addresses | Admin + DB | Low–medium | — |
| Elementor connect key, Formidable connect token, Softaculous licence | DB options | Low | Not rotated |
| WordPress auth salts | `wp-config.php` | Low. Likely regenerated on pod restart, since core and config are ephemeral. | Pod restarted 10:45 |
| K8s ServiceAccount token | Mounted in pod (default SA) | Low. Discovery-only permissions. | — |

### Network reach from the compromised pod

**There are no NetworkPolicies in any namespace.** From the webshell, `www-data` could reach:

- every cluster Service, including **unauthenticated** ones: the Longhorn UI (volume detach/delete), VictoriaLogs and VictoriaMetrics, and the WordPress **Redis, which has no auth**
- the home LAN, `192.168.100.x` (Proxmox hosts, Pi-hole, nodes)
- the internet, with unrestricted egress

**No evidence of lateral movement was found, but this was not investigated in depth.** The webshell was live for ~30 h (2026-10-04 04:51 → 2026-10-05 removal). VictoriaLogs has a known ingest gap ending 2026-10-03 18:40 (see `cnpg-wal-disk-full-incident.md`), so the logging that covers this window is limited.

---

## Root cause / initial access

> **Status: Identified (high confidence) for the rogue-admin intrusions. The July 6–16 spam remains unexplained.**

### Primary vector: WordPress core pre-auth RCE ("wp2shell")

**CVE-2026-63030**: a route-confusion desync in the REST batch endpoint (`/batch/v1`), chained with a SQL injection in `author_exclude` (CVE-2026-60137). It needs no authentication. It affects core **6.9.0–7.0.1**, was fixed in **7.0.2** and was publicly disclosed **2026-07-17**.

The site was still running core **7.0**, because the deployment used the floating tag `wordpress:7.0-php8.2-apache` with `imagePullPolicy: IfNotPresent`. The node kept serving an old cached image, and core lives in the image, so in-app core updates could never persist. **Plugin updates did not fix this. Bumping the image did (see Response actions).**

Advisories:
- [Wordfence vulnerability entry](https://www.wordfence.com/threat-intel/vulnerabilities/wordpress-core/wordpress-core-69-701-remote-code-execution-via-rest-api-batch-request-route-confusion)
- [Wordfence PSA](https://www.wordfence.com/blog/2026/07/psa-wordpress-core-patched-unauthenticated-remote-code-execution-vulnerability-chain/)
- [FullHunt write-up](https://fullhunt.io/blog/2026/07/17/wp2shell-wordpress-core-pre-auth-rce-cve-2026-63030.html)

### Evidence chain (2026-10-04, confirmed from VictoriaLogs)

VictoriaLogs retention is 7 days, so only the Oct 4 run is in the logs.

| Time (UTC) | Event |
|---|---|
| 04:44:29–04:50:58 | About 15 unauthenticated `POST /?rest_route=/batch/v1&_f06=…` from `2a11:6100:0:1f58::`. Each returned 207. The referer was spoofed to `/wp-admin/edit.php` and the UA rotated. PHP warnings `Undefined array key 2/3` at `class-wp-rest-server.php:1836/1848` show the batch desync. DB errors show a UNION injection into `post_author NOT IN (…)` through `serve_batch_request_v1 → WP_REST_Posts_Controller->get_items`. |
| 04:46:32 | `GET /?rest_route=/wp/v2/posts&per_page=1&_fields=link` fetched the newest post URL, which was then used for the oEmbed. |
| 04:47:28 | Table-prefix probe (a `wp_posts` doesn't-exist error). |
| 04:50:06–07 | Forged rows set off a hook chain that ends in admin creation (see below). `wp2_df53f5` was created. |
| 04:51:20 | Read of `wpz7_options.active_plugins`. |
| 04:51:21–25 | About 15 `POST /xmlrpc.php` (verifying the new credentials). |
| 04:51:26 | `POST /wp-login.php` → 302 (login succeeded). |
| 04:51:39 | `upload-plugin` "developer-widget-pack-sple". **It failed** because the plugin dirs are root-owned. |
| 04:51:47–53 | Theme-editor writes to `extendable` and `popularfx`. **They failed** (root-owned). |
| 04:51:57 | Theme-editor write to `twentytwentyfive/functions.php` (www-data-owned) **succeeded**. That is the webshell. |
| 04:52:00 | The webshell was accessed. |
| 06:51:41 | `upgrader_scheduled_cleanup` cron removed the uploaded plugin zip. This explains the `uploads/2026/10` mtime. |

**What the fingerprint trio is:** the injected rows form a privilege-escalation chain.
1. The forged post contains `[embed]https://cognitaid.com/<newest-post>/#<id>[/embed]`. `WP_Embed->shortcode` writes an **`oembed_cache`** row.
2. Saving that row runs `wp_check_post_hierarchy_for_loops`, which calls `wp_update_post` on a forged **`customize_changeset`** (status `future`). This publishes it.
3. The changeset saves a `nav_menu_item` setting carrying `user_id: 1`, so the request now acts as the admin.
4. The menu-item save transitions a forged **`request`** post to status `parse`. That fires `parse_request`, which re-enters `rest_api_loaded` as user 1 and creates the attacker's admin user.

Each changeset contains a `nav_menu_item` titled "proof". From 07-26 to 09-04 its URL is `https://github.com/dinosn/wp2shell-lab` (a public exploit lab). On 10-04 it is `https://nukedx.com`.

**Inferred:** the 07-26 to 09-04 runs (w2s_* admins and uploads shells) used the same vector. The trio rows are identical, but those logs have expired.

Single `/batch/v1` probes from other IPs on 09-30, 10-01, 10-02, 10-03 and 10-04 show the site was being mass-scanned for this CVE.

### Secondary, unexplained: spam from 2026-07-06 to 07-16

Steroid spam (posts 582–726, about 10 a day) was posted as user 1 **before** the CVE was public. It has no trio rows, no new users, and normal revisions. That fits **a valid admin login** (reused, leaked or brute-forced password, or a stolen session) rather than the exploit. No log evidence survives. Loginizer only holds failures from Oct 4 onward. No backdoor was carried over from the cPanel host. The 2026-08-07 app password "auto-job-89164c" also has no trio, so it was created from an already-admin session.

### Why the damage was limited

Plugin and most theme directories were root-owned (an accident of the June migration and today's WP-CLI updates). That blocked the attacker's plugin upload and most theme edits. Only the www-data-owned `twentytwentyfive` theme could be written. **Keep plugin and theme code non-writable by www-data.**

---

## Response actions

All on 2026-10-05.

### Containment (owner)

| Time | Action |
|---|---|
| ~10:35–10:40 | Deleted all 7 rogue admins via WP admin **with their content**, which deleted the 7 uploaded `w2s*_.jpg` shells as their attachments. Also deleted users 2 (`victor_akeni`) and 9. |
| ~10:35–10:40 | Trashed 53 spam posts; set posts 1, 30, 31 to draft |
| ~10:45 | Scaled `wordpress` deployment 0 → 1 (pod restart, regenerating ephemeral core and `wp-config.php`) |
| — | Revoked application password `auto-job-89164c` |
| — | Changed `nobleman` password |

> Note: rogue users were deleted **before** evidence was captured, so their `wp_users` / `wp_usermeta` rows are not in the DB dump. Their details are recorded in this report. The uploaded shells went with them; the tarball does not contain them.

### Eradication (Claude, via `kubectl exec` / WP-CLI)

- Removed webshell `themes/twentytwentyfive/functions.php`, after the evidence tarball was taken.
- Removed `wp-content/temp-write-test-*`.
- Deleted **all 1,826 spam posts** and their revisions. Verified 0 remaining.
- Removed both hidden links from page 64. Deleted revisions **749** and **975**, which also contained them, and oEmbed cache post **4332**. Verified the live homepage renders clean.
- Deleted all **27 spam comments**.

### Hardening

**Plugins:** updated all 13 with available updates (versions in the inventory table above).

**Apache:** ConfigMap `wordpress-apache-hardening` (`k8s/manifest/wordpress/apache-hardening.yaml`) is mounted into `/etc/apache2/conf-enabled/` and mirrored in `wordpress.yaml`:

| Rule | Mechanism | Verified |
|---|---|---|
| Block `xmlrpc.php` | `<Files "xmlrpc.php"> Require all denied` | 403 |
| No PHP execution in `uploads/` | `php_admin_flag engine off` + `FilesMatch` deny for `php\d*`, `phtml`, `pht`, `phar`, `phps` | 403 |

The rules use `php_admin_flag` at the server-config level, so a `.htaccess` dropped into `uploads/` cannot re-enable PHP.

> **Drift:** the live `wordpress` Deployment does not match `wordpress.yaml`. It uses the `Recreate` strategy and has Datadog annotations that are not in the repo. Re-applying `wordpress.yaml` as-is would change those. Reconcile before the next apply.

### Deliberately kept

- **7 sets of exploit fingerprint rows** (`request`, `customize_changeset`, `oembed_cache`), needed for root-cause analysis
- **63 orphan `postmeta` rows**, left behind by deleted content

### Core patch (root-cause fix)

- An attempted dashboard core update to 7.1.2 failed (`Could not create directory … wp-content/upgrade`). It could not have persisted anyway, because core lives in the image.
- The deployment image was changed to the exact patch tag `wordpress:7.1.2-php8.2-apache` (digest `sha256:219698ab…`), live and in `wordpress.yaml`.
- Verified: `$wp_version = '7.1.2'`, `wp core verify-checksums` passes, DB already at latest version, and the site, `wp-admin`, REST, the xmlrpc block and the uploads block all still work.
- `wp-content/litespeed` and `wp-content/uploads` were chowned to `www-data`. This fixes LiteSpeed's "could not create .htaccess" warning and root-owned media from the migration. Plugin and theme dirs were deliberately left root-owned.

### Final cleanup and lockdown

- Deleted the 20 remaining exploit fingerprint rows (`request` / `customize_changeset` / `oembed_cache`) and the 63 orphaned `_menu_item_*` postmeta rows the exploit left. The originals are preserved in the evidence DB dump.
- Deleted the stale nested `wp-content/wp-content/` tree (326 MB, old plugin and theme code reachable from the web). It is preserved in `wp-content.tar.gz`.
- Added `define('DISALLOW_FILE_MODS', true);` to `WORDPRESS_CONFIG_EXTRA` (live and `wordpress.yaml`). Verified that admins no longer have `install_plugins`, `edit_themes` or `update_core`. **Plugin, theme and core updates are now done only by WP-CLI or an image change, not the dashboard.**

---

## Evidence preserved

Location: `homelab/env/wp-incident-2026-10-05/`. It is gitignored; the directory is `0700` and the evidence files are `0600`.

| File | Captured | SHA-256 (prefix) | Contents |
|---|---|---|---|
| `cognitaid_db.sql.gz` | 2026-10-05 11:04 | `13efb3a7…` | Full `cognitaid_db` dump, taken **after** rogue-user deletion, **before** spam/link cleanup |
| `wp-content.tar.gz` | 2026-10-05 11:08 | `ae7852a7…` | Full `wp-content`, including the webshell `functions.php` |
| `Logs-2026-10-05 11_07_01.txt` | 2026-10-05 | `2e3f5e79…` | Access log export, 2026-10-04 20:41–22:18 |
| `SHA256SUMS` | 2026-10-05 11:09 | — | Full hashes of the above |

The first capture attempt failed because the pod was restarted mid-copy. The files above are from the second, complete attempt. The webshell's own hash is recorded in [Code execution](#code-execution).

Treat this directory as sensitive. The DB dump contains password hashes, the Brevo key, and visitor PII. **Do not commit it or copy it off-host.**

---

## Remaining actions

| # | Priority | Action | Owner | Status |
|---|---|---|---|---|
| 1 | **P0** | **Rotate the Brevo API key**; update WP Mail SMTP; review Brevo send logs and contacts for activity since 2026-07 | David | ☐ Open |
| 2 | **P0** | **Confirm the initial access vector** (see [Root cause](#root-cause--initial-access)). Until it is known, the hole may still be open even on updated plugins. | Investigation agent / David | ☐ In progress |
| 3 | P1 | **NetworkPolicy** for the `wordpress` namespace: pod egress only to `mariadb`, `redis`, cluster DNS, and the internet (deny cluster CIDRs and `192.168.100.0/24`). Default-deny ingress except from `cloudflared`. | David | ☐ Open |
| 4 | P1 | Check for lateral movement: Longhorn UI actions, Redis contents/config, unexpected connections from the WordPress pod IP (2026-10-04 04:51 → 2026-10-05) | David | ☐ Open |
| 5 | P1 | Enable 2FA for all admins (Loginizer) | David | ☐ Open |
| 6 | P1 | Monitoring alerts: new administrator user, new/changed `*.php` under `wp-content`, post-creation spikes | David | ☐ Open |
| 7 | P1 | Force password reset for all remaining users; audit remaining users and app passwords | David | ☐ Open |
| 8 | P2 | Decide whether the 117 Formidable submitters need to be notified of possible PII exposure | David | ☐ Open |
| 9 | P2 | Cloudflare WAF rules: block `xmlrpc.php` at the edge, rate-limit `wp-login.php` / `/wp-json/`, challenge known-bad ASNs | David | ☐ Open |
| 10 | P2 | Depending on root cause, disable or restrict user-request/privacy endpoints and `/wp-json/batch/v1` | David | ☐ Blocked on #2 |
| 11 | P2 | Reconcile `wordpress.yaml` with the live Deployment (`Recreate` strategy, Datadog annotations) | David | ☐ Open |
| 12 | P2 | Remove unused plugins/themes (inactive `woocommerce`, `akismet` if unused, `nc-extendify-lc`, inactive themes) and the nested `wp-content/wp-content/` | David | ☐ Open |
| 13 | P2 | Rotate Elementor connect key, Formidable connect token, Softaculous licence | David | ☐ Open |
| 14 | P3 | Rotate MariaDB `wpuser` password (deferred by owner; revisit once #3 limits who can reach MariaDB) | David | ☐ Deferred |
| 15 | P3 | Request removal of spam URLs from search indexes (Google/Bing Search Console); check for a "hacked site" flag | David | ☐ Open |
| 16 | P3 | Delete fingerprint rows and orphan postmeta once root cause is confirmed and evidence is no longer needed | David | ☐ Blocked on #2 |
| 17 | P3 | Make `wp-content/themes` and `plugins` read-only to `www-data` (or set `DISALLOW_FILE_EDIT` / `DISALLOW_FILE_MODS`) so admin access alone cannot write PHP | David | ☐ Open |

---

## Lessons learned

**1. There was no detection for a three-month compromise.** Seven admin accounts, 1,826 posts and a 1,438-post day went unnoticed. The site's own data could have caught it with cheap checks: admin user count, PHP file hashes under `wp-content`, daily post count. The homelab already runs VictoriaMetrics/Logs; WordPress was simply not wired in.

**2. Patch hygiene was the likely weak point.** Every plugin was behind, several by minor versions. A homelab-hosted production site needs automatic minor updates for plugins, or at least a weekly check.

**3. Admin = code execution in default WordPress.** The webshell went in 3 seconds after the rogue admin was created. Admin compromise and server compromise were effectively the same event. `DISALLOW_FILE_MODS` and a read-only code tree would break that link (action #17).

**4. Ephemeral core helped; persistent `wp-content` did not.** Core and `wp-config.php` were rebuilt on restart, and core checksums were clean, so no persistence in core. Everything the attacker needed lived in the database and in `wp-content` on the PVC. A pod restart alone cleans nothing.

**5. A flat network turns a web compromise into a cluster risk.** With no NetworkPolicies, a PHP shell in a public-facing pod could reach unauthenticated admin surfaces: the Longhorn UI, unauthenticated Redis, and the LAN. The public-facing namespace should be isolated first (action #3).

**6. Application passwords are quiet persistence.** `auto-job-89164c` looked like legitimate automation and survived any password change. Audit app passwords whenever an account is suspected.

**7. Order of operations during response.** Rogue users (and their uploaded shells) were deleted before evidence was captured, and a pod restart broke the first capture. Next time: **snapshot first** (DB dump + `wp-content` tarball), then contain. Use `kubectl scale --replicas=0` only after the copy completes, or block traffic at Cloudflare instead.

**8. Separate the noise from the attack.** The loud traffic in the log (xmlrpc brute force, `.env` scanner) was failing. The real access path did not show up in the log window at all. Uniform response sizes are a quick way to tell failed attempts from successful ones.

**9. Floating image tags hide unpatched core.** `wordpress:7.0-php8.2-apache` with `IfNotPresent` kept a pre-patch 7.0 image running for 11 weeks after a pre-auth RCE fix shipped. Pin exact patch tags (or digests), and track WordPress security releases. Renovate or a scheduled check would have flagged it.
