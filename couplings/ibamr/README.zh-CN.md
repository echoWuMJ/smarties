# Smarties-IBAMR 耦合安装与使用说明

近壁外部 episode 模式的成套保存、停止和续算入口见
[配对恢复说明](PAIRED_RESTART.zh-CN.md)。该模式使用 uv Python 3.12 管理独立 MPI
作业，网络仍使用原生 C++ CPU；下文早期单作业入口及其 Python 说明不适用于这个管理器。

本文从未编译源码开始，说明如何在 node3 上准备依赖、构建、启动和检查
Smarties-IBAMR 耦合。现成案例是基于 IBAMR 0.18.0 官方 eel2d 的持续物理时间线
频率控制；同一套 MPI 所有权和案例分层用于后续迁移到其他 IBAMR 案例。

当前基线使用 Smarties 原生 C++ CPU learner，不启用 Python binding、PyTorch 或
CUDA。`uv` 和 Python 3.12 可以作为服务器上的独立 Python 工具环境保留，但不
参与本耦合可执行文件的编译和运行。当前结论是“两个软件能够按既定协议共同
推进并更新原生网络”，不包含策略质量、奖励标定、收敛性或独立物理重置保证。

## 1. 获取指定版本

有网络时，在本地或 node3 克隆指定分支：

```bash
git clone --branch feature/ibamr-eel2d-coupling --single-branch \
  https://github.com/echoWuMJ/smarties.git
cd smarties
git rev-parse --short=12 HEAD
```

若 node3 不直接访问 GitHub，先在本地打包，再上传。打包脚本只纳入 Git 跟踪
文件，避免把本地未跟踪工作混入实验：

```powershell
cd C:\Users\wumj\Project\smarties
.\couplings\ibamr\scripts\package_local.ps1 `
  -Repository . `
  -OutputDirectory .artifacts\packages
```

将生成的 `.tar.gz` 上传到 node3，例如 `/data2/mjwu/local/coupling-src/`，然后：

```bash
mkdir -p /data2/mjwu/local/coupling-src/<snapshot>
tar -xzf smarties-ibamr-<timestamp>-<revision>.tar.gz \
  -C /data2/mjwu/local/coupling-src/<snapshot>
cd /data2/mjwu/local/coupling-src/<snapshot>
sha256sum -c SOURCE_MANIFEST.sha256
```

`<snapshot>` 可自行命名；构建目录必须与该不可变源码目录一一对应。

### 组件清单

| 组件 | 当前要求 | 用途 |
|---|---|---|
| GCC/G++ | 8.5.0 | 编译 Smarties、IBAMR 耦合和 overlay |
| Open MPI | 环境脚本提供，wrapper 必须指向 GCC/G++ 8.5.0 | 单作业内划分 learner 与 environment ranks |
| CMake | 能配置当前仓库及 IBAMR CMake package | 生成并构建 Release 目标 |
| IBAMR | 0.18.0 | 当前已验证 CFD 版本 |
| IBSAMRAI2 源码 | `IBSAMRAI2-2025.10.29` | 生成子通信器 overlay |
| PETSc | 3.23.3 | IBAMR 依赖；绑定到 environment communicator |
| Shell 工具 | Bash、patch、make、awk、sed、sha256sum | 构建、输入渲染、身份记录和启动 |
| uv/Python 3.12 | 可选，不进入当前二进制路径 | 供其它 Python 工具或后续独立工作使用 |

源码包、autoibamr 基础安装和上述工具齐全后，构建和运行不需要访问外网。

## 2. node3 前提环境

脚本会自行 `source` 以下环境，并在继续前核验版本：

```bash
source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
gcc -dumpfullversion -dumpversion   # 必须为 8.5.0
g++ -dumpfullversion -dumpversion   # 必须为 8.5.0
```

它还要求 MPI wrapper 对应 GCC/G++ 8.5.0，且基础 IBAMR 根目录为
`/data2/mjwu/autoibamr-v0.18.0/packages/IBAMR-0.18.0`。不符合时不要绕过
脚本检查；先修正 node3 环境。

## 3. 子通信器补丁如何应用

补丁文件是
`couplings/ibamr/patches/ibsamrai2-subcommunicator.patch`。它处理 IBSAMRAI2
中会错误使用 `MPI_COMM_WORLD` 的路径，使 IBAMR 环境子通信器可以安全运行。
它**不会**修改共享的 autoibamr 安装。

推荐只运行下面的脚本；它会将基础 SAMRAI/IBAMR 源码复制到隔离目录，在副本
中自动执行 `patch -p1`，再重编译并安装 overlay：

```bash
./couplings/ibamr/scripts/prepare_node3_ibamr.sh \
  --prefix /data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1
```

脚本以 `PATCHED_SMARTIES_SAMRAI.sha256` 记录补丁哈希；同一补丁且 overlay
完整时会复用，既不重复打补丁也不改基础安装。除非调试补丁本身，否则不要在
`/data2/mjwu/autoibamr-v0.18.0` 下手工执行 `patch`。

### 补丁为什么需要、什么时候需要

Smarties 会把一个 MPI 作业分为 learner ranks 与一个或多个 IBAMR environment
communicator。IBAMR 必须只在自己的环境子通信器内集体通信；否则 learner rank
不会参加 IBAMR 的集体/点对点通信，这会使通信缺少参与 rank 并产生卡死风险。

node3 所用 IBSAMRAI2 的若干网格聚类与通信路径把 `MPI_COMM_WORLD` 写死。补丁将
这些位置改为 `SAMRAI_MPI::getCommunicator()` 或对象当前的 communicator，例如
`BinaryTree.C`、`BoxComm.C`、`AsyncBergerRigoutsosNode.C` 和
`AsyncCommGroup.C`。因此它在“Smarties learner 与 IBAMR 环境共处同一个 MPI
job、且 IBAMR 只占其中一部分 ranks”时必须使用；普通单独 IBAMR 作业的所有
ranks 都在 `MPI_COMM_WORLD` 时不需要它。

除这个源码补丁外，`EelEnvironment` 还会在 IBTK 初始化前设定
`PETSC_COMM_WORLD = environment_comm`，并在 `IBTKInit` 后重新设定 SAMRAI
active communicator。这三层共同保证 PETSc、SAMRAI、IBTK 和 IBAMR 看见相同的
环境子通信器。

## 4. 编译

从源码快照根目录执行：

```bash
./couplings/ibamr/scripts/build_node3.sh \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot>
```

该脚本会准备 overlay，使用 GCC 8.5.0/CMake 编译 `ibamr_eel2d_smoke` 和
`libsmarties.so`，并写入 `build_manifest.txt`。`COMPILE_PY_SO=OFF` 是有意的：
当前耦合执行路径不需要 Python C++ binding。

默认并行编译任务数为 8，可在命令前设置 `BUILD_JOBS` 调整：

```bash
BUILD_JOBS=16 ./couplings/ibamr/scripts/build_node3.sh \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot>
```

`--ibamr-overlay DIR` 可指定另一份隔离 overlay；省略时使用
`/data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1`。先运行
`--dry-run` 可完成环境预检并打印将执行的配置和构建命令，不写构建产物。

这里没有对 Smarties 源码树执行全局 `make install`：编译产物固定放在
`--build` 指定目录中，其中实际启动程序为
`couplings/ibamr/ibamr_eel2d_smoke`，动态库为 `lib/libsmarties.so`。运行器会
核验它们与源码 revision 的对应关系；不匹配时自动调用同一源码快照的
`build_node3.sh` 重编译。

## 5. 启动一个耦合案例

先做最小生命周期 smoke，确认 MPI 拓扑、环境初始化和退出链：

```bash
./couplings/ibamr/scripts/run_node3.sh smoke \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot> \
  --envs 1 --ranks-per-env 1 --learner-ranks 1 --learner-threads 1 \
  --fidelity medium --smoke-steps 1
```

随后运行已验证过通信与原生 CPU learner 更新的 medium eel2d 诊断案例：

```bash
./couplings/ibamr/scripts/run_node3.sh train \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot> \
  --envs 1 --ranks-per-env 2 --learner-ranks 1 --learner-threads 2 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf \
  --train-updates 2 --end-time 10.0
```

这里总 MPI rank 数是 `learner-ranks + envs * ranks-per-env`，即上例为 3。
`--learner-threads 2` 只增加 Smarties CPU 网络计算的 OpenMP 线程；IBAMR 的
环境 MPI rank 仍由 `--ranks-per-env` 指定。不要同时给出 `--train-steps` 和
`--train-updates`。

若要执行一次低存储的长程 V-RACER 流程，可使用项目提供的长程配置。以下拓扑中
IBAMR 环境固定为 16 个 MPI ranks，另有 1 个 learner rank；`OMP_NUM_THREADS=1`，
因此本次作业共使用 17 个 MPI ranks，未超过 32 个线程的资源边界：

```bash
./couplings/ibamr/scripts/run_node3.sh train \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot> \
  --envs 1 --ranks-per-env 16 --learner-ranks 1 --learner-threads 1 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/eel2d_longrun.json \
  --task couplings/ibamr/configs/tasks/eel2d_longrun.conf \
  --train-updates 32 --end-time 20 --long-run-output
```

该配置用于完整流程与存储策略验收，奖励目标和权重仍是诊断值，不构成已标定的物理
最优策略。`--end-time` 是物理计算的安全上限；若先达到它，启动器会报告训练未正常
完成，而不会把截断计算伪装为收敛结果。

训练正常结束后，直接用同一个 IBAMR 耦合可执行文件加载最终 Agent。评估不是另一个
模拟程序；它仍执行相同的 `EelEnvironment`、`EelSmartiesAdapter` 和真实 CFD 时间推进，
只是 Smarties 冻结网络、使用策略均值生成动作，并且不写 replay、不执行优化器更新：

```bash
TRAIN_RUN=/data2/mjwu/local/coupling-src/<snapshot>/couplings/ibamr/runs/<train-run>

./couplings/ibamr/scripts/run_node3.sh eval \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot> \
  --envs 1 --ranks-per-env 16 --learner-ranks 1 --learner-threads 1 \
  --fidelity medium \
  --training "$TRAIN_RUN/settings.json" \
  --task "$TRAIN_RUN/task.conf" \
  --checkpoint "$TRAIN_RUN/learner-audit/final" \
  --eval-episodes 1 --end-time 20 --long-run-output
```

`--eval-episodes` 统计 Smarties 逻辑段；当前 continuing eel2d 在逻辑段之间保持同一条
物理轨迹，不重置网格、流场、鱼体、相位或物理时间。评估运行目录独立保存冻结输入、
`manifest.txt`、新的 `learner-audit/learner_audit.log`、CFD 初始/终态输出、退出码和
残留进程快照。审计日志应包含 `stage=restart`，不得包含 `stage=update`。正式评估当前
固定 `--envs 1`：适配器达到精确 episode 数后只完成 Smarties 终止握手，不再让 IBAMR
多推进一个控制区间。

### 启动参数

| 参数 | 默认值 | 含义 |
|---|---:|---|
| `smoke` / `train` / `eval` | 必填 | 生命周期检查、训练或 checkpoint 策略评估 |
| `--source DIR` | 当前仓库 | 源码快照；运行目录也创建在该目录下 |
| `--build DIR` | 按源码目录名派生 | 与源码 revision 匹配的构建目录 |
| `--envs N` | 1 | 同时运行的 IBAMR 环境数；eval 当前必须为 1，以保证精确 episode 边界 |
| `--ranks-per-env N` | 1 | 每个 IBAMR 环境使用的 MPI ranks |
| `--learner-ranks N` | 1 | Smarties master/learner ranks |
| `--learner-threads N` | 1 | 每个 learner rank 的原生 CPU/OpenMP 线程数 |
| `--fidelity LEVEL` | `medium` | 当前只接受 `medium` |
| `--training FILE` | 随模式选择 | Smarties JSON 网络与学习参数 |
| `--smoke-steps N` | 1 | smoke 模式推进的 IBAMR 步数 |
| `--task FILE` | train/eval 必填 | eel2d 状态、动作、奖励与控制周期配置 |
| `--train-steps N` | 1 | 启动数据之后的环境 transition 预算 |
| `--train-updates N` | 0 | 精确的原生优化器更新预算；大于 0 时替代 steps 预算 |
| `--checkpoint DIR` | eval 必填 | 包含网络权重和缩放数据的 `learner-audit/final` 目录 |
| `--eval-episodes N` | 1 | 冻结策略评估的 Smarties 逻辑段数 |
| `--end-time T` | 10.0 | IBAMR 正有限物理终止时间 |
| `--long-run-output` | 关闭 | train/eval 可用：关闭 Smarties 全样本记录，仅保留初始/终态 CFD 可视化快照及必要审计产物 |
| `--fault-after-initialize` | 关闭 | 仅用于验证初始化后的协调失败路径 |
| `--dry-run` | 关闭 | 预检并打印派生命令，不启动 MPI 作业 |

只要 `--learner-threads` 大于 1，当前脚本就使用
`mpiexec --bind-to core --map-by slot:PE=4`，即每个 MPI rank 预留 4 个处理单元；
这不是“每个 IBAMR rank 必须占满 4 核”。提交批处理任务时应按脚本实际绑定
预留 CPU，修改线程/绑定策略前先做拓扑检查。

### 任务配置参数

`couplings/ibamr/configs/tasks/speed_tracking.example.conf` 是完整模板。参数分为：

| 参数 | 含义 |
|---|---|
| `baseline_angular_frequency` | 官方基准尾拍角频率；当前 eel2d 为 6.28 |
| `minimum_frequency_ratio` / `maximum_frequency_ratio` | 动作 `[-1,1]` 映射后的频率比范围 |
| `maximum_ratio_delta` | 每个决策最多改变的频率比，限制突变 |
| `decisions_per_baseline_period` | 一个基准周期内的控制决策数 |
| `target_forward_speed` | 目标推进速度 |
| `forward_direction_x/y` | 由质心位移计算推进速度的投影方向 |
| `velocity_scale` | 状态和跟踪误差的速度归一化尺度 |
| `tracking_weight` | 速度跟踪平方误差权重 |
| `frequency_weight` | 偏离基准频率比 1 的平方惩罚权重 |
| `smoothness_weight` | 相邻频率比变化的平方惩罚权重 |
| `warmup_cycles` | 第一次受控决策前按基准频率推进的周期数 |
| `episode_decisions` | 一个 Smarties 逻辑段包含的决策数；不触发物理重置 |

控制区间为
`2*pi/(decisions_per_baseline_period*baseline_angular_frequency)`。模板和
`tests/fixtures/` 下任务文件只用于示范、协议或 learner 更新验证；开始正式训练
前必须在目标网格上标定推进方向、目标速度、归一化尺度和奖励权重。

### Smarties JSON 参数

`speed_tracking.json` 当前选择 `VRACER`，以 `nnLayerSizes` 设置全连接隐藏层，
`batchSize` 设置一次更新使用的样本数，`minTotObsNum` 设置开始学习前的最少观测，
`maxTotObsNum` 限制 replay memory 容量，`obsPerStep` 控制每个学习步采样的观测数，
`saveFreq` 按优化器更新次数设置常规 checkpoint 间隔。修改 JSON 不需要重新
编译；修改 C++ 状态/动作维度、运动库或 IBAMR 案例实现需要重新编译。

运行器为每次启动在 `couplings/ibamr/runs/` 创建独立目录，其中包括：

- `manifest.txt`：源码、可执行文件、库、overlay 补丁和启动拓扑的身份信息；
- `input2d`、`eel2d.vertex`、`settings.json`、`task.conf`：本次冻结输入；
- `stdout.log`、`exit_code.txt` 和 `processes-after.txt`：联合日志、退出码和作用域内
  残留进程快照；
- `learner-audit/initial`、`learner-audit/final` 及审计日志：显式 learner
  初始化/最终网络、优化器、缩放和 replay 状态；
- `agent_*_cumulative_rewards.dat`、`agent_*_obs.raw`：Smarties 默认
  `logAllSamples=1` 时保存的完整 episode 回报和 transition 原始记录；
- `Eel2dStr/`、`viz_eel2d_Str/`、`restart_IB2dStrDiv/` 和计时输出：由渲染后的
  IBAMR `input2d` 控制的结构、可视化、重启和性能数据。

默认输出配置适合短验证：结构输出间隔为 1、可视化间隔为 40、IBAMR restart
间隔为 150、timer 间隔为 100，且 Smarties 使用 `logAllSamples=1`。长程训练应
显式加 `--long-run-output`：它将 `logAllSamples` 设为 0，将结构输出和周期性
可视化间隔设为 `1000000000`，并关闭 restart/timer 输出。环境初始化保留初始
VisIt/Silo 快照；Smarties 正常结束后，环境在 MPI 和 IBAMR 仍存活时写出终态快照。
无论输出档位，都应保留 `manifest.txt`、冻结输入、联合日志、退出码、最终 learner
checkpoint 和复现实验所需的汇总指标。原始 observation、频繁可视化和高频 restart
只在确有诊断需求时启用。

正常的训练诊断结束应出现 `EEL_CONTROL_COMPLETE ... stopped_by=smarties`。
每条 `EEL_CONTROL` 还会记录 `lagrangian_points`；medium 既有验证实例为 2932。
若 IBAMR 先达到 `--end-time`，程序会发送最后一个截断状态后协调报错退出，而不
重建 eel 环境。这是为了避免把未定义的物理重置伪装成正常训练完成。

`--dry-run` 可以先检查环境、输入与派生 MPI 启动命令而不实际运行；把它追加到
上面任一完整的 `run_node3.sh` 命令末尾即可。

### 结果与报错判读

| 现象或信息 | 含义与处理边界 |
|---|---|
| `EEL_CONTROL_COMPLETE ... stopped_by=smarties` 且 `exit_code.txt` 为 0 | Smarties 先达到训练预算，环境完成正常逆序销毁 |
| eval 的审计含 `stage=restart`、不含 `stage=update`，且退出码为 0 | checkpoint 已由冻结策略加载并完成真实 IBAMR 评估 |
| `IBAMR end time reached before Smarties training termination` | 物理 `END_TIME` 小于训练所需时间；已发送截断 transition 后走协调失败路径 |
| `requires gcc/g++ 8.5.0`、`mpicc uses ...` | 未加载指定环境或 MPI wrapper 编译器不匹配 |
| `patched IBAMR overlay is incomplete` | overlay 未完成安装或使用了错误 prefix，重新运行 prepare/build 脚本 |
| `build identity does not match source revision` | 源码、可执行文件、动态库或 build manifest 不属于同一快照 |
| `non-finite eel state or reward` | 物理量、归一化或任务参数无效；不得将该 transition 当作训练样本继续 |
| `processes-after.txt` 非空 | 本次作用域仍有 MPI launcher、daemon 或案例进程，不能判为清理完成 |

`lagrangian_points` 在同一模型和输入下应保持不变。当前 medium 已验证值为 2932；
出现骤减时先检查 vertex 文件、输入复制和布局不变量，不得将模型点减少解释成
正常的背景网格粗化。

## 6. IBAMR 侧改造位置

官方 eel2d 基线及来源哈希在
`couplings/ibamr/cases/eel2d/upstream/PROVENANCE.md`。耦合版本没有通过删减或
重采样 `eel2d.vertex` 来适配网格：`EelEnvironment.*` 将官方示例的初始化和
时间推进封装为环境；`TailBeatPhase.*` 保证频率动作切换时相位连续；
`upstream/IBEELKinematics.*` 将原时间项替换为 `PHI`/`OMEGA`；
`EelSmartiesAdapter.*` 在控制安全点做状态、动作、奖励传递；`main.cpp` 仅将
模式交给唯一的 MPI 所有者 `CouplingDriver`。通用迁移流程见仓库 skill 的
`references/case-porting-playbook.md`，eel2d 公式和文件边界见
`references/eel2d-reference.md`。

### 多 MPI rank 环境必须声明分布式 agent

一个 IBAMR 环境由多个 MPI rank 共同推进时，案例 adapter 必须在第一次
`sendInitState()`、`sendState()` 或 `sendLastState()` 之前，由环境 communicator
中的所有 rank 调用：

```cpp
comm->envHasDistributedAgents();
comm->setStateActionDims(state_dimension, action_dimension);
comm->setActionScales(action_upper, action_lower, true);
```

该声明表示这些 rank 共同实现同一个 agent，而不是多个相互独立的环境。状态只由
环境根 rank 送给 learner；learner 返回的动作以及训练结束的 KILL 状态由环境根通过
`environment_app_comm` 广播给同组其余 rank。

eel2d 初次接入多 rank 环境时曾遗漏这次调用。遗漏后 Smarties 会让每个 IBAMR rank
各自参与状态/动作交换，无法保证所有 rank 接受同一个动作；集体推进可能因此发生
状态分歧或通信阻塞。补上调用只解决分布式 agent 的正常状态/动作语义；Smarties
master 的结束路径还必须只等待每个分布式环境的根 worker，不能等待非根 rank 再向
learner 发送状态。当前实现和 `distributed_environment_shutdown` 回归测试同时覆盖
这两项要求。

### 动作在何处插入，IBAMR 又在何处等待

真实控制循环位于 `cases/eel2d/EelSmartiesAdapter.cpp`。环境先通过
`comm->sendInitState(state)` 将当前 17 维状态交给 Smarties，然后执行：

```cpp
const std::vector<double> action = comm->recvAction(); // 在这里阻塞等待 learner
const ControlDecision decision = task.applyAction(action[0]);
environment.setTailBeatFrequencyRatio(decision.applied_ratio);
const ControlIntervalResult interval =
  environment.advanceControlInterval(task.controlInterval());
```

`recvAction()` 未返回时，IBAMR 没有后台时间推进线程，因而求解器停在上一个完整
控制区间结束后的安全点。动作返回后，`setTailBeatFrequencyRatio()` 以当前
`loop_time` 为生效时间交给 `IBEELKinematics`；随后 `advanceControlInterval()`
同步调用若干次 `IBExplicitHierarchyIntegrator::advanceHierarchy(dt)`，直到到达下
一个控制点。推进完成后才计算质心速度、state 与 reward，并用 `sendState()` 或
`sendLastState()` 交回 Smarties。也就是说，暂停/恢复是同步函数调用的自然结果，
不是暂停一个仍在后台运行的 IBAMR 线程。

当前动作只改变尾拍频率，不重采样 vertex 点，也不直接改流场：
`TailBeatPhase` 先保存动作时刻的相位，再更新角频率；`IBEELKinematics` 将
连续 `PHI` 和 `OMEGA` 注入原有的鱼形和变形速度解析器。

动作是一个标量，经 `[-1,1]` 裁剪、线性映射到配置的频率比区间，再经过
`maximum_ratio_delta` 限幅。状态为 17 维：前 5 维是归一化推进速度、归一化目标
速度、当前频率比、连续相位的正弦和余弦；后 12 维是 6 个随鱼体平移和转动的
探针处二维 Eulerian 流速，两个速度分量都除以 `velocity_scale`。

6 个探针在鱼体坐标系中的位置按下列顺序固定，长度单位为当前 eel2d 的鱼长：

```text
p0=(-0.35,+0.10)  p1=(-0.35,-0.10)
p2=( 0.00,+0.10)  p3=( 0.00,-0.10)
p4=(+0.35,+0.10)  p5=(+0.35,-0.10)
```

每个控制边界使用当前质心和体轴角把这些点旋转、平移到全局坐标，并从带完整
幽灵层的 side-centered 速度场用 IBTK `IB_4` 核采样。状态尾部顺序为
`p0_u,p0_v,...,p5_u,p5_v`。`EEL_PROBES` 日志保存每个点的全局坐标和未归一化
速度，便于核对观测。这里使用的是全局坐标系绝对流速，不是鱼体自身速度、相对
流速或鱼体坐标投影。

奖励仍等于速度跟踪平方惩罚、偏离基准频率平方惩罚和相邻动作平滑平方惩罚之和；
频率项不是功耗或推进效率的物理测量。加入探针后，旧的 5 维 Agent checkpoint
与新的 17 维网络输入不兼容；训练和评估必须使用同一版 17 维代码重新生成的
checkpoint。

## 7. 迁移到其他 IBAMR 版本

本仓库的脚本、补丁和 eel2d 代码只针对 node3 的 **IBAMR 0.18.0 + bundled
IBSAMRAI2-2025.10.29 + PETSc 3.23.3 + GCC 8.5.0** 验证。它们不是其他 IBAMR
版本的二进制兼容层；不能直接把本补丁应用到新版本后就假定正确。

迁移到其他版本时应：

1. 为新版本建立新的隔离 overlay，绝不复用或修改 0.18.0 overlay；
2. 检查新版本 SAMRAI 是否仍存在绕过 active communicator 的
   `MPI_COMM_WORLD` 调用；按新源码位置重写/缩小补丁，或确认上游已修复；
3. 适配 IBTK/IBAMR 初始化、`ConstraintIBKinematics`、构建包名和 CMake target
   的 API 差异；
4. 重新完成编译、子通信器拓扑、一次控制区间、正常退出和故障路径测试。

因此，通用的是 MPI 所有权和“安全控制点”架构；具体补丁和 IBAMR 案例封装必须
按目标版本重新验证。

## 8. 迁移到其他 IBAMR 案例

迁移应从目标 IBAMR 版本的官方案例复制数值设置和推进顺序，先保持无控制基线
可运行，再按以下边界拆分：

1. `CaseEnvironment` 只负责案例初始化、观测所需物理量提取、动作落点、完整控制
   区间推进、明确定义的 reset 和逆序销毁；
2. `CaseSmartiesAdapter` 只负责状态/动作维度、归一化、奖励、控制节拍、终止语义
   以及 `sendInitState`/`recvAction`/`sendState`/`sendLastState` 协议；多 rank 环境
   必须在首次协议交换前调用 `comm->envHasDistributedAgents()`；
3. `main.cpp` 只解析案例模式并调用 `CouplingDriver`，不得再次初始化或终结 MPI；
4. learner ranks 不创建 PETSc/SAMRAI/IBTK/IBAMR 对象，environment ranks 在初始化
   CFD 栈之前将 `PETSC_COMM_WORLD` 和 SAMRAI active communicator 绑定到各自环境；
5. 明确逻辑连续、部分物理 reset 或完整物理 reset，不能把 Smarties 段结束自动
   当作 IBAMR 已重建；
6. `recvAction()` 返回前不推进 IBAMR，动作只在完整时间步之间的安全点生效。

最低验证顺序是：构建和链接、rank/communicator 拓扑、一次动作区间、状态动作
奖励交换、声明的段边界或 reset、正常退出，以及该案例相关的协调失败路径。
只有这些检查通过，才能说新案例完成了耦合；策略质量和收敛性属于之后的任务
设计与训练阶段。

## 9. 当前已验证范围

有界 node3 验证使用 GCC 8.5、Open MPI 5.0.9、IBAMR 0.18、CPU Smarties、1 个
learner rank、1 个双 rank IBAMR 环境和 2 个 learner threads。medium 诊断运行
完成 2 个逻辑段、4 次动作决策和 5004 个 IBAMR 步，2932 个全局拉格朗日点保持
不变，发生 2 次有限的原生 CPU 网络更新，并完成最终 checkpoint 重载一致性
检查；另一个短 `END_TIME` 运行进入协调失败路径且未观察到 callback 重入。

以上范围证明当前拓扑下的耦合协议、持续推进和原生 learner 更新可以共同运行。
它不证明长时间训练重复性、两个 16-rank 环境、策略优势、任务收敛、物理 reset、
PyTorch/CUDA 或非 IBAMR 0.18 兼容性。
