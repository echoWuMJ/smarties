# smarties API、运行环境与 IBAMR 鱼游耦合调研

> 调研日期：2026-08-03
> smarties 源码快照：`34c53d1ef03a324b20b418eaac6343ba44b6c966`（2021-03-01）
> 调研范围：本地 `smarties` 源码、构建配置、示例、语言绑定，以及 IBAMR 的 `ConstraintIB/eel2d` 鱼游案例。

## 1. 结论先行

1. smarties 暴露的主要接口不是 REST/RPC，而是一个进程内 C++ API：程序通过 `smarties::Engine` 启动，环境模拟函数通过回调获得 `smarties::Communicator*`，然后按照“发状态/奖励，收动作”的同步循环交互。
2. 对当前 IBAMR 鱼游任务，首选 **C++ 直接链接 + MPI 子通信器耦合**。smarties 负责划分 learner ranks 和 environment ranks；每组 environment ranks 在回调参数 `MPI_Comm mpicom` 上运行一套 IBAMR 模拟。
3. IBAMR 的 `IBTKInit` 构造函数本身接受 `MPI_Comm`，因此可以用 smarties 提供的环境子通信器初始化 PETSc、SAMRAI 和 IBAMR，避免 learner ranks 误入 IBAMR 集体通信。
4. `examples/ConstraintIB/eel2d` 已有理想的观测来源：质心、质心速度、线动量、角动量和水动力；控制入口应加在 `IBEELKinematics::setKinematicsVelocity()` 和/或 `setShape()`，让 RL 动作改变振幅、频率、相位或转向参数。
5. 第一阶段不要直接做多鱼、多环境和高维流场观测。建议先做 **单鱼、单策略、低维连续动作、低维全局观测、一个环境** 的端到端闭环，再并行多个环境收集经验。
6. smarties 仓库较旧，官方 README 的最低版本只代表历史要求。实际部署必须让 smarties 与 IBAMR 使用同一套编译器、MPI 和 BLAS/PETSc 依赖，并先做 ABI 与 MPI 线程级别验证。

## 2. 源码中的总体架构

```text
main
  └─ smarties::Engine
       ├─ parse()：解析运行资源、训练/评估和路径参数
       ├─ 划分 master/learner ranks 与 worker/environment ranks
       └─ run(app_main)
            └─ app_main(Communicator*, environment MPI_Comm, argc, argv)
                 ├─ 描述状态/动作空间
                 ├─ 初始化环境（这里是 IBAMR）
                 └─ episode loop
                      ├─ sendInitState(s0)
                      ├─ recvAction() -> a_t
                      ├─ IBAMR 推进到下一个控制时刻
                      ├─ sendState(s_{t+1}, r_t)
                      └─ sendTermState/sendLastState
```

关键源码：

- `source/smarties/Engine.h`、`source/smarties/Engine.cpp`：启动、解析和进程角色划分。
- `source/smarties/Communicator.h`、`source/smarties/Communicator.cpp`：环境公开 API。
- `source/smarties/Core/Worker.cpp`：状态/动作通信实现。
- `source/smarties/Core/StateAction.h`：MDP 描述，包括状态、动作、界限、离散动作和部分可观测性。
- `bin/smarties.py`：实验目录、资源配置、MPI 启动命令和环境变量的辅助脚本。
- `settings/*.json`：学习算法与超参数。

`Engine::run()` 根据资源配置选择 socket/fork 或 MPI 模式；worker 才执行环境回调。对于分布式 IBAMR，应走 MPI worker 模式并显式配置每个环境需要的 MPI rank 数。

## 3. `Engine`：程序级 API

### 3.1 构造与运行

公开构造函数：

```cpp
smarties::Engine(int argc, char** argv);
smarties::Engine(std::vector<std::string> args);        // Python 绑定使用
smarties::Engine(MPI_Comm initialized_comm, int argc, char** argv);
```

公开运行流程：

```cpp
smarties::Engine engine(argc, argv);
if (engine.parse()) return 1;
engine.run(app_main);
```

`run()` 支持四种回调签名：

```cpp
void app_main(smarties::Communicator*);
void app_main(smarties::Communicator*, int argc, char** argv);
void app_main(smarties::Communicator*, MPI_Comm app_comm);
void app_main(smarties::Communicator*, MPI_Comm app_comm, int argc, char** argv);
```

IBAMR 应使用最后一种，因为它同时需要环境子通信器和自己的输入文件参数。

如果 MPI 已由外层程序初始化，可使用接受 `MPI_Comm` 的 `Engine` 构造函数。源码会调用 `MPI_Query_thread()`，不会重复初始化 MPI。若由 smarties 作为最外层启动器，则使用普通构造函数即可。

### 3.2 资源和运行参数 setter

| API | 含义 |
|---|---|
| `setNthreads(n)` | learner 进程的 OpenMP 线程数 |
| `setNmasters(n)` | learner/master 进程数 |
| `setNenvironments(n)` | 并发环境数 |
| `setNworkersPerEnvironment(n)` | 每套环境模拟使用的 MPI ranks 数 |
| `setRandSeed(seed)` | 随机种子 |
| `setNumTrainingTimeSteps(n)` | 训练阶段收集的环境 transition 总数目标 |
| `setNumEvaluationEpisodes(n)` | 评估 episode 数；大于 0 时进入评估模式 |
| `setSimulationArgumentsFilePath(path)` | 环境参数文件路径 |
| `setSimulationSetupFolderPath(path)` | 环境 setup 目录 |
| `setRestartFolderPath(path)` | smarties checkpoint 目录 |
| `setIsLoggingAllData(flag)` | 是否记录全部状态、动作和奖励 |
| `setAreLearnersOnWorkers(flag)` | worker 是否也承载 learner 网络计算 |
| `setRedirectAppScreenOutput(flag)` | 是否重定向环境 stdout |

这些 setter 应在 `parse()` 后、`run()` 前调用；命令行与 setter 同时使用时，需在试验中确认最终覆盖顺序。

## 4. `Communicator`：环境公开 API

### 4.1 核心 RL 循环

| API | 使用时机 | 语义 |
|---|---|---|
| `sendInitState(state, agentID=0)` | episode 开始 | 发送初始状态，不带奖励 |
| `recvAction(agentID=0)` | 初始/普通状态之后 | 获取连续动作向量 |
| `recvDiscreteAction(agentID=0)` | 离散动作问题 | 获取离散动作标签 |
| `sendState(state, reward, agentID=0)` | 普通 transition | 发送下一个状态和上一步奖励 |
| `sendTermState(state, reward, agentID=0)` | 真正终止 | 策略导致成功/失败，终态价值按 0 处理 |
| `sendLastState(state, reward, agentID=0)` | 截断 | 仅因时间上限、外部重置等停止，最后状态价值不强制为 0 |

严格调用顺序：

```text
sendInitState(s0)
recvAction() -> a0
环境推进(a0)
sendState(s1, r0)
recvAction() -> a1
...
sendTermState(sT, rT-1) 或 sendLastState(sT, rT-1)
```

终态/截断态之后不能再调用 `recvAction()`，必须开始新 episode 并重新 `sendInitState()`。

### 4.2 问题定义 API

以下接口必须在第一次 `sendInitState()` 之前调用：

| API | 作用与约束 |
|---|---|
| `setNumAgents(n)` | 环境中的 agent 数量 |
| `setStateActionDims(dimState, dimAct, agentID)` | 指定状态和动作维度 |
| `setActionScales(upper, lower, bounded, agentID)` | 连续动作的缩放/边界；参数顺序是上界、下界 |
| `setActionOptions(nOptions, agentID)` | 一维离散动作选项数 |
| `setActionOptions(optionsPerDim, agentID)` | 多维离散选项，内部映射为标签 |
| `setStateObservable(mask, agentID)` | 隐藏部分状态分量；隐藏量仍可被日志记录 |
| `setStateScales(upper, lower, agentID)` | 给状态提供物理缩放范围 |
| `setIsPartiallyObservable(agentID)` | 声明 POMDP，促使 learner 使用循环网络 |
| `finalizeProblemDescription()` | 显式冻结问题描述；多线程环境应主动调用 |

连续控制时，动作向量长度必须等于 `dimAct`，上下界和 bound 向量长度也必须一致。离散控制使用 `setActionOptions()`，不要同时把同一 agent 当作连续动作问题配置。

### 4.3 多 agent 和分布式环境 API

| API | 作用 |
|---|---|
| `envHasDistributedAgents()` | 声明一个逻辑 agent 分布在多个环境 ranks 上 |
| `agentsDefineDifferentMDP()` | 不同 agent 训练不同策略；此前定义的公共描述会被复制 |
| `disableDataTrackingForAgents(begin, end)` | 指定一段 agent 的数据不进入训练 |
| `agentsShareExplorationNoise(agentID)` | 多 agent 共享探索噪声 |

注意：README 对 `envHasDistributedAgents()` 的说明存在明显文档错误，源码签名是 `void`，作用是设置分布式 agent 标志，并不返回训练/评估状态。训练/评估查询应使用 `isTraining()`。

对于一条鱼由多个 MPI ranks 协同求解、所有 ranks 执行同一个全局动作的 IBAMR 模拟，语义上对应 `envHasDistributedAgents()`。状态必须通过 IBAMR/SAMRAI 的归约得到全局一致值，动作也必须在环境子通信器内一致。

### 4.4 高级状态预处理

| API | 作用 |
|---|---|
| `setPreprocessingConv2d(...)` | 为图像类状态追加 Conv2D 预处理层，可多次调用 |
| `setNumAppendedPastObservations(n, agentID)` | 将过去 n 帧拼到当前状态，替代一部分 RNN 用途 |

首版 IBAMR 耦合不建议直接输入全流场或涡量图。先使用低维物理观测，待闭环和奖励设计稳定后再考虑降采样流场、POD 模态或局部传感器。

### 4.5 工具与监控 API

| API | 作用 |
|---|---|
| `getPRNG()` | 返回每个进程具有独立种子的 C++ PRNG |
| `getUniformRandom(begin,end)` | 均匀随机数 |
| `getNormalRandom(mean,stdev)` | 正态随机数 |
| `isTraining()` | 当前是否训练而非评估 |
| `terminateTraining()` | smarties 是否要求环境退出 |
| `getLearnersGradStepsNum(agentID)` | learner 已完成的梯度步数 |
| `getLearnersTrainingTimeStepsNum(agentID)` | 已收集的训练 transition 数 |
| `getLearnersAvgCumulativeReward(agentID)` | replay memory 中平均累计奖励；部分 on-policy 算法不支持 |

环境循环必须定期检查 `terminateTraining()`。CFD 单步很贵时，应在每个 RL 决策间隔内也检查一次，避免 smarties 已结束而 IBAMR 继续长时间推进。

### 4.6 无状态优化接口

`getOptimizationParameters()` 和 `setOptimizationEvaluation()` 用于零状态维度的函数优化，不适合有时间演化的鱼游控制闭环。

## 5. C++、Python、Fortran 暴露情况

### C++

C++ 是功能最完整、最适合 IBAMR 的接口。头文件为 `include/smarties.h`，实际包含 `Communicator.h` 与 `Engine.h`。

最小链接要求：

```text
include:  ${SMARTIES_ROOT}/include
library:  ${SMARTIES_ROOT}/lib
link:     smarties + MPI + OpenMP
standard: C++14
```

### Python

Python 模块由 `source/smarties/smarties_pybind11.cpp` 生成，基本用法与 C++ 相同：

```python
import smarties as rl

def app_main(comm):
    comm.setStateActionDims(dim_state, dim_action)
    comm.setActionScales(upper, lower, areBounds=True)
    # episode loop ...

engine = rl.Engine(sys.argv)
if engine.parse() == 0:
    engine.run(app_main)
```

Python 绑定只覆盖 C++ API 的一个子集，尤其不是所有高级 MPI、多 agent、finalize、PRNG 和优化接口都在绑定文件中出现。因此 Python 可用于原型或 Gym 类环境，不应作为 IBAMR 主耦合层。

### Fortran

`include/smarties.f90` 配合 `source/smarties/smarties_extern.cpp` 暴露 C ABI 包装，覆盖状态/动作发送、动作接收、维度、边界、可观测性等核心功能。仓库示例为 `apps/cart_pole_f90`。当前 IBAMR 是 C++，没有理由为本项目增加 Fortran 中间层。

### 原始 C ABI

`smarties_extern.cpp` 中虽有 `extern "C"` 风格入口，但仓库的稳定公共头主要面向 Fortran 模块；除非维护者决定冻结 ABI，否则不建议直接从 IBAMR 调用这些符号。

## 6. 构建和运行环境

### 6.1 仓库声明的历史最低要求

| 项目 | 仓库要求/实现 |
|---|---|
| 操作系统 | README 给出 Linux 和 macOS；没有原生 Windows 构建说明 |
| 编译器 | Linux GCC >= 6.1；必须支持 C++14 |
| CMake | `cmake_minimum_required(VERSION 3.2)` |
| MPI | 至少 `MPI_THREAD_SERIALIZED` 的线程安全实现 |
| OpenMP | 必需 |
| BLAS | 串行 BLAS，且具有 CBLAS 接口；示例使用 OpenBLAS |
| Python 绑定 | Python 3 + pybind11 |
| launcher Python 依赖 | `psutil`，以及标准库 `argparse/subprocess/...` |

仓库根 CMake 默认：Release、C++14、`COMPILE_PY_SO=ON`、动态库输出到 `${SMARTIES_ROOT}/lib`。CMake 直接 `add_subdirectory(source/extern/pybind11)`，所以必须完整拉取 git submodule。README 中“pip 安装 pybind11”的说法与当前 CMake 实际路径并不完全一致，应以源码构建结果为准。

### 6.2 面向 IBAMR 的实际约束

smarties 与 IBAMR 必须统一：

- C/C++ 编译器和 C++ ABI；
- MPI 实现与版本，不能一个链接 MPICH、另一个链接 OpenMPI；
- OpenMP runtime；
- BLAS 实现和线程设置；
- PETSc 所使用的 MPI；
- Debug/Release 和 `_GLIBCXX_USE_CXX11_ABI` 等关键编译选项。

建议在运行 IBAMR 的 Linux/HPC 环境中重新编译 smarties，而不是复制另一台机器生成的 `libsmarties.so`。

推荐环境变量：

```bash
export SMARTIES_ROOT=/absolute/path/to/smarties
export PATH="$SMARTIES_ROOT/bin:$PATH"
export LD_LIBRARY_PATH="$SMARTIES_ROOT/lib:$LD_LIBRARY_PATH"
export PYTHONPATH="$SMARTIES_ROOT/lib:$PYTHONPATH"   # 只有 Python 绑定需要
export OPENBLAS_NUM_THREADS=1
```

smarties 的 launcher 还会设置 `OMP_NUM_THREADS`、`MPICH_MAX_THREAD_SAFETY=multiple` 和关闭 MVAPICH affinity。实际集群上不要盲目复制，应按 MPI 实现和调度器调整绑核策略。

### 6.3 建议构建命令

```bash
cd "$SMARTIES_ROOT"
git submodule update --init --recursive
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=mpicc \
  -DCMAKE_CXX_COMPILER=mpicxx \
  -DCOMPILE_PY_SO=OFF
cmake --build build -j
```

对 IBAMR 耦合首版建议关闭 Python 模块，减少 pybind11/Python 版本变量。构建完成后应出现：

```text
${SMARTIES_ROOT}/lib/libsmarties.so
```

### 6.4 当前本地 Windows 工作区状态

当前检出的工作区没有 `lib/` 构建产物，并且本机 `python.exe` 无法正常启动；因此本轮只做了源码级调研，没有声称 smarties 已在本机编译或执行通过。真正的可运行验证应在 IBAMR 已能运行的 Linux/远程环境完成。

## 7. 启动器和资源模型

`bin/smarties.py` 的主要位置参数：

```text
smarties.py [application] [settings.json ...]
```

默认算法配置为 `settings/VRACER.json`。常用参数：

| 参数 | 含义 |
|---|---|
| `--runname/-r` | 运行目录名 |
| `--nThreads` | learner OpenMP 线程数 |
| `--nProcesses/-n` | MPI 总进程数 |
| `--nLearners/-l` | learner 进程数 |
| `--nEnvironments/-e` | 并发环境数 |
| `--mpiProcsPerEnv/-m` | 每个环境的 MPI ranks 数 |
| `--nTrainSteps` | 训练 transition 目标数 |
| `--nEvalEpisodes` | 评估 episode 数 |
| `--restart` | checkpoint 路径 |
| `--args` | 传给环境应用的参数 |
| `--disableDataLogging` | 禁用完整轨迹日志以节省 I/O |

分布式资源关系：

```text
MPI 总进程数 >= learner ranks + 环境数 × 每环境 ranks
```

例如 1 个 learner、2 套 IBAMR 环境、每套 16 ranks，至少需要 33 个 MPI ranks。

首个验证阶段建议不使用 `smarties.py` 的复制/setup 自动化，先直接构造 `Engine` 并用一个明确的 `mpirun` 命令跑通。确认进程拓扑后再接入运行目录管理脚本。

## 8. 学习算法和设置文件

`settings/default.json` 中的主要默认项包括：

- learner：VRACER；
- `gamma=0.995`、`lambda=0.95`；
- `learnrate=1e-4`；
- `batchSize=256`；
- 两层 128 单元 FFNN；
- replay memory 上限 262144，训练起始阈值 131072；
- `saveFreq=200000`。

支持的 learner 包括 VRACER、RACER、PPO、DPG、ACER、NAF、DQN、CMA 和 PYTORCH。鱼游连续控制首版可从 VRACER 开始，因为仓库默认配置和流体控制背景都围绕它构建；但这不是性能结论，最终应以小规模对照实验决定。

高成本 CFD 环境需要特别检查：

- `minTotObsNum` 不能大到必须先做无法承受的海量 CFD transition；
- `maxTotObsNum` 与磁盘/内存规模匹配；
- `obsPerStep` 控制每个观测对应的梯度步数；
- `saveFreq` 应显著降低，避免长时间计算后无 checkpoint；
- 关闭或抽样完整轨迹日志，减少并行文件系统压力。

## 9. 日志、checkpoint 与评估

重要输出：

- `agent_%02d_stats.txt`：训练统计；
- `agent_%02d_rank%02d_cumulative_rewards.dat`：episode 累计奖励；
- `agent_%02d_rank%02d_obs.raw`：完整状态/动作/奖励/策略日志；
- `agent_%02d_*_weights.raw`：网络权重；
- `agent_%02d_*_scaling.raw`：状态/奖励缩放；
- `out.log`、`gitlog.log`、`gitdiff.log`、`problem_size.log`。

评估必须使用 `--nEvalEpisodes N` 并从训练 checkpoint 重启。最好复制 checkpoint 到独立评估目录，避免覆盖训练文件。

IBAMR 自己还有 restart、VisIt、Silo、timer 和 postprocessing 文件。正式耦合时应把 smarties checkpoint 与 IBAMR episode restart 分开命名，并设置不同目录层级。

## 10. IBAMR `eel2d` 的可耦合位置

### 10.1 当前案例结构

`examples/ConstraintIB/eel2d/example.cpp`：

- 构造 `ConstraintIBMethod` 和 `IBExplicitHierarchyIntegrator`；
- 构造并注册 `IBEELKinematics`；
- 主循环中计算时间步、推进 hierarchy、更新质心/动量、水动力和输出；
- 可从 `ConstraintIBMethod` 获取结构状态。

`IBEELKinematics`：

- `setKinematicsVelocity(time, angle, center_of_mass, tagged_pt_position)` 更新运动学速度；
- `setShape(time, angle)` 更新鱼体形状；
- 当前波形主要由输入数据库和 muParser 表达式在构造时配置，没有面向控制器的运行时 setter。

因此需要为 `IBEELKinematics` 增加一个明确的控制参数入口，例如：

```cpp
struct EelControl
{
    double amplitude_scale;
    double frequency_scale;
    double phase_offset;
    double steering_bias;
};

void IBEELKinematics::setControl(const EelControl& control);
```

`setKinematicsVelocity()` / `setShape()` 在每个 CFD 时间步读取最近一次动作，并在动作边界内生成连续、平滑的运动学量。动作不应直接修改网格或速度场。

### 10.2 可用观测

源码已经提供：

- `ConstraintIBMethod::getCurrentStructureCOM()`；
- `ConstraintIBMethod::getCurrentCOMVelocity()`；
- `getStructureMomentum()`；
- `getStructureRotationalMomentum()`；
- `IBHydrodynamicForceEvaluator` 计算的水动力/力矩；
- 鱼体姿态、目标点相对位置、控制相位等案例内部量。

首版状态建议保持低维并做无量纲化：

```text
[目标相对位置 x/L, y/L,
 鱼体速度 u/Uref, v/Uref,
 航向误差 sin(theta_err), cos(theta_err),
 角速度 omega*L/Uref,
 当前摆动相位 sin(phi), cos(phi),
 上一动作]
```

如果目标只是最大化直游效率，可先去掉目标相对位置，只保留推进速度、横向漂移、姿态、相位和上一动作。

### 10.3 动作建议

按由易到难顺序：

1. 单维：尾摆振幅缩放；
2. 二维：振幅缩放 + 频率缩放；
3. 三至四维：再增加相位偏置/转向曲率；
4. 后续才考虑沿体长分段控制。

动作应通过 `setActionScales(upper, lower, true)` 限幅，并在相邻决策间做插值或一阶低通，避免运动学不连续导致 IBAMR 数值不稳定。

### 10.4 奖励建议

奖励必须与研究目标一致。可选原型：

```text
r = w_progress * 沿目标方向位移
  - w_lateral  * 横向偏移平方
  - w_heading  * 航向误差平方
  - w_power    * 无量纲机械功率
  - w_smooth   * 动作变化平方
```

若做推进效率，建议最终围绕单位能耗推进距离或 Froude efficiency 定义，而不是只奖励速度。奖励的每个物理量必须在一个控制区间上积分/平均，再送给 smarties。

## 11. 推荐的耦合控制流

下面是结构骨架，不是可直接编译的最终实现：

```cpp
#include "smarties.h"
#include <ibtk/IBTKInit.h>

void ibamr_environment(smarties::Communicator* const rl,
                       MPI_Comm env_comm,
                       int argc,
                       char** argv)
{
    // 所有 IBAMR/PETSc/SAMRAI 集体通信限定在本环境子通信器。
    IBTK::IBTKInit ibtk_init(argc, argv, env_comm);

    rl->envHasDistributedAgents();
    rl->setStateActionDims(DIM_STATE, DIM_ACTION);
    rl->setActionScales(action_upper, action_lower, true);
    rl->setStateScales(state_upper, state_lower);
    rl->finalizeProblemDescription();

    while (!rl->terminateTraining())
    {
        EelSimulation sim = build_fresh_eel_simulation(env_comm, argv);
        rl->sendInitState(sim.get_state());

        while (!rl->terminateTraining())
        {
            const auto action = rl->recvAction();
            sim.set_control(action);

            // 一个 RL 动作保持若干 CFD 步；区间内累积奖励。
            const StepResult result = sim.advance_to_next_decision();

            if (result.failed_or_succeeded)
            {
                rl->sendTermState(result.state, result.reward);
                break;
            }
            if (result.time_limit)
            {
                rl->sendLastState(result.state, result.reward);
                break;
            }
            rl->sendState(result.state, result.reward);
        }
    }
}

int main(int argc, char** argv)
{
    smarties::Engine engine(argc, argv);
    if (engine.parse()) return 1;
    engine.setNworkersPerEnvironment(RANKS_PER_IBAMR_ENV);
    engine.run(ibamr_environment);
    return 0;
}
```

关键点：

- 不要让 IBAMR 使用包含 learner ranks 的全局 `MPI_COMM_WORLD`；
- `IBTKInit` 使用回调传入的 `env_comm`；
- 每个环境组独立创建 IBAMR hierarchy 和输出目录；
- 全局观测在 `env_comm` 内归约后，所有 ranks 保持一致；
- 一个 RL 决策间隔可以包含多个 CFD 步，但必须固定或作为状态的一部分；
- time-limit 使用 `sendLastState()`，物理失败/成功使用 `sendTermState()`。

## 12. CMake 集成建议

在鱼游可执行程序目标上追加 smarties，示意如下：

```cmake
find_package(MPI REQUIRED)
find_package(OpenMP REQUIRED)

find_path(SMARTIES_INCLUDE_DIR smarties.h
          HINTS "$ENV{SMARTIES_ROOT}/include")
find_library(SMARTIES_LIBRARY smarties
             HINTS "$ENV{SMARTIES_ROOT}/lib")

target_include_directories(eel2d_rl PRIVATE "${SMARTIES_INCLUDE_DIR}")
target_link_libraries(eel2d_rl PRIVATE
    "${SMARTIES_LIBRARY}"
    MPI::MPI_CXX
    OpenMP::OpenMP_CXX)
```

真正接入 IBAMR 构建时，目标名称和现有 helper 宏需按案例 CMake 调整。配置阶段应输出 smarties 库的绝对路径，并通过 `ldd` 确认 smarties、IBAMR 和 PETSc 都解析到同一 MPI 实现。

## 13. 主要风险与验证顺序

### 高风险

1. **MPI 通信器污染或死锁**：任何 IBAMR/PETSc 集体操作误用全局 world 都会把 learner ranks 卷入。
2. **重复初始化/销毁 PETSc 与 IBTK**：一个进程内多 episode 应复用库级初始化，只重建 episode 级模拟对象。
3. **旧 smarties 与新工具链兼容性**：2021 年代码可能需要适配新 CMake、MPI、pybind11 或编译器告警。
4. **CFD 样本成本**：默认 replay memory 和训练起始阈值对 IBAMR 可能完全不可承受。
5. **episode 重置成本和确定性**：必须验证重建 hierarchy 后初态分布、随机种子和输出目录均正确。

### 建议验证阶梯

1. 在目标 Linux 环境只编译 smarties C++ 库和 `cart_pole_cpp`；
2. 运行 `cart_pole_distribEnv`，确认多 rank 环境拓扑；
3. 建立“不学习”的 IBAMR adapter，固定动作推进 2–3 个控制区间；
4. 接 smarties，但动作仍固定/回放，核对 state-reward-action 时序；
5. 单环境、短 episode、极小 replay memory 训练；
6. 加 checkpoint/重启和独立评估；
7. 最后增加并发环境数和更复杂动作空间。

每一级都记录：MPI rank 角色、通信器大小、状态维度、动作维度、每 episode 步数、控制间隔、累计奖励、墙钟时间和输出路径。

## 14. 下一阶段应产出的最小可验证原型

建议下一步实现一个独立 `eel2d_rl` 案例，而不是立即修改原始 `eel2d`：

1. 复制/封装 `eel2d` 初始化与一步推进逻辑为 `EelSimulation`；
2. 给 `IBEELKinematics` 增加受限、平滑的 `setControl()`；
3. 实现低维 `getState()`、区间奖励和终止判断；
4. 加入 smarties `Engine`/`Communicator` adapter；
5. 新增一份针对 CFD 成本调小的 learner JSON；
6. 提供单环境 smoke test 和 MPI 多环境启动脚本；
7. 将 IBAMR restart 与 smarties checkpoint 的重启语义分别测试。

## 15. 本调研的源码证据入口

smarties：

- `README.rst`
- `CMakeLists.txt`
- `install_dependencies.sh`
- `include/smarties.h`
- `include/smarties.f90`
- `source/smarties/Engine.h`
- `source/smarties/Engine.cpp`
- `source/smarties/Communicator.h`
- `source/smarties/Communicator.cpp`
- `source/smarties/smarties_pybind11.cpp`
- `source/smarties/smarties_extern.cpp`
- `source/smarties/Settings/ExecutionInfo.h`
- `source/smarties/Core/StateAction.h`
- `apps/cart_pole_cpp/cart-pole.cpp`
- `apps/cart_pole_distribEnv/cart-pole.cpp`
- `apps/cart_pole_distribAgent/cart-pole.cpp`
- `apps/cart_pole_py/exec.py`
- `bin/smarties.py`
- `settings/default.json`
- `settings/VRACER.json`

IBAMR：

- `examples/ConstraintIB/eel2d/example.cpp`
- `examples/ConstraintIB/eel2d/IBEELKinematics.h`
- `examples/ConstraintIB/eel2d/IBEELKinematics.cpp`
- `include/ibamr/ConstraintIBMethod.h`
- `ibtk/include/ibtk/IBTKInit.h`
