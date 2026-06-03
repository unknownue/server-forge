# Multi-stage build: compile Go binary then package in minimal alpine image.
# No Go installation needed on the host.

FROM golang:alpine AS builder

RUN apk add --no-cache git ca-certificates

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/cc-relay ./cmd/cc-relay

FROM alpine:3.23

RUN apk add --no-cache ca-certificates tzdata

COPY --from=builder /out/cc-relay /usr/local/bin/cc-relay

EXPOSE 8787 9090

ENTRYPOINT ["/usr/local/bin/cc-relay"]
CMD ["serve"]
