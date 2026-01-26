FROM registry.fedoraproject.org/fedora:latest

RUN dnf install -y python3-configargparse python3-kubernetes

COPY llmd-xks-checks.py /root/llmd-xks-checks

ENTRYPOINT ["/root/llmd-xks-checks"]