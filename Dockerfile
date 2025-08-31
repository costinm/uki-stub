##########
# Builder for C + EFI library
# Edge build seems to fail due to changes in gnu-efi-dev - it's the last build
# that seems to work.
FROM alpine:3.20 AS stub-builder
RUN --mount=target=/var/lib/cache,id=apt,type=cache \
  apk add gnu-efi-dev musl-dev gcc binutils make 

##########
FROM stub-builder AS builder

COPY ./src ./src

RUN  (cd src/efi && make out=/out)

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
FROM alpine:edge AS signer

COPY ./signer/sbin/setup-signer /sbin/

RUN setup-signer add_builder

COPY ./signer/sbin /sbin
COPY ./signer/etc /etc

VOLUME [ "/data" ]
VOLUME [ "/config" ]
VOLUME [ "/var/run/secrets"]

# COPY --from=ghcr.io/costinm/uki-stub/uki-stub:latest /boot/linux.efi.stub \
#   /usr/lib/efi-stub/linux-efi.stub
COPY --from=uki-stub:latest /usr/lib/efi-stub \
  /usr/lib/efi-stub

ENTRYPOINT [ "/sbin/setup-efi" ]

##########

FROM scratch AS out
COPY --from=builder /out/boot/linux.efi.stub /usr/lib/efi-stub/
COPY --from=builder2 /out/img/ministub.efi /usr/lib/efi-stub/

