# GroundBolt Ansible

Provisions a GroundBolt host from a single bootstrap command. `bootstrap_groundbolt.sh`
runs **on the target device**: it resolves configuration into a durable
inventory, installs Docker and the NetBird client, downloads the playbook and
templates, then runs `playbook.yml` against `localhost` to bring up the
docker-compose stack. Ansible runs locally on the target — there is no control
node and no push over SSH.

The pieces:

- `bootstrap_groundbolt.sh` — the bootstrapper that runs on the target.
- `playbook.yml` — the Ansible playbook.
- `templates/` — Jinja2 templates the playbook renders onto the target.

## Configuration & secrets

The bootstrap resolves all configuration into a durable inventory at
`/etc/groundbolt/inventory.ini` (mode `0600`). Each value is resolved as:

1. **existing value in the inventory** (so a re-run reuses what you entered), then
2. **an environment variable** of the same name, then
3. **a generated value, a default, or an interactive prompt.**

On the first run it prompts for the secrets it doesn't have —
`NETBIRD_SETUP_KEY`, `GHCR_REGISTRY_USER`, `GHCR_REGISTRY_TOKEN` — and the
per-device `GATEWAY_SERIAL`. `VAULT_POSTGRES_PASSWORD` is generated once and
persisted. The
prompts read from the terminal, so they work even through `curl … | bash`.

Consequences worth knowing:

- **Re-running is safe and unattended** — everything is already in the inventory,
  so nothing prompts. Use this to re-apply the playbook after a change.
- **Adding a new secret to the repo** (a new entry in the script's
  `INVENTORY_SPECS`) makes the next run prompt for just that one, because the
  script is re-fetched each run.
- **To change a persisted value** (e.g. bump `SPARKMETER_TAG`), edit
  `/etc/groundbolt/inventory.ini` or delete that line to be re-prompted/defaulted.
- **Pre-seed to skip a prompt** by exporting the variable before running (with
  `sudo -E` so it survives the sudo).
- `FORCE_REPULL` / `RESET_DATABASE` are per-run flags read from the environment
  (default `false`); they are not persisted.
- **Postgres 14 → 18 upgrade**: the stack now runs `postgres:18`. A data volume
  initialized by an older PG14 image will not start under PG18 — the container
  crash-loops on a version mismatch. Greenfield deployments are unaffected. To
  wipe and re-initialize in place, run with `RESET_DATABASE=true` (this destroys
  all existing data); preserving the data across the major version requires a
  manual `pg_upgrade`.

`GHCR_REGISTRY_USER` / `GHCR_REGISTRY_TOKEN` are always required — they're what
`docker login` uses to pull the container images from `ghcr.io/earthspark`.
That's a separate concern from how the repo files reach the target (below), so
they're needed regardless of which method you use.

## Running it

The target must be Debian/Ubuntu (apt-based). There are two ways to get the
playbook files onto it.

### Option A — clone from GitLab (recommended)

Forward your SSH agent into the target (`ssh -A`) so its git operations
authenticate to GitLab with your key — no token or key on the box. Clone the
repo to get the script, then run it pointing `--repo` at the same URL. `sudo -E`
is required so the forwarded `SSH_AUTH_SOCK` survives the sudo:

```sh
ssh -A user@target
# on the target:
git clone git@gitlab.com:sparkmeter/earthspark/ansible.git
sudo -E bash ansible/bootstrap_groundbolt.sh \
  --repo git@gitlab.com:sparkmeter/earthspark/ansible.git --ref main
```

`--repo` re-checks out the repo under `/opt/groundbolt-setup/repo` (refreshed on
each re-run) — that's the copy the playbook is run from, so re-running picks up
the latest `main` without re-cloning by hand.

### Option B — serve the repo over HTTP (no git auth on the target)

Clone the repo on your machine and start a web server **from inside the repo
folder** — the bootstrap expects the files at the server root
(`playbook.yml`, `templates/...`):

```sh
git clone git@gitlab.com:sparkmeter/earthspark/ansible.git
cd ansible
python3 -m http.server 8000
```

Get the URL the target will use to reach this machine. Run this **on the machine
serving the files** (it must be on a network the target can route to):

```sh
# macOS
echo "http://$(ipconfig getifaddr en0):8000"
# Linux
echo "http://$(hostname -I | awk '{print $1}'):8000"
```

Use that as `<WEBSERVER>`. The bootstrap and all files are then reachable at
`<WEBSERVER>/...` (e.g. `<WEBSERVER>/bootstrap_groundbolt.sh`):

```sh
curl -fsSL http://<WEBSERVER>/bootstrap_groundbolt.sh \
  | sudo bash -s -- --fileserver http://<WEBSERVER>
```

(The script prompts for the secrets, so no `export`s are needed. Use `sudo -E`
instead if you want to pre-seed any values from the environment.)

## After it finishes

- Configuration is persisted at `/etc/groundbolt/inventory.ini`.
- Verify the mesh connection with `netbird status`.
- Reach the app at `http://localhost/` (or over the NetBird mesh IP).

If you skipped the setup key at the prompt, NetBird is installed but not
registered — the bootstrap won't run the interactive `netbird up` (it would
block a non-interactive run). The final output prints the exact `netbird up`
command to run on the device; it shows a browser login URL to complete
registration.

## Extending the deployment

Each component runs as its own compose project on a shared network, so you can
run your own services alongside the deployment — for example your own application
talking to the gateway in place of `thundercloud`, or `thundercloud` together
with your own sidecar services. You do that from your own ansible/compose,
integrating through two stable surfaces this deployment exposes.

### The inventory — `/etc/groundbolt/inventory.ini`

The resolved configuration (image tags, gateway serial, registry creds, etc.).
Point your own playbook at it:

    ansible-playbook -i /etc/groundbolt/inventory.ini your-playbook.yml

### The `sparkapp` network — a shared external Docker network

Our services run on it; join it to reach them by name. In your compose:

    networks:
      sparkapp:
        external: true

    services:
      my-service:
        image: my-image
        networks: [sparkapp]
        environment:
          METERING_URL: http://sparknet-http:8080

Compose registers each service's name as a network alias, so your containers
reach `sparknet-http` (the gateway, port 8080) and `app` (the webapp) across
project boundaries. There is no cross-project `depends_on` — reach a service over
the network and retry until it answers.
