FROM golang:1.23-alpine AS builder

ARG TARGETARCH

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY . .

RUN if [ "${TARGETARCH}" = "amd64" ]; then \
      make dist-x86_64; \
    elif [ "${TARGETARCH}" = "arm64" ]; then \
      make dist-arm64; \
    else \
      echo "Unsupported architecture: ${TARGETARCH}" && exit 1; \
    fi

FROM alpine:3.20

# It's good practice to add ca-certificates for any potential HTTPS communication.
RUN apk add --no-cache ca-certificates

WORKDIR /opt

COPY --from=builder /app/extensions .

