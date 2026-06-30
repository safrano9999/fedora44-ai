# fedora44-ai Container Build

This document maps the current `Containerfile` to the 55 steps reported by Buildah/Podman. It also records where each input originates, where it is installed, and which runtime component uses it.

## Build entrypoint and source of truth

`setup.sh` is the host-side entrypoint. Before Podman reads the `Containerfile`, it performs the following work:

1. Clone or fast-forward the repositories listed in `setup.sh:REPOS` into `./safrano9999/`.
2. Recreate the shared hardlinks from the development SOT at `../../SCRIPTS/safrano9999/` into `./SCRIPTS/safrano9999/`.
3. Run `SCRIPTS/safrano9999/image/relink_shared.sh` so shared files such as `config.sh`, `python_header.py`, and the common systemd units have one canonical implementation.
4. Merge all repository `env.example` and `requirements.txt` files through `merge.sh`, deduplicating environment keys and Python package names.
5. Merge every repository example class and `requirements.txt` through the hardlinked `SCRIPTS/safrano9999/merge.sh`.
6. Resolve `fedora.build.conf_example` into the non-runtime `build.conf`, stage valid public certificates from `CERTS` inside the build context, and pass all build values as Containerfile arguments.
7. Run the shared `config.sh`, then render `<CONTAINER_NAME>-compose.yml` and `<CONTAINER_NAME>.container` from `.env`, `config.conf`, and `container.conf`.
8. Ask whether to pull `docker.io/safrano9999/fedora44-ai:latest` or build `localhost/fedora44-ai:latest` from this `Containerfile`.

The build context deliberately excludes secrets and generated configuration through `.dockerignore`: `.env`, `build.conf`, `config.conf`, `container.conf`, generated Quadlets/Compose files, Git metadata, and Python caches are not copied into the image. Only validated public certificates are copied into the staged `CERTS` path; private keys are rejected.

## Runtime configuration model

- Secrets and credentials live in `.env`.
- Build-only versions and the host certificate source live in `build.conf`; this file is never injected at runtime.
- Non-secret application settings live in `config.conf`.
- Container-only settings such as publish ports, capabilities, devices, and volumes live in `container.conf`.
- The generated Quadlet injects all three files with `EnvironmentFile=` and publishes only the configured host ports.
- PID 1 is systemd. Units are installed under `/etc/systemd/system/` and enabled for `multi-user.target` during the image build.
- `*_PERSISTENT_PATH` values from `build.conf` are optional. Nonblank absolute paths create dedicated named volumes and are created by `fedora44-ai-init`; blank values remain ephemeral.
- `services/fedora44-runtime-environment-generator.sh` writes a global service drop-in at manager startup so injected container environment variables are available to system services.

## The 53 image steps

### 01 - Fedora 44 base image

```dockerfile
FROM quay.io/fedora/fedora:44
```

- **Instruction:** `FROM quay.io/fedora/fedora:44`
- **Purpose:** Starts from the Fedora 44 userspace used by every later layer.
- **Runtime:** The final image keeps Fedora systemd as PID 1; no Debian-style entrypoint is used.

### 02 - Electrum version

```dockerfile
ARG ELECTRUM_VERSION=4.7.2
```

- **Instruction:** `ARG ELECTRUM_VERSION=4.7.2`
- **Purpose:** Pins the Electrum artifact downloaded in step 22.
- **Scope:** Build-time only; it is not injected into the running container.

### 03 - LND version

```dockerfile
ARG LND_VERSION=v0.20.1-beta
```

- **Instruction:** `ARG LND_VERSION=v0.20.1-beta`
- **Purpose:** Pins the LND archive installed in step 23.
- **Scope:** Build-time only.

### 04 - Geth version

```dockerfile
ARG GETH_VERSION=1.17.2
```

- **Instruction:** `ARG GETH_VERSION=1.17.2`
- **Purpose:** Selects the Geth release installed in step 24.
- **Scope:** Used together with `GETH_COMMIT`.

### 05 - Geth commit identifier

```dockerfile
ARG GETH_COMMIT=be4dc0c4
```

- **Instruction:** `ARG GETH_COMMIT=be4dc0c4`
- **Purpose:** Completes the official Geth artifact filename and verification target.
- **Scope:** Build-time only.

### 06 - webhook version

```dockerfile
ARG WEBHOOK_VERSION=2.8.3
```

- **Instruction:** `ARG WEBHOOK_VERSION=2.8.3`
- **Purpose:** Pins the `adnanh/webhook` binary installed in step 19.
- **Scope:** Build-time only.

### 07 - Certificate source

```dockerfile
ARG CERTS=/srv/shared/certs
```

- **Instruction:** Declares the absolute host certificate source used by `setup.sh`.
- **Build context:** `setup.sh` mirrors validated public certificates at the corresponding relative context path, for example `./srv/shared/certs`.
- **Scope:** Build-time only; neither `CERTS` nor `build.conf` is injected into the running container.

### 08 - Fedora packages and base tools

```dockerfile
RUN --mount=type=cache,target=/var/cache/dnf \
    dnf -y update && dnf -y install \
    bash bash-completion shadow-utils sudo \
    git gh tmux \
    nano vim-minimal less \
    curl wget ca-certificates openssl gnupg2 fuse-libs \
    nodejs npm \
    python3 python3-pip \
    make gcc gcc-c++ \
    ripgrep fd-find jq unzip tar gzip xz which file \
    iputils iproute procps-ng psmisc util-linux \
    findutils grep sed gawk diffutils \
    hostname bind-utils net-tools traceroute \
    lsof strace tcpdump nmap-ncat \
    v4l-utils zbar qrencode bc ffmpeg mpv libv4l \
    dbus-x11 xauth mesa-dri-drivers \
    tailscale
```

- **Instruction:** Cached `dnf update` followed by `dnf install`.
- **Purpose:** Installs shells, Git/GitHub CLI, tmux, editors, Node/npm, Python/pip, compilers, diagnostics, multimedia tools, X11 support, networking tools, and Tailscale.
- **Cache:** `/var/cache/dnf` is a BuildKit/Buildah cache mount and is not an image volume.
- **Important paths:** Commands are installed in Fedora system paths such as `/usr/bin` and `/usr/sbin`.

### 09 - Staged public certificates

```dockerfile
COPY ${CERTS}/ /run/fedora44-ai-certs/
```

- **Instruction:** Copies the public certificates prepared by `setup.sh` into the image build.
- **Source:** `${CERTS}` is resolved inside the build context; an absolute value such as `/srv/shared/certs` maps to `./srv/shared/certs`.
- **Security:** `setup.sh` validates every candidate with `openssl x509`; private keys are never staged.

### 10 - Fedora certificate trust

```dockerfile
RUN \
    set -eu; \
    find /run/fedora44-ai-certs -type f \( -name '*.crt' -o -name '*.pem' \) -print \
      | while IFS= read -r cert; do \
          if openssl x509 -in "$cert" -noout >/dev/null 2>&1; then \
            fingerprint="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 \
              | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"; \
            install -m 0644 "$cert" "/etc/pki/ca-trust/source/anchors/fedora44-ai-${fingerprint}.crt"; \
          fi; \
        done; \
    update-ca-trust
```

- **Instruction:** Installs each valid certificate into Fedora's trust anchors and regenerates the system CA bundle.
- **Consumers:** Hermes/Python, OpenClaw/Node, curl, and other software can validate internal TLS certificates through the system trust store.
- **Result:** Public cloud CAs remain trusted while the configured internal certificates are added.

### 11 - Anza/Solana CLI

```dockerfile
RUN curl -sSfL https://release.anza.xyz/stable/install | sh \
 && find /root/.local/share/solana/install/active_release/bin -maxdepth 1 -type f -executable \
      -exec ln -sf {} /usr/local/bin/ \; \
 && solana --version
```

- **Instruction:** Runs the official Anza stable installer.
- **Purpose:** Installs the current stable Solana CLI toolchain.
- **Paths:** The installer writes below `/root/.local/share/solana/install/`; executable files are symlinked into `/usr/local/bin/`.
- **Verification:** `solana --version` must succeed during the build.

### 12 - uv and uvx

```dockerfile
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && ln -sf /root/.local/bin/uv /usr/local/bin/uv \
 && ln -sf /root/.local/bin/uvx /usr/local/bin/uvx
```

- **Instruction:** Runs Astral's `uv` installer.
- **Purpose:** Provides fast Python environment and tool management for application setup.
- **Paths:** Source binaries are under `/root/.local/bin/`; stable links are created at `/usr/local/bin/uv` and `/usr/local/bin/uvx`.

### 13 - Hermes source tree

```dockerfile
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent /usr/local/lib/hermes-agent
```

- **Instruction:** Shallow-clones `NousResearch/hermes-agent`.
- **Purpose:** Keeps the Hermes source and templates available inside the image.
- **Path:** `/usr/local/lib/hermes-agent`.
- **Consumers:** `hermes-configure-openai-v1` reads `cli-config.yaml.example`; the SSL patch edits `run_agent.py` when applicable.

### 14 - Hermes installation

```dockerfile
RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
      | bash -s -- --skip-setup
```

- **Instruction:** Runs Hermes' upstream `scripts/install.sh --skip-setup`.
- **Purpose:** Installs the native `hermes` CLI without launching interactive user configuration during image creation.
- **Runtime:** `hermes.service` and `hermes-dashboard.service` invoke `/usr/local/bin/hermes`.

### 15 - Global AI command-line tools

```dockerfile
RUN --mount=type=cache,target=/root/.npm \
    npm install -g --include=optional\
    @openai/codex@latest \
    @anthropic-ai/claude-code@latest \
    openclaw@latest
```

- **Instruction:** `npm install -g --include=optional @openai/codex@latest @anthropic-ai/claude-code@latest openclaw@latest`.
- **Purpose:** Installs Codex CLI, Claude Code, and OpenClaw globally.
- **Cache:** Uses the build cache at `/root/.npm`.
- **Paths:** Packages live under `/usr/local/lib/node_modules`; command shims live under `/usr/local/bin`.

### 16 - OpenClaw Brave plugin

```dockerfile
RUN --mount=type=cache,target=/root/.npm \
    openclaw plugins install @openclaw/brave-plugin
```

- **Instruction:** `openclaw plugins install @openclaw/brave-plugin`.
- **Purpose:** Adds Brave-backed web search support to the image's OpenClaw installation.
- **Runtime configuration:** `services/openclaw-configure.py` enables it only when `BRAVE_API_KEY` is present.

### 17 - OpenClaw Codex harness plugin

```dockerfile
RUN --mount=type=cache,target=/root/.npm \
    openclaw plugins install clawhub:@openclaw/codex
```

- **Instruction:** `openclaw plugins install clawhub:@openclaw/codex`.
- **Purpose:** Adds the Codex harness to OpenClaw.
- **Runtime configuration:** `openclaw-configure.py` enables the `codex` plugin entry. `CODEX_AUTH_PERSISTENCE=1` mounts only Codex authentication state; sessions remain ephemeral.

### 18 - cloudflared binary

```dockerfile
RUN curl -fL \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared \
 && chmod +x /usr/local/bin/cloudflared \
 && cloudflared --version
```

- **Instruction:** Downloads the latest Linux AMD64 Cloudflare Tunnel connector.
- **Path:** `/usr/local/bin/cloudflared`.
- **Runtime:** `cloudflared.service` runs it with `TUNNEL_TOKEN`. The unit is conditionally activated by runtime configuration rather than unconditionally enabled in step 53.

### 19 - adnanh/webhook binary

```dockerfile
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64) webhook_arch=amd64 ;; \
      aarch64|arm64) webhook_arch=arm64 ;; \
      armv7l|armv6l) webhook_arch=arm ;; \
      i386|i686) webhook_arch=386 ;; \
      *) echo "Unsupported webhook architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/adnanh/webhook/releases/download/${WEBHOOK_VERSION}/webhook-linux-${webhook_arch}.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "webhook-linux-${webhook_arch}/webhook"; \
    webhook -version
```

- **Instruction:** Detects the build architecture and extracts the pinned webhook release.
- **Purpose:** Provides the generic HTTP-to-command webhook runner used by components such as the optional PV_D-A-CH QGIS bridge.
- **Path:** `/usr/local/bin/webhook`.
- **Verification:** `webhook -version` must succeed.

### 20 - systemd container cleanup

```dockerfile
RUN cd /usr/lib/systemd/system/sysinit.target.wants/ 2>/dev/null \
    && for i in *; do [ "$i" = "systemd-tmpfiles-setup.service" ] || rm -f "$i"; done || true \
 && rm -f /usr/lib/systemd/system/multi-user.target.wants/* \
 && rm -f /etc/systemd/system/*.wants/* \
 && rm -f /usr/lib/systemd/system/local-fs.target.wants/* \
 && rm -f /usr/lib/systemd/system/sockets.target.wants/*udev* \
 && rm -f /usr/lib/systemd/system/sockets.target.wants/*initctl* \
 && rm -f /usr/lib/systemd/system/basic.target.wants/* \
 && rm -f /usr/lib/systemd/system/anaconda.target.wants/*
```

- **Instruction:** Removes host-oriented default wants and sockets from Fedora's systemd tree.
- **Purpose:** Prevents hardware, installer, udev, and host boot units from starting inside the container.
- **Preserved unit:** `systemd-tmpfiles-setup.service` remains available.
- **Result:** The image still uses full systemd, but with an intentionally reduced container boot graph.

### 21 - BIP39 static application

```dockerfile
RUN mkdir -p /usr/local/share/bip39 \
 && curl -fsSL \
    https://github.com/iancoleman/bip39/releases/download/0.5.6/bip39-standalone.html \
    -o /usr/local/share/bip39/index.html \
 && echo "129b03505824879b8a4429576e3de6951c8599644c1afcaae80840f79237695a  /usr/local/share/bip39/index.html" \
    | sha256sum -c -
```

- **Instruction:** Downloads the pinned Ian Coleman BIP39 standalone HTML and verifies its SHA-256 hash.
- **Path:** `/usr/local/share/bip39/index.html`.
- **Runtime:** `bip39.service` runs `python3 -m http.server` from `/usr/local/share/bip39` on `BIP39_PORT`, default `11002`.

### 22 - Electrum AppImage extraction

```dockerfile
RUN mkdir -p /opt/electrum \
 && cd /opt/electrum \
 && curl -fsSLO "https://download.electrum.org/${ELECTRUM_VERSION}/electrum-${ELECTRUM_VERSION}-x86_64.AppImage" \
 && curl -fsSLO "https://download.electrum.org/${ELECTRUM_VERSION}/electrum-${ELECTRUM_VERSION}-x86_64.AppImage.asc" \
 && curl -fsSL https://raw.githubusercontent.com/spesmilo/electrum/master/pubkeys/ThomasV.asc | gpg --batch --import \
 && curl -fsSL https://raw.githubusercontent.com/spesmilo/electrum/master/pubkeys/sombernight_releasekey.asc | gpg --batch --import \
 && curl -fsSL https://raw.githubusercontent.com/spesmilo/electrum/master/pubkeys/Emzy.asc | gpg --batch --import \
 && curl -fsSL https://raw.githubusercontent.com/spesmilo/electrum/master/pubkeys/felixb_f321x.asc | gpg --batch --import \
 && gpg --batch --verify "electrum-${ELECTRUM_VERSION}-x86_64.AppImage.asc" "electrum-${ELECTRUM_VERSION}-x86_64.AppImage" \
 && chmod +x "electrum-${ELECTRUM_VERSION}-x86_64.AppImage" \
 && "./electrum-${ELECTRUM_VERSION}-x86_64.AppImage" --appimage-extract >/dev/null \
 && rm -f "electrum-${ELECTRUM_VERSION}-x86_64.AppImage" "electrum-${ELECTRUM_VERSION}-x86_64.AppImage.asc" \
 && printf '%s\n' '#!/usr/bin/env bash' 'cd /opt/electrum/squashfs-root' 'exec ./AppRun "$@"' > /usr/local/bin/electrum \
 && chmod +x /usr/local/bin/electrum
```

- **Instruction:** Downloads the pinned AppImage and signature, imports official release keys, verifies the signature, and extracts the AppImage.
- **Path:** Extracted application at `/opt/electrum/squashfs-root`.
- **Command:** `/usr/local/bin/electrum` changes to the extracted tree and executes `AppRun`.
- **Why:** The extracted AppImage works inside the container without requiring a runtime FUSE mount.

### 23 - LND and lncli

```dockerfile
RUN mkdir -p /tmp/lnd \
 && curl -fsSL \
    "https://github.com/lightningnetwork/lnd/releases/download/${LND_VERSION}/lnd-linux-amd64-${LND_VERSION}.tar.gz" \
    -o "/tmp/lnd/lnd-linux-amd64-${LND_VERSION}.tar.gz" \
 && echo "e01f755ba18e45a7b20f9fd645a328a250aae241e23b8c1eca06efeb2974570a  /tmp/lnd/lnd-linux-amd64-${LND_VERSION}.tar.gz" \
    | sha256sum -c - \
 && tar -xzf "/tmp/lnd/lnd-linux-amd64-${LND_VERSION}.tar.gz" -C /tmp/lnd \
 && install -m 0755 "/tmp/lnd/lnd-linux-amd64-${LND_VERSION}/lnd" /usr/local/bin/lnd \
 && install -m 0755 "/tmp/lnd/lnd-linux-amd64-${LND_VERSION}/lncli" /usr/local/bin/lncli \
 && rm -rf /tmp/lnd \
 && lnd --version \
 && lncli --version
```

- **Instruction:** Downloads the pinned LND archive, checks SHA-256, extracts it, and installs both binaries.
- **Paths:** `/usr/local/bin/lnd` and `/usr/local/bin/lncli`.
- **Verification:** Both version commands run during the build.

### 24 - Geth

```dockerfile
RUN gpgconf --kill all && rm -rf /root/.gnupg \
 && mkdir -p /tmp/geth \
 && cd /tmp/geth \
 && curl -fsSLO "https://gethstore.blob.core.windows.net/builds/geth-linux-amd64-${GETH_VERSION}-${GETH_COMMIT}.tar.gz" \
 && curl -fsSLO "https://gethstore.blob.core.windows.net/builds/geth-linux-amd64-${GETH_VERSION}-${GETH_COMMIT}.tar.gz.asc" \
 && echo "56d2b4772c63b02e7487c76a56b7afd5  geth-linux-amd64-${GETH_VERSION}-${GETH_COMMIT}.tar.gz" | md5sum -c - \
 && gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys A61A13569BA28146 \
 && gpg --batch --verify "geth-linux-amd64-${GETH_VERSION}-${GETH_COMMIT}.tar.gz.asc" "geth-linux-amd64-${GETH_VERSION}-${GETH_COMMIT}.tar.gz" \
 && tar -xzf "geth-linux-amd64-${GETH_VERSION}-${GETH_COMMIT}.tar.gz" \
 && install -m 0755 "geth-linux-amd64-${GETH_VERSION}-${GETH_COMMIT}/geth" /usr/local/bin/geth \
 && rm -rf /tmp/geth \
 && geth version
```

- **Instruction:** Downloads the pinned Geth archive and signature, checks the artifact checksum, imports the release key, and verifies the signature.
- **Path:** `/usr/local/bin/geth`.
- **Cleanup:** Temporary files and the temporary GPG home are removed from the resulting layer.

### 25 - XDG runtime directory

```dockerfile
RUN mkdir -p /tmp/runtime-root \
 && chmod 700 /tmp/runtime-root
```

- **Instruction:** Creates `/tmp/runtime-root` with mode `0700`.
- **Purpose:** Supplies the default `XDG_RUNTIME_DIR` used by GUI and desktop-aware tools inside the container.
- **Related variables:** `DISPLAY`, `NO_AT_BRIDGE`, and `XDG_RUNTIME_DIR` originate in `env.fedora44-ai.example` and are injected at runtime.

### 26 - Combined Python requirements

```dockerfile
COPY requirements.txt /requirements.txt
```

- **Instruction:** Copies generated `requirements.txt` to `/requirements.txt`.
- **SOT:** `merge.sh` builds this file from every staged repository's `requirements.txt`, deduplicated by package name.
- **Security:** The generated file contains package declarations only, not environment credentials.

### 27 - Shared Python runtime packages

```dockerfile
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r /requirements.txt
```

- **Instruction:** `pip install -r /requirements.txt` with a cached pip download directory.
- **Purpose:** Installs dependencies needed by standalone applications and shared runtime scripts into Fedora's system Python.
- **Cache:** `/root/.cache/pip` is build cache only.
- **Plugin isolation:** OpenClaw plugins may additionally create their own `.venv` in step 32.

### 28 - Application staging path

```dockerfile
ENV SAFRANO9999_STAGE_DIR=/opt/safrano9999/.stage
```

- **Instruction:** `ENV SAFRANO9999_STAGE_DIR=/opt/safrano9999/.stage`.
- **Purpose:** Gives the SOT installation helpers a deterministic temporary source tree.
- **Lifetime:** The stage directory is removed at the end of step 32.

### 29 - Staged safrano9999 repositories

```dockerfile
COPY safrano9999 ${SAFRANO9999_STAGE_DIR}
```

- **Instruction:** Copies `./safrano9999` into `${SAFRANO9999_STAGE_DIR}`.
- **SOT:** These are the clean Git clones updated by `setup.sh`; generated build clones must never be edited manually.
- **Purpose:** Makes every selected repository available to the shared installation helper without network cloning during this build path.

### 30 - Shared SCRIPTS tree

```dockerfile
COPY SCRIPTS /opt/safrano9999/SCRIPTS
```

- **Instruction:** Copies `./SCRIPTS` to `/opt/safrano9999/SCRIPTS`.
- **SOT:** The host tree is hardlinked from `../../SCRIPTS/safrano9999` by `setup.sh`.
- **Purpose:** Carries common config, environment, installation, relinking, systemd, OpenClaw, Tailscale, Cloudflare, and Python helper logic into the image.

### 31 - OpenClaw plugin installer helper

```dockerfile
COPY services/safrano9999_plugins.py /usr/local/bin/safrano9999_plugins.py
```

- **Instruction:** Copies `services/safrano9999_plugins.py` to `/usr/local/bin/safrano9999_plugins.py`.
- **Purpose:** Provides deterministic Python environment setup, OpenClaw link installation, command-auth adjustment, and plugin registration.
- **Consumers:** The shared `safrano9999_OC_plugins` function in step 32 and `openclaw-safrano9999` at runtime.

### 32 - Install standalone applications and OpenClaw plugins

```dockerfile
RUN bash -lc 'chmod +x /opt/safrano9999/SCRIPTS/safrano9999/image/safrano9999_container.sh \
 && . /opt/safrano9999/SCRIPTS/safrano9999/image/safrano9999_container.sh \
 && safrano9999_standalone \
      CODEANALYST JUGO VikAI PV_D-A-CH KIWIX_BRIDGE \
      NAPOLEON_HILLS_AI_MASTERMIND_CLASSES \
      SOLANA_AIRGAPPED_DEBIAN_WORKFLOW \
      NaturalGrounding-Tiktok-Ying-Video-Manager@feature/webui-db-backend-dual \
 && safrano9999_OC_plugins --link CITADEL \
 && safrano9999_OC_plugins --link --fullrun --crontab "CET 01:23,CET 07:00,CET 09:40,CET 12:00,CET 15:30,CET 19:00" \
      DAILYNEWS CALENDAR ZEROINBOX KACHELMANN SPANKER \
 && rm -rf "$SAFRANO9999_STAGE_DIR"'
```

- **Instruction:** Sources `/opt/safrano9999/SCRIPTS/safrano9999/image/safrano9999_container.sh` and runs its shared functions.
- **Standalone targets:** CODEANALYST, JUGO, VikAI, PV_D-A-CH, KIWIX_BRIDGE, Napoleon, Solana Airgapped Workflow, and NaturalGrounding are installed under `/opt/safrano9999/<repo>`.
- **OpenClaw plugin targets:** CITADEL, DAILYNEWS, CALENDAR, ZEROINBOX, KACHELMANN, and SPANKER are installed with links from `/opt/safrano9999`.
- **Generated commands:** The helper creates `/usr/local/bin/safrano9999-webhooks`, `/usr/local/bin/safrano9999-fullrun`, the `WEBHOOK-RUNNER` plugin, and `/opt/safrano9999/.openclaw-crontab`.
- **Plugin Python:** `safrano9999_plugins.py setup-python` prepares plugin environments before link installation.
- **Cleanup:** `${SAFRANO9999_STAGE_DIR}` is removed after installation, leaving only the runtime copies under `/opt/safrano9999`.

### 33 - Enable CITADEL providers in the image

```dockerfile
RUN mkdir -p /opt/safrano9999/CITADEL/extensions/enabled \
 && if [ -d /opt/safrano9999/CITADEL/extensions/disabled/subnet ]; then \
      mv /opt/safrano9999/CITADEL/extensions/disabled/subnet /opt/safrano9999/CITADEL/extensions/enabled/subnet; \
    fi \
 && if [ -d /opt/safrano9999/CITADEL/extensions/disabled/tailscale ]; then \
      mv /opt/safrano9999/CITADEL/extensions/disabled/tailscale /opt/safrano9999/CITADEL/extensions/enabled/tailscale; \
    fi \
 && chmod +x /opt/safrano9999/CITADEL/scan.sh
```

- **Instruction:** Moves CITADEL's `subnet` and `tailscale` provider directories from `extensions/disabled` to `extensions/enabled` when present.
- **Purpose:** Makes those providers available to CITADEL without starting or logging into Tailscale itself.
- **Path:** `/opt/safrano9999/CITADEL/extensions/enabled/`.
- **Runtime:** Marks `/opt/safrano9999/CITADEL/scan.sh` executable. `citadel-scan.service` runs it after the main services have started.

### 34 - Base systemd unit set

```dockerfile
COPY services/*.service /etc/systemd/system/
```

- **Instruction:** Copies every `services/*.service` file to `/etc/systemd/system/`.
- **Applications:** Includes CODEANALYST, JUGO, CITADEL, PV_D-A-CH, KIWIX_BRIDGE, Napoleon, NaturalGrounding, BIP39, Hermes, OpenClaw, Tailscale, Cloudflare, and Fedora initialization units.
- **Important distinction:** Copying installs unit definitions; step 53 decides which units are enabled by default.

### 35 - Plugin-owned WebUI units

```dockerfile
RUN install -m 0644 /opt/safrano9999/KACHELMANN/systemd/kachelmann-webui.service /etc/systemd/system/kachelmann-webui.service \
 && install -m 0644 /opt/safrano9999/SPANKER/systemd/spanker-webui.service /etc/systemd/system/spanker-webui.service
```

- **Instruction:** Installs KACHELMANN and SPANKER unit files from their own repositories.
- **Sources:** `/opt/safrano9999/KACHELMANN/systemd/kachelmann-webui.service` and `/opt/safrano9999/SPANKER/systemd/spanker-webui.service`.
- **Targets:** `/etc/systemd/system/kachelmann-webui.service` and `/etc/systemd/system/spanker-webui.service`.
- **Runtime:** Both use their repository `.venv`; KACHELMANN is started after OpenClaw plugin registration, while SPANKER is enabled directly.

### 36 - Runtime environment generator

```dockerfile
COPY services/fedora44-runtime-environment-generator.sh /usr/lib/systemd/system-generators/fedora44-runtime-environment-generator
```

- **Instruction:** Installs `services/fedora44-runtime-environment-generator.sh` as a systemd generator.
- **Path:** `/usr/lib/systemd/system-generators/fedora44-runtime-environment-generator`.
- **Purpose:** At manager startup, writes `service.d/90-fedora44-runtime-environment.conf` with `PassEnvironment=` for the injected container environment.
- **Cloudflare:** If `CLOUDFLARED_START` is true, the generator also creates the runtime wants-link for `cloudflared.service`.

### 37 - systemd drop-ins for Tailscale and OpenClaw

```dockerfile
COPY services/systemd/ /etc/systemd/system/
```

- **Instruction:** Copies four SOT-hardlinked unit drop-ins from `services/systemd/` to `/etc/systemd/system/`.
- **SOT:** The canonical files live under `SCRIPTS/safrano9999/image/services/{openclaw,tailscale}/`; setup hardlinks their deployment copies into `services/systemd/`.
- **Tailscale drop-in:** Adds `--ssh`, optional `TS_HOSTNAME`, route acceptance, DNS acceptance, and an `ExecStartPost` SSH enable call.
- **OpenClaw config drop-in:** Passes OpenAI-v1/VikAI variables and requires `OPENAI_V1_URL`, `OPENAI_V1_PORT`, and `OPENAI_V1_KEY`.
- **OpenClaw gateway drop-ins:** Pass the same provider variables and make `openclaw.service` require and follow `openclaw-safrano9999.service`.

### 38 - Initialization script directory

```dockerfile
RUN mkdir -p /usr/local/share/fedora44-ai/bin
```

- **Instruction:** Creates the deterministic image-owned initialization directory.
- **Runtime:** `fedora44-ai-init` executes image scripts from this directory in sorted order without persisting them.

### 39 - Claude Code onboarding marker

```dockerfile
RUN echo '{"hasCompletedOnboarding":true}' > /root/.claude.json
```

- **Instruction:** Writes `{"hasCompletedOnboarding":true}` to `/root/.claude.json`.
- **Purpose:** Prevents the first interactive Claude Code launch from blocking on its onboarding prompt.
- **Auth:** No credential is embedded; runtime auth still comes from injected configuration.

### 40 - OpenClaw configuration program

```dockerfile
COPY services/openclaw-configure.py /usr/local/bin/openclaw-configure
```

- **Instruction:** Copies `services/openclaw-configure.py` to `/usr/local/bin/openclaw-configure`.
- **Runtime caller:** `openclaw-config.service`, before the gateway.
- **Purpose:** Creates/updates `/root/.openclaw/openclaw.json`, configures the main agent, token auth, allowed origins, Telegram, Brave, Codex harness, VikAI agents, and OpenAI-compatible providers.
- **Main variables:** `OPENCLAW_START`, `OPENCLAW_GATEWAY_TOKEN`, `OPENCLAW_GATEWAY_PORT`, `OPENCLAW_GATEWAY_PUBLISH_PORT`, `OPENCLAW_TELEGRAMTOKEN`, `OPENAI_V1_*`, `OPENCLAW_OPENAI_V1_DEFAULT_LLM`, and optional numbered provider suffixes parsed by `python_header.py`.

### 41 - safrano9999 OpenClaw runtime registration

```dockerfile
COPY services/openclaw-safrano9999.py /usr/local/bin/openclaw-safrano9999
```

- **Instruction:** Copies `services/openclaw-safrano9999.py` to `/usr/local/bin/openclaw-safrano9999`.
- **Runtime caller:** `openclaw-safrano9999.service`, after OpenClaw config and before the gateway.
- **Purpose:** Reinstalls plugin links, disables plugin command auth where designed, writes plugin registration into OpenClaw config, and refreshes the plugin registry.
- **Post action:** The unit starts `kachelmann-webui.service` after registration.

### 42 - Hermes OpenAI-v1 configuration

```dockerfile
COPY services/hermes-configure-openai-v1.py /usr/local/bin/hermes-configure-openai-v1
```

- **Instruction:** Copies `services/hermes-configure-openai-v1.py` to `/usr/local/bin/hermes-configure-openai-v1`.
- **Runtime caller:** `hermes.service` runs it with `ExecStartPre`.
- **Purpose:** Builds `/root/.hermes/config.yaml`, discovers OpenAI-compatible providers, selects `HERMES_OPENAI_V1_DEFAULT_LLM`, configures the matching provider URL/key, and enforces certificate verification through Fedora's trust store.
- **Variables:** `OPENAI_V1_PROVIDER`, `OPENAI_V1_URL`, `OPENAI_V1_PORT`, `OPENAI_V1_KEY`, optional numbered variants, and `HERMES_OPENAI_V1_DEFAULT_LLM`.

### 43 - OpenClaw `/models` patch program

```dockerfile
COPY services/openclaw-patch-models-command.py /usr/local/bin/openclaw-patch-models-command
```

- **Instruction:** Copies `services/openclaw-patch-models-command.py` to `/usr/local/bin/openclaw-patch-models-command`.
- **Purpose:** Implements a bounded read-only catalog load for `/models` and avoids slow runtime auth discovery.
- **Current status:** The corresponding `RUN` line is commented out after step 53, so the program is present and executable but is not automatically applied by this `Containerfile`.

### 44 - VikAI agent bootstrap

```dockerfile
COPY services/vikai-bootstrap-openclaw-agents.py /usr/local/bin/vikai-bootstrap-openclaw-agents
```

- **Instruction:** Copies `services/vikai-bootstrap-openclaw-agents.py` to `/usr/local/bin/vikai-bootstrap-openclaw-agents`.
- **Runtime caller:** `openclaw-configure.py` calls it only when all three tokens are present.
- **Variables:** `TOKEN_WORKER`, `TOKEN_ARCHITECT`, and `TOKEN_QC` must be supplied together.
- **Purpose:** Creates the worker, architect, and QC OpenClaw agent workspaces and links their VikAI skills.

### 45 - Fedora initialization dispatcher

```dockerfile
COPY services/fedora44-ai-init.sh /usr/local/bin/fedora44-ai-init
```

- **Instruction:** Copies `services/fedora44-ai-init.sh` to `/usr/local/bin/fedora44-ai-init`.
- **Runtime caller:** `fedora44-ai.service` at `multi-user.target`.
- **Purpose:** Creates configured optional persistence paths, then executes deterministic image scripts in filename order.

### 46 - Shared OpenClaw Python helpers

```dockerfile
COPY services/openclaw_common.py /usr/local/bin/openclaw_common.py
```

- **Instruction:** Copies `services/openclaw_common.py` to `/usr/local/bin/openclaw_common.py`.
- **Consumers:** `openclaw-configure.py`, `openclaw-safrano9999.py`, and `hermes-configure-openai-v1.py`.
- **Purpose:** Centralizes OpenClaw command lookup, environment references, agent config, Telegram setup, Tailscale origins, and OpenAI-v1 provider/model discovery.
- **SOT:** Relinked across matching copies again in the final hardlink pass.

### 47 - OpenClaw cron installer

```dockerfile
COPY SCRIPTS/safrano9999/container/openclaw/openclaw_crontabs.sh /usr/local/bin/openclaw-crontabs
```

- **Instruction:** Copies the shared `openclaw_crontabs.sh` to `/usr/local/bin/openclaw-crontabs`.
- **Runtime caller:** `openclaw.service` runs it asynchronously after gateway startup.
- **Purpose:** Converts comma-separated CET entries from `OPENCLAW_CRONTABS` or `OPENCLAW_CRONTAB` into OpenClaw cron jobs for `agent:main:main`.
- **Event:** Each job emits `__safrano9999_webhooks__`, which the generated `WEBHOOK-RUNNER` handles.

### 48 - OpenClaw command-authorization helper

```dockerfile
COPY SCRIPTS/safrano9999/container/openclaw/openclaw_allow_all.mjs /usr/local/bin/openclaw-allow-all
```

- **Instruction:** Copies `openclaw_allow_all.mjs` to `/usr/local/bin/openclaw-allow-all`.
- **Purpose:** Repairs OpenClaw command authorization when cron registration initially fails.
- **Runtime caller:** `/usr/local/bin/openclaw-crontabs` retries cron creation after invoking it.
- **Path adjustment:** Step 50 changes its module URL from `/app/dist` to the global npm OpenClaw path.

### 49 - Recreate shared hardlinks inside the image

```dockerfile
RUN ln -f /opt/safrano9999/SCRIPTS/safrano9999/python_header.py /usr/local/bin/python_header.py \
 && ln -f /opt/safrano9999/SCRIPTS/safrano9999/optional_persistence.sh /usr/local/bin/optional_persistence.sh \
 && /opt/safrano9999/SCRIPTS/safrano9999/image/relink_shared.sh \
    --extra-root /usr/local/bin \
    --extra-root /etc/systemd/system \
    -- \
    config.sh python_header.py \
    openclaw-config.service openclaw.service openclaw_common.py \
    safrano9999_plugins.py tailscale-up.service tailscaled.service \
    cloudflared.service env.cloudflare.example config.cloudflare.conf_example config.cloudflare.container \
    sqlite_persistence.sh optional_persistence.sh \
    10-tailscale-ssh.conf 10-fedora-openai-v1.conf 20-safrano9999.conf
```

- **Instruction:** Hardlinks `python_header.py` directly into `/usr/local/bin`, then runs `relink_shared.sh` for all named SOT files.
- **Targets:** Matching files are relinked under `/opt/safrano9999`, `/usr/local/bin`, and `/etc/systemd/system`.
- **Files:** Includes `config.sh`, `python_header.py`, SQLite and optional persistence helpers, OpenClaw/Tailscale/Cloudflare units and drop-ins, `openclaw_common.py`, and `safrano9999_plugins.py`.
- **Invariant:** Deployed runtime binaries and systemd units share their inode with the SCRIPTS SOT, so in-container development changes the canonical implementation.

### 50 - Runtime path adjustment and executable modes

```dockerfile
RUN sed -i 's#file:///app/dist/#file:///usr/local/lib/node_modules/openclaw/dist/#' \
      /usr/local/bin/openclaw-allow-all \
 && chmod +x /usr/local/bin/openclaw-configure /usr/local/bin/hermes-configure-openai-v1 \
    /usr/local/bin/openclaw-safrano9999 \
    /usr/local/bin/openclaw-patch-models-command \
    /usr/local/bin/vikai-bootstrap-openclaw-agents \
    /usr/local/bin/optional_persistence.sh \
    /usr/local/bin/fedora44-ai-init \
    /usr/local/bin/openclaw-crontabs \
    /usr/local/bin/openclaw-allow-all \
    /usr/lib/systemd/system-generators/fedora44-runtime-environment-generator
```

- **Instruction:** Rewrites `/app/dist/` to `/usr/local/lib/node_modules/openclaw/dist/` in `openclaw-allow-all` and marks runtime programs executable.
- **Purpose:** Adapts the shared helper to the globally installed npm layout and guarantees systemd can execute all copied scripts.
- **Also covered:** The systemd runtime environment generator.

### 51 - Enable the runtime service graph

```dockerfile
RUN systemctl enable codeanalyst.service jugo.service citadel.service pvdach.service kiwix-bridge.service napoleon.service naturalgrounding.service \
    citadel-scan.service bip39.service spanker-webui.service fedora44-ai.service \
    tailscaled.service tailscale-up.service openclaw-config.service openclaw-safrano9999.service openclaw.service hermes.service \
    hermes-dashboard.service
```

- **Instruction:** Enables the selected application and infrastructure units after deployment, hardlinking, and mode adjustment are complete.
- **Enabled applications:** CODEANALYST, JUGO, CITADEL, PV_D-A-CH, KIWIX_BRIDGE, Napoleon, NaturalGrounding, BIP39, and SPANKER WebUI.
- **Enabled setup units:** CITADEL scan, Fedora initialization, Tailscale daemon/up, OpenClaw config/plugin/gateway, Hermes gateway, and Hermes dashboard.
- **KACHELMANN:** Not enabled directly; `openclaw-safrano9999.service` starts it after registering plugins.
- **Cloudflare:** Not enabled here. It remains conditional on `CLOUDFLARED_START` or CITADEL's runtime Cloudflare logic.

### 52 - systemd stop signal

```dockerfile
STOPSIGNAL SIGRTMIN+3
```

- **Instruction:** `STOPSIGNAL SIGRTMIN+3`.
- **Purpose:** Uses systemd's standard container shutdown signal instead of a generic process signal.
- **Result:** PID 1 performs an orderly unit shutdown when Podman stops the container.

### 53 - systemd as PID 1

```dockerfile
CMD ["/sbin/init"]
```

- **Instruction:** `CMD ["/sbin/init"]`.
- **Purpose:** Boots the enabled systemd service graph.
- **Container integration:** The generated Quadlet and Compose definitions also explicitly execute `/sbin/init` and inject `.env`, `config.conf`, and `container.conf`.
- **Published services:** Host mappings are generated from matching `<PREFIX>_PORT` and `<PREFIX>_PUBLISH_PORT` values; the `Containerfile` does not hard-code `EXPOSE` instructions.

## Runtime boot order summary

1. systemd's runtime generator imports the injected environment and optionally enables cloudflared.
2. `fedora44-ai.service` creates configured optional persistence paths and runs image-owned initialization scripts.
3. `tailscaled.service` and `tailscale-up.service` establish the optional in-container Tailscale node when `TS_AUTHKEY` is present.
4. Application WebUIs start from their individual units.
5. CITADEL starts its WebUI, then scans after dependent services become available.
6. `openclaw-config.service` writes OpenClaw configuration, followed by plugin registration in `openclaw-safrano9999.service` and the gateway in `openclaw.service`.
7. KACHELMANN WebUI starts after OpenClaw plugin registration.
8. Hermes configures its OpenAI-v1 provider, starts the gateway/API, and then starts its dashboard.
9. OpenClaw installs cron jobs and optionally runs `/usr/local/bin/safrano9999-fullrun` after the configured startup delay.
