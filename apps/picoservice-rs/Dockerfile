# Build binary
FROM rust:1-alpine3.22 as builder
WORKDIR /usr/src/picoservice-app
COPY . .
RUN apk add musl-dev && cargo build --release

# Minimal container for runtime
FROM alpine:3.22
WORKDIR /app
COPY --from=builder /usr/src/picoservice-app/target/release/picoservice .
EXPOSE 3000
CMD ["./picoservice"]