# RaspAP + WebOne image builder

Debian script that builds one flashable Raspberry Pi **64-bit** `.img`: official [RaspAP](https://raspap.com/) plus [WebOne](https://github.com/atauenis/webone).

It downloads the official RaspAP Lite image, grows it with `dd`, customizes it (loop mount + qemu), and writes a final `.img` you flash with Raspberry Pi Imager.

## What you get

| Item | Value |
| --- | --- |
| Base OS | Official RaspAP 64-bit Lite (Debian Trixie, currently 3.5.5) |
| WebOne | arm64 `.deb` (currently 0.18.2), proxy `10.3.141.1:8080` |
| Hotspot IP | `10.3.141.1/24` |
| Default SSID | `RaspAP` (RaspAP default) |
| Wi-Fi password | `ChangeMe` (RaspAP default) |
| Hostname | **none — you set it** |
| Login user / password | **none — you set them** |
| RaspAP web admin | `admin` / `secret` (RaspAP default) |
| SSH | On by default; can be turned off |
| PAC / WPAD | `http://10.3.141.1/wpad.dat` |

Connect to the hotspot, then:

- RaspAP: http://10.3.141.1/
- WebOne: `10.3.141.1:8080`
- SSH (if enabled): `USER@10.3.141.1` or `USER@HOSTNAME.local`

## Host requirements

- Debian Trixie
- Root 
- About **9 GB** free for a full new build (soft-warn under 10 GB; refuses under ~4.5 GB)
- For the graphical UI: `python3-tk`

```bash
sudo apt-get install -y python3-tk
```

The script installs the other build tools itself (`qemu-user-static`, `mtools`, `parted`, …).

## Run it

**Download the zip or clone**

- `build-raspap-webone.sh`
- `build-cli`
- `build-gui`

```bash
sudo ./build-cli       # text menu / flags
sudo ./build-gui       # graphical window
```

`./build-cli` and `./build-gui` also work — they run `sudo` for you.

```bash
sudo ./build-cli --help
```

### UI

- **New** / **Update** / **Delete all**
- Hostname, user, password, SSID, Wi-Fi password
- **View** shows a hidden password
- **Enable SSH** (optional public key)
- **Skip extras** (WebOne only, no ffmpeg / yt-dlp)
- A progress bar in the terminal; a progress window if you have a display

### CLI (no window)

```bash
sudo ./build-cli --new --name mypi --user myuser --password 'your-login-pass'
```

Optional:

```bash
  --ssid RaspAP \
  --wifi-pass ChangeMe \
  --no-ssh \
  --ssh-key /home/you/.ssh/id_ed25519.pub \
  --skip-extras \
  --expand-mib 1024 \
  --workdir /home/you/work \
  --outdir /home/you/out
```

`--ssh-key` turns SSH on and bakes that `.pub` into the image.

## Modes

| Mode | What it does |
| --- | --- |
| **New** (`--new`) | Wipe working files (keeps downloads) and rebuild from official RaspAP |
| **Update** (`--update [FILE]`) | Remount an existing `.img`, re-apply settings, check GitHub for newer RaspAP / WebOne |
| **Delete all** (`--delete-all`) | Wipe work, output, **and** downloads, then full rebuild |
| Resume | If the last run died mid-build, run the **same command again** |

An in-place RaspAP git upgrade only works if `/var/www/html/.git` is in the image. If it is missing, use `--delete-all` for a new official OS image.

## Output

Default layout next to the script:

```
work/          scratch (downloads, working .img, mounts)
out/           final image + .sha256
```

Final name:

```
out/HOSTNAME-raspap3.5.5-webone0.18.2-arm64.img
```

## Flash it

Raspberry Pi Imager:

1. **Choose OS** → **Use custom** → the `.img`
2. **Services** → Enable SSH → password and/or paste a public key
3. Write

Or:

```bash
sudo dd if=out/HOSTNAME-raspap3.5.5-webone0.18.2-arm64.img of=/dev/sdX bs=4M status=progress conv=fsync && sync
```

Replace `/dev/sdX` with the real card device. Imager SSH customisation still works: the builder does not disable `userconfig.service`.

## SSH

- Default: SSH **on** (boot `ssh` flag + `ssh.service` enabled)
- UI: uncheck **Enable SSH**, or CLI: `--no-ssh`
- Off = no remote login. You can still turn SSH on later in Raspberry Pi Imager
- Pubkey and password auth are both allowed when SSH is on

## Interrupted builds

The script is verbose and checkpointed. If it stops:

```bash
sudo ./build-cli
```

Same flags as before. To throw the work away:

```bash
sudo ./build-cli --new
```

Last error is in `work/last-error.txt`.

## Notes

- Build host can be x86_64; the image is aarch64 (qemu + binfmt)
- Peak disk is roughly: zip + working image + final image
- RaspAP admin `admin` / `secret` is the official image default — change it in the RaspAP web UI after first boot
- WebOne proxy for clients: `10.3.141.1:8080`, or set the PAC URL to `http://10.3.141.1/wpad.dat`
