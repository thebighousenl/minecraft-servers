# Minecraft Bedrock servers

Kustomize manifests for Minecraft Bedrock Edition servers on the k3s cluster (`bighaus` context),
namespace `minecraft-servers`. Servers use the
[`itzg/minecraft-bedrock-server`](https://github.com/itzg/docker-minecraft-bedrock-server) image.

## Servers

| Server | World | Mode | Port | Connect to | Migrated from |
|---|---|---|---|---|---|
| `daan` | Daan | adventure | 19332 | `13.140.175.141:19332` | LinuxGSM `mcserverdaan` |

Xbox players use BedrockConnect (custom DNS) and enter the address and port from this table.

## How it works

Bedrock uses RakNet over UDP. The protocol carries no hostname, so several servers cannot share
one port behind a proxy. Every server gets its own public UDP port:

```
player ─UDP <port>─▶ node 13.140.175.141 ─▶ Traefik entrypoint mc-<server>
       ─▶ IngressRouteUDP bedrock-<server> ─▶ Service bedrock-<server>:19132 ─▶ pod
```

| Path | Purpose |
|---|---|
| `base/` | Generic server: Deployment, PVC (`local-path`, 5Gi), Service, IngressRouteUDP |
| `servers/<server>/` | Per-server overlay: name suffix, entrypoint, env settings |
| `cluster/traefik-helmchartconfig.yaml` | Traefik UDP entrypoints, one per server (lives in `kube-system`) |
| `scripts/restore-world.sh` | Copies a world folder into a server's volume |
| `scripts/raknet-ping.py` | Checks that a server answers from outside |
| `tests/` | Render and script tests |

Naming: overlay `servers/<server>` produces `bedrock-<server>` (Deployment, Service,
IngressRouteUDP), `bedrock-data-<server>` (PVC) and uses entrypoint `mc-<server>`.

The base sets `TRANSPORT=raknet`. Bedrock 1.26.50+ defaults to NetherNet (TCP plus a WebRTC UDP
range), which does not fit one UDP port per server. The server logs a "TRANSPORT TYPE ERROR"
warning at startup; Xbox clients connect fine over RakNet.

Server settings come only from env vars in `servers/<server>/patch.yaml`. The image rewrites
`server.properties` from them on every start. See the
[image's env var list](https://github.com/itzg/docker-minecraft-bedrock-server#server-properties).

## Checks

```bash
tests/render-test.sh              # renders all overlays, dry-runs against the cluster
tests/restore-world-test.sh       # restore script validation
tests/restore-world-cluster-test.sh  # restore script against the cluster (throwaway zz-rtest server)
tests/deploy-test.sh              # deploy dry-run with the CI's permissions
python3 -m unittest tests/test_raknet_ping.py
```

## Creating a new server (fresh world)

1. **Pick a name and a free port.** Name: lowercase, e.g. `creative`. Port: one not in the
   server table, e.g. `19232`.
2. **Add a Traefik entrypoint.** Add under `ports:` in `cluster/traefik-helmchartconfig.yaml`,
   keeping the existing entries. Indent `mc-creative:` exactly like `mc-daan:`:
   ```yaml
      mc-creative:
        port: 19232
        exposedPort: 19232
        protocol: UDP
        expose:
          default: true
   ```
3. **Create the overlay.** `cp -r servers/daan servers/creative`, then in
   `servers/creative/kustomization.yaml` replace every `daan` with `creative`
   (`nameSuffix`, the instance label, `mc-creative`, `bedrock-creative`).
4. **Set the server's settings** in `servers/creative/patch.yaml`: at least `SERVER_NAME`,
   `LEVEL_NAME`, `GAMEMODE`. Remove `LEVEL_SEED` for a random seed.
5. **Test:** `tests/render-test.sh` must pass.
6. **Deploy:** add the server to the table below (step 9), commit and push to `main`. CI runs
   `scripts/deploy.sh` (see *Deployment*). The Traefik change restarts Traefik for a few seconds.
7. **Open the firewall** for the new UDP port (ufw on the node and/or the VPS provider's firewall).
8. **Verify:**
   ```bash
   kubectl -n minecraft-servers logs deploy/bedrock-creative | grep "Server started"
   python3 scripts/raknet-ping.py 13.140.175.141 19232
   ```
9. **Add a row to the server table** above (commit it together with step 6).

## Migrating a server from a LinuxGSM backup

A LinuxGSM home directory has the live server in `serverfiles/`:

- `serverfiles/server.properties`: the settings to copy into env vars.
- `serverfiles/worlds/<world>/`: the world data. The active one is `level-name` in
  `server.properties`.
- `serverfiles/allowlist.json`, `serverfiles/permissions.json`: players and operators.
- `lgsm/backup/*.tar.*`: older snapshots; use them only if `serverfiles` is missing or broken.

Steps:

1. **Read the old settings:**
   ```bash
   grep -Ev '^\s*(#|$)' <backup>/serverfiles/server.properties
   ```
2. **Create the server** with steps 1–5 of *Creating a new server*, mapping properties to env vars:

   | `server.properties` | env var | notes |
   |---|---|---|
   | `server-name` | `SERVER_NAME` | |
   | `level-name` | `LEVEL_NAME` | must equal the world folder name |
   | `gamemode` | `GAMEMODE` | `0`/`1`/`2` = `survival`/`creative`/`adventure` |
   | `difficulty` | `DIFFICULTY` | fix typos like `peacefull` |
   | `level-seed` | `LEVEL_SEED` | quote it; only matters for new chunks |
   | `max-players` | `MAX_PLAYERS` | |
   | `online-mode` | `ONLINE_MODE` | |
   | `allow-list` / `white-list` | `ALLOW_LIST` | |
   | `allow-cheats` | `ALLOW_CHEATS` | |
   | `default-player-permission-level` | `DEFAULT_PLAYER_PERMISSION_LEVEL` | |
   | `view-distance` | `VIEW_DISTANCE` | only if changed from default |
   | `tick-distance` | `TICK_DISTANCE` | only if changed from default |
   | `allowlist.json` entries | `ALLOW_LIST_USERS` | `name:xuid,name:xuid` |
   | `permissions.json` operators | `OPS` | `xuid,xuid` |

   Use the old `server-port` as the public port so players' saved entries keep working.
   **Do not push yet.** CI would start the server, and it would generate an empty world first.
3. **Create only the volume** from your machine:
   ```bash
   kubectl apply -k servers/<server> -l app.kubernetes.io/component=storage
   ```
4. **Restore the world** (the folder name must equal `LEVEL_NAME`; quote paths with spaces):
   ```bash
   scripts/restore-world.sh --dry-run <server> "<backup>/serverfiles/worlds/<world>"
   scripts/restore-world.sh <server> "<backup>/serverfiles/worlds/<world>"
   ```
   If the script reports an empty `level.dat`, copy the world folder somewhere else (keep its
   name), run `cp level.dat_old level.dat` inside the copy, and restore from the copy.
5. **Deploy:** commit and push to `main`. CI applies the Traefik port and the server.
6. **Open the firewall, verify and add the table row** as in steps 7–9 of *Creating a new server*.
   Check the logs show your world's name loading, not a new world.

Notes:

- **The world upgrade is one-way.** The server runs the latest Bedrock version and upgrades older
  worlds on first start. Keep the original backup.
- **Add-ons:** worlds with `behavior_packs/` and `resource_packs/` folders inside the world folder
  (e.g. `mcbflat1/serverfiles/worlds/plaskut`) carry their packs with them.
- **Replacing a world** on an existing server: `scripts/restore-world.sh --force <server> <dir>`
  scales the server down, replaces the world and scales it back up. This deletes the current world
  on the server.

## Deployment

Every push to `main` that touches `base/`, `servers/`, `cluster/` or `scripts/deploy.sh` runs the
OneDev job **deploy servers** (`.onedev-buildspec.yml`) on the `cluster-deployer` executor. The
job runs `scripts/deploy.sh`, which:

1. server-side dry-runs the Traefik config and every overlay, and stops if any of them fails;
2. applies `cluster/traefik-helmchartconfig.yaml` and every `servers/<server>`;
3. waits for every server's rollout.

It never deletes anything. See *Removing a server*.

Run the same thing by hand with `scripts/deploy.sh` (or `scripts/deploy.sh --dry-run`).

**One-time permission setup:** the executor's ServiceAccount (`onedev/onedev`) uses the
hand-applied ClusterRole `manifest-deployer`. That role needs access to `ingressrouteudps` and
`helmchartconfigs`:

```bash
kubectl patch clusterrole manifest-deployer --type=json \
  -p "$(cat cluster/rbac/manifest-deployer-patch.json)"
tests/deploy-test.sh   # must print "all checks passed"
```

## Operations

```bash
kubectl -n minecraft-servers get pods
kubectl -n minecraft-servers logs -f deploy/bedrock-<server>
kubectl -n minecraft-servers rollout restart deploy/bedrock-<server>
```

**Server commands:** run console commands such as `list` or `op <player>` with the image's
`send-command` helper; the output appears in the logs:

```bash
kubectl -n minecraft-servers exec deploy/bedrock-<server> -- send-command list
kubectl -n minecraft-servers logs --tail=5 deploy/bedrock-<server>
```

**Updating Bedrock:** `rollout restart` pulls the latest image and server version.

**Removing a server** (manual; CI never deletes):

1. Delete its entry from `cluster/traefik-helmchartconfig.yaml` and apply it.
2. `kubectl delete -k servers/<server>`. **This deletes the PVC and the world with it.** Copy the
   world out first if you want to keep it.
3. Delete `servers/<server>`, remove its table row, close its firewall port.

## Firewall

Traefik listens on the node's public IP. Each server's UDP port must also be allowed by ufw on the
node (if enabled) and by the VPS provider's firewall.
