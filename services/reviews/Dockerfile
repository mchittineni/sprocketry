# The build stage runs on the builder's own CPU and cross-compiles a static (musl) binary for the target
# one. TLS uses ring, which has C and assembly, so zig (through cargo-zigbuild) acts as the C cross
# compiler. Multi-arch builds need no emulation.
FROM --platform=$BUILDPLATFORM rust:1.99-slim-trixie AS build
ARG TARGETARCH
ARG ZIG_VERSION=0.15.1
ARG ZIG_SHA256_X86_64=c61c5da6edeea14ca51ecd5e4520c6f4189ef5250383db33d01848293bfafe05
ARG ZIG_SHA256_AARCH64=bb4a8d2ad735e7fba764c497ddf4243cb129fece4148da3222a7046d3f1f19fe
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && arch=$(uname -m) \
 && case "$arch" in x86_64) sha=$ZIG_SHA256_X86_64 ;; aarch64) sha=$ZIG_SHA256_AARCH64 ;; *) echo "unsupported build CPU $arch" >&2; exit 1 ;; esac \
 && curl -fsSLo /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
 && echo "$sha  /tmp/zig.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/zig.tar.xz -C /opt && rm /tmp/zig.tar.xz \
 && ln -s "/opt/zig-${arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
 && cargo install cargo-zigbuild --version 0.23.4 --locked \
 && rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl
WORKDIR /src

# Dependencies first, in their own layer, so source changes don't rebuild them.
COPY Cargo.toml Cargo.lock ./
RUN case "$TARGETARCH" in amd64) t=x86_64-unknown-linux-musl ;; arm64) t=aarch64-unknown-linux-musl ;; *) echo "unsupported arch $TARGETARCH" >&2; exit 1 ;; esac \
 && echo "$t" > /target \
 && mkdir src && echo 'fn main() {}' > src/main.rs && touch schema.sql \
 && cargo zigbuild --release --locked --target "$t" \
 && rm -rf src schema.sql

COPY schema.sql ./
COPY src ./src
# touch so cargo rebuilds the crate itself rather than reusing the placeholder from the step above.
RUN touch src/main.rs && cargo zigbuild --release --locked --target "$(cat /target)" \
 && cp "target/$(cat /target)/release/reviews" /reviews

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /reviews /reviews
EXPOSE 8080
ENTRYPOINT ["/reviews"]
