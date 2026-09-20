# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM crystallang/crystal:1.21.0@sha256:32b7b908a8c3625ebd629053daf48b6f469deaf74aeb71ad101895096b1665fa AS build

ARG TINRELAY_BUILD_LABEL=development
WORKDIR /build

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
      busybox-static \
      libsodium-dev \
      libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY shard.yml shard.lock ./
RUN shards install --production --frozen

COPY src ./src
COPY sql ./sql
COPY templates/tinrelayd-help.txt ./templates/tinrelayd-help.txt
RUN TINRELAY_BUILD_LABEL="$TINRELAY_BUILD_LABEL" \
      shards build tinrelayd --release --no-debug --warnings=all --error-on-warnings \
    && strip bin/tinrelayd

COPY container/tinrelayd-entrypoint /build/tinrelayd-entrypoint
RUN set -eu; \
    mkdir -p \
      /runtime/bin \
      /runtime/etc \
      /runtime/usr/local/bin \
      /runtime/var/lib/tinrelay; \
    install -m 0555 /bin/busybox /runtime/bin/busybox; \
    install -m 0555 bin/tinrelayd /runtime/usr/local/bin/tinrelayd; \
    install -m 0555 /build/tinrelayd-entrypoint /runtime/usr/local/bin/tinrelayd-entrypoint; \
    ldd bin/tinrelayd \
      | awk '($3 ~ /^\//) { print $3 } ($1 ~ /^\//) { print $1 }' \
      | sort -u \
      > /tmp/runtime-libraries.txt; \
    while IFS= read -r library; do \
      cp --parents -L "$library" /runtime; \
    done < /tmp/runtime-libraries.txt; \
    rm /tmp/runtime-libraries.txt; \
    printf 'tinrelay:x:10001:10001:TinRelay:/var/lib/tinrelay:/bin/false\n' > /runtime/etc/passwd; \
    printf 'tinrelay:x:10001:\n' > /runtime/etc/group; \
    chown 10001:10001 /runtime/var/lib/tinrelay; \
    chmod 0700 /runtime/var/lib/tinrelay

FROM scratch

COPY --from=build /runtime/ /

WORKDIR /opt/tinrelay
EXPOSE 8787
STOPSIGNAL SIGTERM
ENTRYPOINT ["/bin/busybox", "sh", "/usr/local/bin/tinrelayd-entrypoint"]
CMD ["serve"]
