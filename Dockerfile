FROM rust:1-alpine AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src src
RUN cargo build --release --locked

FROM alpine:3

# The program that captures the audio inside Android. droidtap copies it to
# the device for each recording. Version and checksum must change together.
ARG SCRCPY_VERSION=5.0.1
ARG SCRCPY_SERVER_SHA256=764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536
RUN wget -q -O /usr/local/share/scrcpy-server \
        "https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-server-v${SCRCPY_VERSION}" \
    && echo "${SCRCPY_SERVER_SHA256}  /usr/local/share/scrcpy-server" | sha256sum -c -

COPY --from=build /src/target/release/droidtap /usr/local/bin/droidtap

ENV SCRCPY_SERVER_PATH=/usr/local/share/scrcpy-server \
    SCRCPY_SERVER_VERSION=${SCRCPY_VERSION} \
    DROIDTAP_OUT=/recordings
VOLUME ["/recordings"]

ENTRYPOINT ["droidtap"]
