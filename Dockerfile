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
RUN  cd src/stub0 && zig build -p /out -freference-trace=8
##########

FROM scratch AS out
COPY --from=builder2 /out/img/ministub.efi /
COPY --from=builder2 /out/EFI/BOOT/BOOTx64.EFI /


