#FROM node:20-trixie-slim
#RUN apt-get update && \
#    apt-get install -y git docker.io python3 make gcc g++ curl jq
#ARG NITRO_CONTRACTS_BRANCH=main
#WORKDIR /workspace  
#RUN git clone --no-checkout https://github.com/OffchainLabs/nitro-contracts.git ./
#RUN git checkout ${NITRO_CONTRACTS_BRANCH}
#RUN git submodule update --init --recursive
#RUN yarn install && yarn cache clean
#RUN curl -L https://foundry.paradigm.xyz | bash
#ENV PATH="${PATH}:/root/.foundry/bin"
#RUN foundryup --install 1.0.0
#RUN touch scripts/config.ts
#RUN yarn build:all
#ENTRYPOINT ["yarn"]

FROM node:20-trixie-slim


RUN sed -i 's|http://deb.debian.org/debian|http://mirrors.tuna.tsinghua.edu.cn/debian|g' /etc/apt/sources.list.d/debian.sources && \
    sed -i 's|http://security.debian.org/debian-security|http://mirrors.tuna.tsinghua.edu.cn/debian-security|g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y git docker.io python3 make gcc g++ curl jq && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN npm config set registry https://registry.npmmirror.com && \
    yarn config set registry https://registry.npmmirror.com

COPY third_party/foundry/forge /usr/local/bin/forge
COPY third_party/foundry/cast /usr/local/bin/cast
COPY third_party/foundry/anvil /usr/local/bin/anvil
COPY third_party/foundry/chisel /usr/local/bin/chisel
RUN chmod +x /usr/local/bin/forge /usr/local/bin/cast /usr/local/bin/anvil /usr/local/bin/chisel

WORKDIR /workspace

COPY third_party/nitro-contracts/ /workspace/

RUN yarn install && yarn cache clean
RUN touch scripts/config.ts
RUN yarn build:all

ENTRYPOINT ["yarn"]
