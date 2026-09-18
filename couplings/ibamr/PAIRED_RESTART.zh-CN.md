# 近壁 eel2d：成套保存与续算

实现范围：Smarties 原生 CPU VRACER、单 learner、独立 CFD 作业、同机同构建恢复。
不包含 PyTorch，也不替代普通的“加载策略进行评估”。
验证结果见[实施与验收记录](../../docs/reports/2026-09-18-paired-restart-validation.zh-CN.md)；
验证范围不包含跨版本迁移或真实存储介质故障。

## 1. 编译与配置

本功能需要重新编译 **Smarties、耦合主程序和 CFD episode 程序**。只更新 Python
脚本或仅使用旧 `agent_*_weights.raw` 不够。无需修改或重新安装系统 IBAMR 库。
保留项目现有的案例侧 regrid 修复。

在已配置的 IBAMR/MPI/编译器环境中：

```bash
source /path/to/autoibamr/configuration/enable.sh
cmake -S /path/to/smarties -B /path/to/build \
  -DCMAKE_BUILD_TYPE=Release -DCOMPILE_PY_SO=OFF \
  -DBUILD_IBAMR_COUPLING=ON \
  -DIBAMR_DIR="$IBAMR_ROOT/lib64/cmake/ibamr"
cmake --build /path/to/build \
  --target ibamr_eel2d_smoke eel_near_wall_episode -j8
```

`COMPILE_PY_SO=OFF` 关闭 Python binding；Python 3.12 只运行非 MPI 管理器，
神经网络仍在 C++ 中。`IBAMR_DIR` 指向当前安装的 CMake 配置目录。
编译器、MPI 必须与 IBAMR 安装匹配，不能混用其他安装的 MPI wrapper。

复制并修改 [`configs/paired-node4.json`](configs/paired-node4.json)。其中路径是本次
node4 开发部署路径，迁移机器或重新部署时必须修改；它不是任意服务器通用路径。

| 配置项 | 含义 |
|---|---|
| `source`、`build` | 本次源码和匹配的构建目录，均为绝对路径 |
| `environment_script` | 启动前 source 的 IBAMR 环境脚本 |
| `python` | uv 管理的 Python 3.12 或 `.venv/bin/python` 的绝对路径 |
| `bin_paths`、`library_paths` | 需要优先使用的编译器/MPI 命令及动态库目录 |
| `environments`、`ranks` | 环境数、每环境 CFD MPI rank 数；乘积不得超过 32 |
| `threads` | learner 的 OpenMP 线程数，默认 8 |
| `steps` | Smarties 原有的累计训练样本预算；不是 CFD 步数，也不是网络更新次数 |
| `max_periods` | 每个物理回合最长持续的基准摆动周期数；原有终止条件仍生效 |
| `seed` | 初始高度种子的基础值；环境号与回合号参与生成各回合种子 |
| `checkpoint_minutes` | 墙钟保存请求间隔，默认 30 分钟 |
| `keep_checkpoints` | 全运行保留的完整批次数，默认 2，最少 2 |
| `settings`（可选） | 自定义 Smarties 参数 JSON；省略则复制 `configs/training/near_wall.json` |

`batchSize` 必须至少等于 learner 线程数，`minTotObsNum` 至少为 `batchSize`。
Smarties 预热依赖已结束的轨迹；仍在进行的 episode 不等于已满足预热条件。
恢复保留预热状态及原累计计数，不重新开始一份同样大的预算。

## 2. 三个命令

以下命令在源码根目录执行。运行目录必须使用绝对路径。

```bash
# 新建；拒绝覆盖已有目录。
bash couplings/ibamr/scripts/run_near_wall.sh start \
  --run /data/path/run01 --config /data/path/node4.json

# 请求成套保存，然后正常退出各 MPI 作业。
bash couplings/ibamr/scripts/run_near_wall.sh stop --run /data/path/run01

# 自动选择最新完整批次，恢复网络、活动轨迹和所有环境。
bash couplings/ibamr/scripts/run_near_wall.sh resume --run /data/path/run01
```

前台运行时，`Ctrl+C` 与 `stop` 相同。收到请求后，正在执行的动作区间需要先完成；
等待时间取决于 CFD 的推进速度，不以固定几秒超时判失败。不要同时向 CFD 或 learner
手工发送其他信号。断电、`kill -9` 等强制中断只能回到最近成功发布的快照。

新建时可覆盖保存频率和保留数：

```bash
bash couplings/ibamr/scripts/run_near_wall.sh start \
  --run /data/path/run02 --config /data/path/node4.json \
  --checkpoint-minutes 30 --keep-checkpoints 2
```

恢复读取 `run-config.json`，不再要求重新填写训练和资源参数。最新批次损坏时会明确
报错，不会悄悄重开鱼游；可以显式选择上一套：

```bash
bash couplings/ibamr/scripts/run_near_wall.sh resume \
  --run /data/path/run01 --checkpoint previous
```

已正常完成预算的目录含 `completed`，再次 `resume` 不启动新训练。同一个运行目录
只能有一个管理器，使用操作系统文件锁判断，不按旧 PID 文件杀进程。
若只强杀管理器而旧 MPI 作业仍活着，恢复会检查旧作业目录并拒绝重复启动；
需要先处理这些仍在运行的作业。断电后所有进程已消失时无需此步骤。
运行应放在持久终端（如 tmux）或服务器既有后台作业系统中；上述脚本本身前台运行。

配对模式达到训练预算后，停止启动新物理回合，请求一次最终成套保存，再正常退出；不会在其他环境
尚未暂停时直接关闭 learner。收尾期间仍需等待正在执行的 CFD 动作区间，因此累计
反馈或更新数可能略超过目标。若最终快照已发布，但断电发生在 `completed` 标记写入前，
恢复也会根据快照中的累计训练计数识别已完成预算，不再启动 MPI 作业。

## 3. 文件位置与磁盘占用

```text
run01/
  run-config.json                 # 保存的非敏感运行配置
  input2d / eel2d.vertex          # 初始 CFD 输入
  task.conf / settings.json      # 动作配置 / Smarties 参数
  checkpoints/
    snapshot-000001/
      manifest.json              # 对应关系、累计计数、完整成员清单及文件大小
      config/                    # 该快照使用的输入和参数副本
      learner/
        learner.native           # 网络、优化器、replay、归一化、计数和随机数状态
        learner.meta             # 可读累计计数；预热阶段单独标记
      env_1/                     # env_2 同样组织
        agent.state              # proxy 端 Agent、待用状态与随机数
        proxy.state              # 回合号、消息序号、待执行动作或下一回合状态
        cfd/
          adapter.state          # 动作历史、控制计数、探针缓存、初始高度
          environment.state      # CFD 时间步和案例历史
          samrai/restore.*/nodes.*/proc.*
    .writing-000002/              # 未发布；恢复时忽略
  sessions/
    session-000001/
      process.log                # learner/proxy 标准输出
      learner-audit/             # 原有网络更新审计输出；满足更新条件后产生
      env_1/episode_1/
        process.log              # 当前 CFD 作业标准输出
        cfd/                     # 当前 CFD、结构、transitions.csv 和可视化输出
      manager.exit.status        # 管理器退出状态，0 为正常
    session-000002/               # 恢复后输出，不覆盖旧 session
```

`kind=N` 表示“下一物理回合尚未开始”，该环境不需要 CFD dump；恢复后按保存的回合号
启动新进程。`kind=A` 才包含正在推进的 CFD 状态。

保存由管理器统一触发，配对模式下 `restart_dump_interval=0`，避免每个 CFD 作业
另行产生无限累积的周期 dump。**不是每次网络更新都写 CFD 文件**。
默认只保留全运行最近两套，写新一套时峰值约三套；新批次成功发布后才删除最旧批次。
快照实际大小随网格、结构和 replay 增长，不能按最初几步的大小估算整个训练。

保留数只限制 checkpoint，不清理 CSV、日志、可视化和旧 session。
字段可视化沿用现有策略：第一个物理回合保留周期输出，其余关闭周期输出。
失败的 `.writing-*` 保留供调查且不会用于恢复；反复写入失败时需排查空间和存储故障。
空间不足不会通过先删除已有完整快照腾空间。

## 4. 配对为何不会错一拍

1. CFD 完成当前动作区间，发送观测与奖励，然后阻塞等待下一动作。
2. proxy 将反馈交给 learner，并取得选好的下一动作，但暂不发给 CFD。
3. proxy 保存 Agent、序号及待执行动作；CFD 所有 rank 共同写原生 restart 和案例历史。
4. 全部 proxy 停住后，learner 在完整优化器更新之间保存，包含尚未结束的轨迹。
5. 所有文件成功写完，管理器同步文件/目录，再将临时目录原子发布为完整批次。
6. 恢复时，learner、proxy、CFD 全部就绪后才释放待执行动作；旧反馈不重复提交。

不同环境可以处于不同物理时间，配对的是明确的消息边界，不要求它们同时到达某个
CFD 步号。MPI 初始化/结束的所有权不变；管理器不是 MPI rank。

IBAMR 0.18 的原生 restart 未覆盖案例的全部历史。本实现额外恢复尾摆相位/频率、
动作限幅历史、进度原点、角速度历史及控制体移动余量；结构动量历史由 force evaluator
保存的 `P_current/L_current` 补回，避免重启后首段 Fx 奖励出现跳变。

## 5. 使用边界

- 支持本项目当前原生 VRACER、前馈网络、uniform replay 和单 learner 外部环境模式。
  其他算法、循环网络、worker learner、多 learner 或共享动作噪声会被拒绝。
- 使用相同构建、IBAMR/MPI 安装及原资源配置恢复；恢复前不要覆盖原构建。即使在相同路径重新编译，系统也不会自动检测 Git/依赖的语义兼容性；不承诺跨编译器或跨版本迁移。
- 状态、轨迹和累计计数续接，不承诺异步环境到达顺序或未来训练曲线逐位相同。
- 旧运行只有网络权重而没有 CFD restart 时，不能补出中途的配对恢复点。
- 文件同步及原子发布仍受文件系统和硬件的持久性保证限制，不能恢复已损坏的介质。
