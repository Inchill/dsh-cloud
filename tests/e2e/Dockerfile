# e2e 用的干净基础镜像：只装 curl/sudo 等 bootstrap 自己不会装的东西，
# 其余（Node、gh、jq、dsh）都留给脚本，这样才是在测脚本。
ARG BASE=ubuntu:24.04
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git sudo tar xz-utils \
 && rm -rf /var/lib/apt/lists/*

# bootstrap 明确拒绝 root 运行，所以建一个能免密 sudo 的普通用户
RUN useradd -m -s /bin/bash agent \
 && printf 'agent ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/agent \
 && chmod 0440 /etc/sudoers.d/agent

USER agent
WORKDIR /home/agent

COPY --chown=agent:agent bootstrap.sh /home/agent/bootstrap.sh
COPY --chown=agent:agent tests/e2e/check.sh /home/agent/tests/e2e/check.sh
