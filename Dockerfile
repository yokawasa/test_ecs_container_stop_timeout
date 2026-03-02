# This container ignores SIGTERM and continues running.
# It will be forcibly terminated with SIGKILL after the stop timeout period.

FROM alpine:latest
CMD ["sh", "-c", "trap 'echo Received SIGTERM, ignoring...; sleep 1000' TERM; echo Started; sleep infinity"]
