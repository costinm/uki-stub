
FROM alpine:edge as stub-builder

RUN \
    --mount=target=/var/lib/cache,id=apt,type=cache \
    apk add gnu-efi-dev musl-dev gcc binutils make 


FROM stub-builder as builder

COPY ./src ./src
COPY Makefile ./

RUN \
    make out=/out

FROM scratch
COPY --from=builder /out/boot/linux.efi.stub /boot/
