FROM debian:bookworm-slim

ARG GODOT_VERSION=4.4.1
ARG GODOT_RELEASE=stable

ENV GODOT_VERSION=${GODOT_VERSION}
ENV GODOT_RELEASE=${GODOT_RELEASE}
ENV HOME=/tmp/godot-home
ENV XDG_DATA_HOME=/tmp/godot-data
ENV XDG_CONFIG_HOME=/tmp/godot-config
ENV XDG_CACHE_HOME=/tmp/godot-cache

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        inotify-tools \
        unzip \
        libasound2 \
        libdbus-1-3 \
        libfontconfig1 \
        libgl1 \
        libglu1-mesa \
        libudev1 \
        libxi6 \
        libxcursor1 \
        libxinerama1 \
        libxrandr2 \
        libxrender1 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    godot_base="Godot_v${GODOT_VERSION}-${GODOT_RELEASE}"; \
    godot_url="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-${GODOT_RELEASE}/${godot_base}_linux.x86_64.zip"; \
    templates_url="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-${GODOT_RELEASE}/${godot_base}_export_templates.tpz"; \
    curl -fsSL "${godot_url}" -o /tmp/godot.zip; \
    unzip -q /tmp/godot.zip -d /tmp/godot; \
    mv "/tmp/godot/${godot_base}_linux.x86_64" /usr/local/bin/godot-bin; \
    chmod +x /usr/local/bin/godot-bin; \
    curl -fsSL "${templates_url}" -o /tmp/export_templates.tpz; \
    unzip -q /tmp/export_templates.tpz -d /tmp/export_templates; \
    templates_dir="/opt/godot/export_templates/${GODOT_VERSION}.${GODOT_RELEASE}"; \
    mkdir -p "${templates_dir}"; \
    mv /tmp/export_templates/templates/* "${templates_dir}/"; \
    rm -rf /tmp/godot /tmp/godot.zip /tmp/export_templates /tmp/export_templates.tpz; \
    mkdir -p "${HOME}" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"; \
    chmod -R a+rX /opt/godot; \
    chmod -R a+rwX "${HOME}" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"

COPY tools/container/godot-wrapper /usr/local/bin/godot

RUN chmod +x /usr/local/bin/godot

WORKDIR /workspace

ENTRYPOINT ["godot"]
CMD ["--help"]
