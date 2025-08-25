
#################

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