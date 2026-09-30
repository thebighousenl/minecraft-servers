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

Server settings come only from env vars in `servers/<server>/patch.yaml`. The image rewrites
`server.properties` from them on every start. See the
[image's env var list](https://github.com/itzg/docker-minecraft-bedrock-server#server-properties).

## Checks

```bash
tests/render-test.sh              # renders all overlays, dry-runs against the cluster
tests/restore-world-test.sh       # restore script validation
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
6. **Apply** (the Traefik change restarts Traefik for a few seconds):
   ```bash
   kubectl apply -f cluster/traefik-helmchartconfig.yaml
   kubectl apply -k servers/creative
   ```
7. **Open the firewall** for the new UDP port (ufw on the node and/or the VPS provider's firewall).
8. **Verify:**
   ```bash
   kubectl -n minecraft-servers logs deploy/bedrock-creative | grep "Server started"
   python3 scripts/raknet-ping.py 13.140.175.141 19232
   ```
9. **Add a row to the server table** above and commit.

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
3. **Create only the volume** (so the server does not generate an empty world first):
   ```bash
   kubectl apply -k servers/<server> -l app.kubernetes.io/component=storage
   ```
4. **Restore the world** (the folder name must equal `LEVEL_NAME`; quote paths with spaces):
   ```bash
   scripts/restore-world.sh --dry-run <server> "<backup>/serverfiles/worlds/<world>"
   scripts/restore-world.sh <server> "<backup>/serverfiles/worlds/<world>"
   ```
5. **Apply everything:**
   ```bash
   kubectl apply -f cluster/traefik-helmchartconfig.yaml
   kubectl apply -k servers/<server>
   ```
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

## Operations

```bash
kubectl -n minecraft-servers get pods
kubectl -n minecraft-servers logs -f deploy/bedrock-<server>
kubectl -n minecraft-servers rollout restart deploy/bedrock-<server>
```

**Console:** `kubectl -n minecraft-servers attach -it deploy/bedrock-<server>`, type commands such
as `list` or `op <player>`. Detach with `Ctrl-P Ctrl-Q`. `Ctrl-C` stops the server; it then
restarts.

**Updating Bedrock:** `rollout restart` pulls the latest image and server version.

**Removing a server:**

1. Delete its entry from `cluster/traefik-helmchartconfig.yaml` and apply it.
2. `kubectl delete -k servers/<server>`. **This deletes the PVC and the world with it.** Copy the
   world out first if you want to keep it.
3. Delete `servers/<server>`, remove its table row, close its firewall port.

## Firewall

Traefik listens on the node's public IP. Each server's UDP port must also be allowed by ufw on the
node (if enabled) and by the VPS provider's firewall.
