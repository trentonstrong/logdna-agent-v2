# syntax = docker/dockerfile:1.0-experimental
ARG BUILD_IMAGE
ARG TARGET_PLATFORM
ARG TARGET

# Target image to retrieve package metadata/gpg keys from
FROM --platform=${TARGET_PLATFORM} registry.access.redhat.com/ubi8/ubi-minimal:8.4 as target

FROM ${BUILD_IMAGE} as build

# TODO: move this bit into the build image
RUN apt update -y && apt install -y lld-12 gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
RUN rustup target add aarch64-unknown-linux-gnu

RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-12 100 && \
    update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-12 100 && \
    update-alternatives --install /usr/bin/ld.lld lld /usr/bin/ld.lld-12 100 && \
    update-alternatives --install /usr/bin/llvm-ar llvm-ar /usr/bin/llvm-ar-12 100

ARG TARGET_ARCH=x86_64
ARG ARCH_TRIPLE=x86_64-linux-gnu

# Set up UBI sysroot
COPY --from=target /etc/yum.repos.d/ubi.repo /sysroot/ubi8/etc/yum.repos.d/
COPY --from=target /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release /sysroot/ubi8/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release

RUN apt update -y && apt install -y yum yum-utils && \
    rpm --import /sysroot/ubi8/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release && \
    wget https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi8/8/${TARGET_ARCH}/baseos/os/Packages/r/redhat-release-8.5-0.8.el8.${TARGET_ARCH}.rpm && \
    rpm -i --nodeps --force --ignorearch --root=/sysroot/ubi8 redhat-release-8.5-0.8.el8.${TARGET_ARCH}.rpm && \
    mkdir -p /etc/pki/ && ln -s /sysroot/ubi8/etc/pki/rpm-gpg/ /etc/pki/

RUN sed -i "s/\$basearch/${TARGET_ARCH}/" /sysroot/ubi8/etc/yum.repos.d/ubi.repo
RUN mkdir /sysroot/ubi8/etc/yum && echo "[main]\nreposdir=/sysroot/ubi8/etc/yum.repos.d/" >> /sysroot/ubi8/etc/yum/yum.conf &&\
    mkdir -p /tmp/rpms && cd /tmp/rpms && \
    repotrack -c /sysroot/ubi8/etc/yum/yum.conf -a ${TARGET_ARCH} systemd-libs glibc-devel gcc-c++ libstdc++-static && \
    ls | xargs -n1 rpm -i --nodeps --noscripts --force --ignorearch --root=/sysroot/ubi8

# Add linker scripts so -lsystemd and -lgcc_s CFLAGS work as expected. This is
# tidier than a symlink
RUN echo "/* GNU ld script\n\
*/\n\
OUTPUT_FORMAT(elf64-$(echo ${TARGET_ARCH} | tr '_' '-' ))\n\
GROUP ( /lib64/libsystemd.so.0  AS_NEEDED ( /lib64/libsystemd.so.0 ) )" > /sysroot/ubi8/lib64/libsystemd.so

RUN echo "/* GNU ld script\n\
*/\n\
OUTPUT_FORMAT(elf64-$(echo ${TARGET_ARCH} | tr '_' '-' ))\n\
GROUP ( /lib64/libgcc_s.so.1  AS_NEEDED ( /lib64/libgcc_s.so.1 ) )" > /sysroot/ubi8/lib64/libgcc_s.so

ENV _RJEM_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"
ENV JEMALLOC_SYS_WITH_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"

ARG SCCACHE_BUCKET
ARG SCCACHE_REGION
ARG SCCACHE_ENDPOINT
ARG SCCACHE_SERVER_PORT=4226
ARG SCCACHE_RECACHE
ARG AWS_ACCESS_KEY_ID
ARG AWS_SECRET_ACCESS_KEY

ARG FEATURES

ARG TARGET
ARG TARGET_ENV_VAR_SUFFIX

ARG BUILD_ENVS

ARG RUSTFLAGS
ARG TARGET_CFLAGS
ARG TARGET_CXXFLAGS
ARG BINDGEN_EXTRA_CLANG_ARGS
ENV RUSTFLAGS=${RUSTFLAGS}
ENV TARGET_CFLAGS=${TARGET_CFLAGS}
ENV TARGET_CXXFLAGS=${TARGET_CXXFLAGS}
ENV BINDGEN_EXTRA_CLANG_ARGS=${BINDGEN_EXTRA_CLANG_ARGS}

ENV RUST_LOG=rustc_codegen_ssa::back::link=info

# Create the directory for agent repo
WORKDIR /opt/logdna-agent-v2

# Add the actual agent source files
COPY . .

RUN env
# Rebuild the agent
RUN --mount=type=secret,id=aws,target=/root/.aws/credentials \
    --mount=type=cache,target=/opt/rust/cargo/registry  \
    --mount=type=cache,target=/opt/logdna-agent-v2/target \
    set -x; \
    if [ -z "$SCCACHE_BUCKET" ]; then unset RUSTC_WRAPPER; fi; \
    if [ -n "${TARGET}" ]; then export TARGET_ARG="--target ${TARGET}"; fi; \
    export ${BUILD_ENVS?};  \
    if [ -z "$SCCACHE_ENDPOINT" ]; then unset SCCACHE_ENDPOINT; fi; \
    export CLANG_TARGET=${ARCH_TRIPLE}; \
    export CC_${TARGET_ENV_VAR_SUFFIX}="$PWD/scripts/clang-wrapper"; \
    export CXX_${TARGET_ENV_VAR_SUFFIX}="$PWD/scripts/clang++-wrapper"; \
    export CFLAGS_${TARGET_ENV_VAR_SUFFIX}="${TARGET_CFLAGS}"; \
    export CXXFLAGS_${TARGET_ENV_VAR_SUFFIX}="${TARGET_CXXFLAGS}"; \
    cargo build -vv --manifest-path bin/Cargo.toml --no-default-features ${FEATURES} --release $TARGET_ARG && \
    export status=$? && \
    find ./target/ -name "logdna-agent" && \
    ${ARCH_TRIPLE}-strip ./target/${TARGET}/release/logdna-agent; \
    cp ./target/${TARGET}/release/logdna-agent /logdna-agent ;\
    sccache --show-stats; \
    exit $status

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
