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

On the first run it prompts for the secrets it doesn't have — `NETBIRD_SETUP_KEY`
— and the per-device `GATEWAY_SERIAL`. `VAULT_POSTGRES_PASSWORD` is generated once
and persisted. The prompts read from the terminal, so they work even through
`curl … | bash`.

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

## Running it

The target must be Debian/Ubuntu (apt-based). Run the bootstrap on it — it pulls
this repo and the playbook, then provisions the host:

```sh
curl -fsSL https://raw.githubusercontent.com/EarthSpark/ansible/main/bootstrap_groundbolt.sh \
  | sudo bash -s -- --repo https://github.com/EarthSpark/ansible.git --ref main
```

`--repo` checks the repo out under `/opt/groundbolt-setup/repo` (refreshed each
run), so re-running picks up the latest `main`. Prompts read from the terminal,
so they work through the pipe; to pre-seed a secret and skip its prompt, `export
VAR=…` and use `sudo -E`.

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

The resolved configuration (image tags, gateway serial, etc.).
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
