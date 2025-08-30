##########
FROM alpine:3.20 AS stub-builder
# Edge build seems to fail due to changes in gnu-efi-dev - it's the last build
# that seems to work.
RUN --mount=target=/var/lib/cache,id=apt,type=cache \
  apk add gnu-efi-dev musl-dev gcc binutils make 


##########
FROM alpine:edge AS builder-zig
# 3:20 has zig 0.12

RUN --mount=target=/var/lib/cache,id=apt,type=cache \
  apk add zig


##########
FROM stub-builder AS builder

COPY ./src ./src
COPY Makefile ./

RUN  make out=/out
##########
FROM builder-zig AS builder2

COPY ./src ./src
RUN  cd src/stub2 && zig build -p /out -freference-trace=8


##########

FROM scratch AS out
COPY --from=builder /out/boot/linux.efi.stub /usr/lib/efi-stub/
COPY --from=builder2 /out/img/ministub.efi /usr/lib/efi-stub/

