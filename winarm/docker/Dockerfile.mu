# Build container for Project Mu (mu_aloha_platforms). The repo is mounted
# at /build, not copied. Upstream's Dockerfile asks for python3.10 and
# python3-distutils, which Ubuntu 24.04 no longer ships.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i 's|http://archive.ubuntu.com|http://mirrors.tuna.tsinghua.edu.cn|g; s|http://security.ubuntu.com|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/ubuntu.sources
RUN apt-get update -y && apt-get -y install --no-install-recommends \
        uuid-dev clang llvm lld gcc-aarch64-linux-gnu build-essential \
        iasl nasm python3 python3-venv python3-pip python3-git git git-core \
        gettext locales gnupg ca-certificates curl mono-devel \
        device-tree-compiler xxd cpio \
    && rm -rf /var/lib/apt/lists/* && locale-gen en_US.UTF-8
ENV LANG=en_US.utf8
# nuget is not packaged for 24.04; stuart calls `nuget` through mono.
RUN curl -fsSL -o /usr/local/bin/nuget.exe https://dist.nuget.org/win-x86-commandline/latest/nuget.exe \
    && printf '#!/bin/sh\nexec mono /usr/local/bin/nuget.exe "$@"\n' > /usr/local/bin/nuget && chmod 755 /usr/local/bin/nuget
COPY pip-requirements.txt /tmp/pip-requirements.txt
RUN pip install --break-system-packages --upgrade -r /tmp/pip-requirements.txt \
    && git config --global --add safe.directory '*'
WORKDIR /build
CMD ["/bin/bash"]
