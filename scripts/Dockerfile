# Stage 1: Base build environment
#FROM node:20-trixie-slim AS base
#WORKDIR /workspace
#COPY ./package.json ./yarn.lock ./
#RUN yarn

# Stage 2: Copy files and run build
#FROM base AS pre-build
#COPY ./*.ts ./tsconfig.json ./
#RUN echo "Intermediate image created before yarn build"

# Stage 3: Final build
#FROM pre-build AS final
#RUN yarn build
#ENTRYPOINT ["node", "index.js"]

FROM node:20-trixie-slim

WORKDIR /workspace

# 换 npm/yarn 源
RUN npm config set registry https://registry.npmmirror.com && \
    yarn config set registry https://registry.npmmirror.com

# 跳过 puppeteer 浏览器下载
ENV PUPPETEER_SKIP_DOWNLOAD=true

COPY ./package.json ./yarn.lock ./
RUN yarn --network-timeout 600000

COPY ./*.ts ./tsconfig.json ./

# 编译并显式检查 index.js 是否生成
RUN yarn build && test -f /workspace/index.js && ls -la /workspace

ENTRYPOINT ["node", "index.js"]
