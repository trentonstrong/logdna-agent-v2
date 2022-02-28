# syntax = docker/dockerfile:1.0-experimental
ARG BUILD_IMAGE
ARG TARGET_PLATFORM
ARG TARGET

#FROM --platform=${TARGET_PLATFORM} registry.access.redhat.com/ubi8/ubi-minimal:8.4 as target
FROM --platform=linux/amd64 registry.access.redhat.com/ubi8/ubi-minimal:8.4 as target
RUN ls /etc/yum.repos.d

FROM ${BUILD_IMAGE} as build

ARG TARGET_ARCH=x86_64

RUN apt update -y && apt install -y lld-12 gcc-aarch64-linux-gnu g++-aarch64-linux-gnu && ln -s /usr/bin/ld.ldd-12 /usr/bin/ld.ldd

COPY --from=target /etc/yum.repos.d/ubi.repo /sysroot/ubi8/etc/yum.repos.d/
COPY --from=target /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release /sysroot/ubi8/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release

RUN ls /sysroot/ubi8/etc/pki/
RUN apt update -y && apt install -y yum yum-utils && \
    rpm --import /sysroot/ubi8/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release && \
    wget https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi8/8/${TARGET_ARCH}/baseos/os/Packages/r/redhat-release-8.5-0.8.el8.${TARGET_ARCH}.rpm && \
    rpm -i --nodeps --force --ignorearch --root=/sysroot/ubi8 redhat-release-8.5-0.8.el8.${TARGET_ARCH}.rpm

RUN sed -i "s/\$basearch/${TARGET_ARCH}/" /sysroot/ubi8/etc/yum.repos.d/ubi.repo
RUN mkdir /sysroot/ubi8/etc/yum && echo "[main]\nreposdir=/sysroot/ubi8/etc/yum.repos.d/" >> /sysroot/ubi8/etc/yum/yum.conf

RUN mkdir -p /etc/pki/ && ln -s /sysroot/ubi8/etc/pki/rpm-gpg/ /etc/pki/

RUN mkdir -p /tmp/rpms && cd /tmp/rpms && \
    repotrack -c /sysroot/ubi8/etc/yum/yum.conf -a ${TARGET_ARCH} systemd-libs glibc-devel && \
    ls | xargs -n1 rpm -i --nodeps --noscripts --force --ignorearch --root=/sysroot/ubi8

# RUN echo ${TARGET_ARCH} > /etc/yum/vars/arch && \
#     echo ${TARGET_ARCH} > /etc/yum/vars/basearch && \
#     echo ignorearch=True >> /etc/yum/yum.conf
#
# RUN yum repolist -v --setopt=reposdir=/sysroot/ubi8/etc/yum.repos.d \
#     --setopt=install_weak_deps=False \
#     --installroot=/sysroot/ubi8
#
# RUN yum list available -v --setopt=reposdir=/sysroot/ubi8/etc/yum.repos.d \
#     --setopt=install_weak_deps=False \
#     --installroot=/sysroot/ubi8
#
# RUN yum install -v --setopt=reposdir=/sysroot/ubi8/etc/yum.repos.d \
#     --setopt=install_weak_deps=False \
#     --installroot=/sysroot/ubi8 -y \
#     systemd-libs.${TARGET_ARCH} liblzma gcrpyt
#
ENV _RJEM_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"
ENV JEMALLOC_SYS_WITH_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"

ARG FEATURES


ARG SCCACHE_BUCKET
ARG SCCACHE_REGION
ARG SCCACHE_ENDPOINT
ARG SCCACHE_SERVER_PORT=4226
ARG SCCACHE_RECACHE
ARG AWS_ACCESS_KEY_ID
ARG AWS_SECRET_ACCESS_KEY

ARG BUILD_ENVS

ARG TARGET

ARG RUSTFLAGS
ENV RUSTFLAGS=${RUSTFLAGS}

ENV RUST_LOG=rustc_codegen_ssa::back::link=info

RUN rustup target add aarch64-unknown-linux-gnu

# Create the directory for agent repo
WORKDIR /opt/logdna-agent-v2

# Add the actual agent source files
COPY . .

RUN env
# Rebuild the agent
RUN --mount=type=secret,id=aws,target=/root/.aws/credentials \
    --mount=type=cache,target=/opt/rust/cargo/registry  \
    --mount=type=cache,target=/opt/logdna-agent-v2/target \
    if [ -z "$SCCACHE_BUCKET" ]; then unset RUSTC_WRAPPER; fi; \
    if [ -n "${TARGET}" ]; then export TARGET_ARG="--target ${TARGET}"; fi; \
    export ${BUILD_ENVS?};  \
    if [ -z "$SCCACHE_ENDPOINT" ]; then unset SCCACHE_ENDPOINT; fi; \
    cargo build -v --manifest-path bin/Cargo.toml --no-default-features ${FEATURES} --release $TARGET_ARG && \
    find ./target/ -name "logdna-agent" && \
    strip ./target/${TARGET}/release/logdna-agent; \
    cp ./target/${TARGET}/release/logdna-agent /logdna-agent ;\
    sccache --show-stats

# Use Red Hat Universal Base Image Minimal as the final base image
FROM --platform=${TARGET_PLATFORM} registry.access.redhat.com/ubi8/ubi-minimal:8.4

ARG REPO
ARG BUILD_TIMESTAMP
ARG VCS_REF
ARG VCS_URL
ARG BUILD_VERSION

LABEL org.opencontainers.image.created="${BUILD_TIMESTAMP}"
LABEL org.opencontainers.image.authors="LogDNA <support@logdna.com>"
LABEL org.opencontainers.image.url="https://logdna.com"
LABEL org.opencontainers.image.documentation=""
LABEL org.opencontainers.image.source="${VCS_URL}"
LABEL org.opencontainers.image.version="${BUILD_VERSION}"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.vendor="LogDNA Inc."
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.ref.name=""
LABEL org.opencontainers.image.title="LogDNA Agent"
LABEL org.opencontainers.image.description="The blazingly fast, resource efficient log collection client"

ENV DEBIAN_FRONTEND=noninteractive
ENV _RJEM_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"
ENV JEMALLOC_SYS_WITH_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"

# Copy the agent binary from the build stage
COPY --from=build /logdna-agent /work/
WORKDIR /work/

RUN microdnf update -y \
    && microdnf install ca-certificates libcap shadow-utils -y \
    && rm -rf /var/cache/yum \
    && chmod -R 777 . \
    && setcap "cap_dac_read_search+eip" /work/logdna-agent \
    && groupadd -g 5000 logdna \
    && useradd -u 5000 -g logdna logdna

CMD ["./logdna-agent"]
