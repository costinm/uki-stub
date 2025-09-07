##########
# Builder for Zig
# 3:20 has zig 0.12, need 0.14
FROM alpine:edge AS builder-zig

RUN --mount=target=/var/lib/cache,id=apt,type=cache \
  apk add zig

##########
FROM builder-zig AS builder2

COPY ./src ./src
RUN  cd src/stub2 && zig build -p /out -freference-trace=8
##########

FROM scratch AS out
COPY --from=builder2 /out/img/ministub.efi /

##########
# This image includes the unsigned stub as /usr/lib/efi-stub/ministub.efi
# 
# It also has the scripts to generate ESP images, using mounted volumes containing
# the kernel image and the rootfs image. 
FROM alpine:edge AS signer

COPY --from=busybox:musl /bin/busybox /initrd/bin/busybox
COPY --from=docker.io/jedisct1/minisign /usr/local/bin/minisign /initrd/bin/minisign

COPY ./signer/sbin/setup-signer /sbin/

RUN setup-signer add_signer

COPY ./signer/sbin /sbin
COPY ./signer/etc /etc
COPY ./signer/initrd /initrd/

VOLUME [ "/data" ]
VOLUME [ "/config" ]
VOLUME [ "/var/run/secrets"]

COPY --from=builder2 /out/img/ministub.efi /usr/lib/efi-stub/

ENTRYPOINT [ "/sbin/setup-efi" ]


