# 支持 4 台云服务器的 endorsement 实验编排脚本

## 变更概述

这个 PR 将 `experiments` 目录下的 endorsement 实验脚本，从原来的单机 Docker Compose 编排，改造成 4 台云服务器可用的版本。

目标部署模式为：

- 1 台主服务器运行 sequencer / Nitro 主节点
- 3 台背书服务器分别运行 endorser A / B / C

## 主要改动

- 新增 `experiments/cluster.env.example`，用于描述云服务器实验环境配置
- 修改 `write_case_config.py`
  - 支持从环境变量读取 endorser URL
  - 支持从环境变量读取 endorser 公钥
  - 支持从环境变量读取 `fail-to-address`
- 修改 `apply_case_config_to_volume.sh`
  - 不再依赖本地 Docker volume
  - 改为复制配置文件并重启目标服务
- 修改 `fault_injector.sh`
  - 不再通过 `docker stop` 或 `docker exec tc` 注入故障
  - 改为通过 SSH、systemd 和 `tc` 对远端节点执行故障注入
- 修改 `run_endorsement_tests.sh`
  - 不再依赖本地 `docker compose up`
  - 改为检查远端 RPC 和 health 状态
  - 改为通过 SSH 收集 sequencer 和 endorser 日志
  - 保留原有 matrix、workload、metrics 流程

## 改动原因

原有实验脚本默认基于以下前提：

- 所有服务运行在同一台机器的 Docker Compose 中
- 背书节点通过 `endorser-a`、`endorser-b`、`endorser-c` 这样的容器服务名访问
- 故障注入依赖本地 Docker 容器
- 日志采集依赖 `docker logs`

这些假设在 4 台云服务器部署环境下不再成立，因此需要对实验编排层做相应改造。

## 兼容性说明

本次改动主要替换的是编排方式，实验结构本身保持不变：

- 仍然使用 matrix 文件定义测试用例
- 仍然使用 `send_workload.sh` 发送 workload
- 仍然使用 `extract_metrics.py` 汇总指标
- 仍然保留 correctness、threshold、fault、performance 等实验组织方式

也就是说，核心实验流程没有变，变化的是底层环境依赖。

## 配套改动

这个 PR 需要配合 `endorsement` 仓库中的对应分支一起使用：

- `endorsement`: `feature/cloud-4node-experiments`

## 验证情况

- 更新后的 shell 脚本已通过 `bash -n` 语法检查
- `write_case_config.py` 已通过 Python 编译检查
- 提交时已避免把历史实验日志、结果文件、输出产物一并纳入版本控制
