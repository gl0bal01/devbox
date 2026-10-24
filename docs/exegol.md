# Exegol and HTB VPN

[Exegol](https://exegol.com) containers with a browser desktop (noVNC) reachable over Tailscale, plus a host-side OpenVPN helper for HTB/THM labs. Exegol containers are not hardened like the rest of the stack. See [security.md](security.md#boundaries).

## Prerequisites

- The `exegol` CLI is installed by setup.sh through mise (`pypi:exegol`), unless you used `--no-dev-tools`. If you get `command not found`, open a new login shell, or run `mise install` as the operator.
- On the first start the Exegol CLI asks you to accept its EULA. It may also ask you to activate a licence (the free Community plan is for personal, non-commercial use). It then downloads the `free` image, which is several GB. To fetch the image in advance: `exegol install free`.
- Clients resolve `exegol.internal` to the server's Tailscale IP (the same hosts entry as `ai.internal`). The Tailscale IP works directly too.

## Start a container

```bash
exegol-up [name] [--port PORT] [--vpn FILE] [--log] [--privileged]
```

`exegol-up` is a zsh alias for `~/docker/exegol-start.sh`.

| Option | Default | Effect |
|---|---|---|
| `name` | `htb` | The container is named `exegol-<name>` |
| `--port` | `45377` | noVNC port |
| `--vpn FILE` | none | OpenVPN or WireGuard config started inside the container (Exegol `--vpn`) |
| `--log` | off | Shell logging to `/workspace/logs/` |
| `--privileged` | off | Full privileges. Use it only if a tool needs it. |

On first creation, the script does the following:

1. It adds a UFW rule `allow in on tailscale0` for the port, with comment `exegol-novnc-exegol-<name>`. The rule is never removed automatically.
2. It runs `exegol start <name> free --workspace ~/docker/exegol-workspace/<name> --desktop --desktop-config http:0.0.0.0:<port>` with Exegol's default host networking. The desktop listens on all interfaces, and UFW limits it to `tailscale0`. `security-check.sh` reports it as an expected warning.
3. Once the container exists, it sets a random password for `root` and prints it once:

   ```
   Desktop: http://exegol.internal:45377/vnc.html  user: root  password: ...
   ```

Options apply only when the container is created. If `exegol-<name>` already exists, the script just runs `exegol start <name>`. The password set at creation stays valid.

Run several containers side by side by giving each its own name and port, for example `exegol-up osint --port 45378`.

## Manage containers

```bash
exegol info                          # list containers and images (alias: exegol-list)
exegol start htb                     # start if needed and open a shell
exegol stop htb
exegol remove htb
exegol-reset exegol-htb              # new root/noVNC password (~/docker/exegol-reset-vnc.sh)
```

After removing a container, delete its firewall rule:

```bash
sudo ufw status | grep exegol-novnc
sudo ufw delete allow in on tailscale0 to any port 45377 proto tcp
```

## Workspace and backups

`exegol-up` creates each container with `/workspace` mapped to `~/docker/exegol-workspace/<name>` on the host. `backup.sh` archives that directory, so your engagement files are part of every backup. A container always keeps the workspace it was created with. Containers created with the plain `exegol` CLI use Exegol's default, `~/.exegol/workspaces/<container>`, which is not backed up.

## HTB / THM VPN on the host

`htb-vpn` (`~/docker/htb-vpn.sh`) runs OpenVPN on the host. All host-network containers, Exegol included, share the resulting `tun0`.

```bash
htb-vpn                           # start with ~/htb/lab.ovpn
htb-vpn ~/htb/other.ovpn          # start with another file (or: htb-vpn start ~/htb/other.ovpn)
htb-vpn status
htb-vpn stop
```

- Starting the VPN replaces a tunnel that is already running. The script tightens the `.ovpn` file to mode 0600, starts `sudo openvpn --daemon`, and waits up to 10 s for `tun0`.
- The PID file and log are in `/run/devbox/` (`htb-vpn.pid`, `htb-vpn.log`), which is recreated at boot. Stopping runs `sudo pkill -F /run/devbox/htb-vpn.pid openvpn`, which signals only the process in that file, and only if it is openvpn.
- Both `sudo openvpn` and that `pkill` are passwordless sudoers entries, so the helper never asks for a password.

For a VPN that only one container uses, pass `--vpn` to `exegol-up` when you create it instead.

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| Desktop page times out | `sudo ufw status \| grep <port>`, `ss -ltn \| grep <port>` | Add the UFW rule shown above, or start the container |
| `tailscale0 not found` | `tailscale status` | `sudo tailscale up` |
| Password never printed | The container took longer than 2 minutes to appear | `exegol-reset exegol-<name>` |
| Port already in use | `ss -ltnp \| grep <port>` | Pick another `--port` |
| `No tun0 after 10s` | `sudo tail /run/devbox/htb-vpn.log` | Fix the `.ovpn` file or the credentials. Check that the lab isn't expired. |
| `/run/devbox missing` | `ls /etc/tmpfiles.d/devbox.conf` | Re-run `sudo ./setup.sh` |
| Targets unreachable from Exegol | `ip route get 10.10.10.1` on the host | Start the VPN. Containers created with Exegol `--network` other than host don't see the host's `tun0`. |
