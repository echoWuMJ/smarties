# IBAMR eel2d 与 Smarties 耦合框架设计

## 1. 目标

在 Smarties 仓库中建立独立的 `couplings/ibamr/` 集成目录，以 IBAMR 0.18.0 的 `examples/ConstraintIB/eel2d` 为首个示范案例。第一阶段只证明耦合基础设施可靠：MPI 所有权唯一、进程拓扑明确、eel2d 能在 Smarties worker 中短时启动、正常退出，并能通过一个简单脚本在 node3 上构建和运行。

第一阶段不定义最终强化学习状态、动作和奖励，不接入 PyTorch、CUDA 或 pybind11，不进行长时间训练。

## 2. 已批准的原则

- 本地 Smarties Git 仓库是唯一代码源和版本存档。
- node3 只用于构建和运行；不允许存在只保存在 node3 的源代码修改。
- 新增耦合内容集中放入 `couplings/ibamr/`。
- Coupling Driver 是唯一 MPI owner。
- Smarties 和 IBAMR 都在同一 MPI job 内运行，不在 MPI 初始化后 `fork()`。
- 初期使用 Smarties 现有 CPU 神经网络实现。
- 未完整验证的日志和结论不进入 `experience/verified/`。

## 3. 目录结构

```text
couplings/ibamr/
├── CMakeLists.txt
├── README.md
├── core/
│   ├── MpiSession.h
│   ├── MpiSession.cpp
│   ├── CommunicatorLayout.h
│   ├── CommunicatorLayout.cpp
│   ├── CouplingDriver.h
│   └── CouplingDriver.cpp
├── cases/
│   └── eel2d/
│       ├── EelEnvironment.h
│       ├── EelEnvironment.cpp
│       ├── EelSmartiesAdapter.h
│       ├── EelSmartiesAdapter.cpp
│       ├── main.cpp
│       └── upstream/
│           ├── PROVENANCE.md
│           ├── IBEELKinematics.h
│           ├── IBEELKinematics.cpp
│           ├── eel2d.vertex
│           └── input2d.in
├── configs/
│   ├── fidelity/
│   │   ├── coarse.conf
│   │   ├── medium.conf
│   │   └── fine.conf
│   └── training/
│       └── smoke.json
├── scripts/
│   ├── package_local.ps1
│   ├── build_node3.sh
│   └── run_node3.sh
└── tests/
    ├── CMakeLists.txt
    ├── test_mpi_session.cpp
    ├── test_communicator_layout.cpp
    └── test_borrowed_engine_shutdown.cpp
```

`upstream/` 保存构建 eel2d 所需的、固定来源的 IBAMR 示例快照。`PROVENANCE.md` 记录 IBAMR 版本、原始路径、许可证和各文件 SHA-256。这样 node3 不依赖一份未归档的示例源码，同时不会修改本地 IBAMR 源树。

## 4. MPI 所有权与线程级别

### 4.1 Coupling Driver

`MpiSession` 在进程入口调用一次：

```cpp
MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided);
```

若 `provided < MPI_THREAD_SERIALIZED`，所有 ranks 输出一致的诊断并调用 `MPI_Abort`。正常路径中，`MpiSession` 在 Smarties、IBAMR、PETSc、SAMRAI 和 IBTK 全部销毁后调用一次 `MPI_Finalize()`。

### 4.2 Smarties borrowed-MPI

现有 `Engine(MPI_Comm world, int argc, char** argv)` 继续作为嵌入入口。修改 `ExecutionInfo`，增加不可歧义的 `bOwnMPI` 状态：

- 由 Smarties 自行初始化 MPI 的构造路径设置 `bOwnMPI=true`；
- 接收外部 communicator 的构造路径设置 `bOwnMPI=false`；
- 析构函数仅在 `bOwnMPI=true` 时调用 `MPI_Finalize()`；
- Smarties 只释放自己创建的派生 communicator，不释放调用者传入的 communicator；
- 现有独立 Smarties 应用行为保持不变。

该修改必须先通过 MPI ownership 单元测试，再用于 eel2d。

### 4.3 Rank 布局

一个 MPI job 包含 learner ranks 和 environment ranks。Smarties 继续负责其既有 worker/learner 分配算法；Coupling Driver 持有根 communicator，并把它以 borrowed 方式交给 Smarties。每个 eel2d 环境使用 Smarties callback 收到的 `environment_app_comm`。

只有 environment ranks 执行以下操作：

1. 将 `PETSC_COMM_WORLD` 设为 `environment_app_comm`；
2. 构造 `IBTKInit`；
3. 构造并运行 eel2d 环境；
4. 在 callback 返回前销毁 IBAMR、SAMRAI、IBTK 和 PETSc 对象。

Learner ranks 不初始化 CFD 栈。

## 5. 组件边界

### 5.1 `MpiSession`

只负责 MPI 初始化、线程级别验证和最终化。它不理解 Smarties、IBAMR 或训练参数。

### 5.2 `CommunicatorLayout`

提供 communicator、world rank、environment rank 和 environment size 的只读描述，并验证：

- communicator 不是 `MPI_COMM_NULL`；
- 所有 environment ranks 对 communicator 大小和成员关系达成一致；
- communicator 不会在 adapter 中被释放。

### 5.3 `CouplingDriver`

创建 `MpiSession`，再以根 communicator 构造 Smarties `Engine`，解析 Smarties 参数并调用 `Engine::run()`。它是进程入口和最终退出状态的唯一汇合点。

### 5.4 `EelEnvironment`

封装原始 eel2d 的对象创建、网格初始化、单步推进和销毁。第一阶段接口只包含：

```cpp
void initialize(MPI_Comm environment_comm, const std::string& input_file);
void advanceOneStep();
bool stepsRemaining() const;
void shutdown();
```

`initialize()` 和 `shutdown()` 必须可在短时 smoke test 中成对执行。强化学习观察和动作接口在后续设计中添加，不提前猜测。

### 5.5 `EelSmartiesAdapter`

负责 Smarties callback 边界。第一阶段只运行有限步数的生命周期探针，不把结果声明为训练。它验证：

- callback 获得的 communicator 可供 IBAMR 使用；
- eel2d 可以推进指定步数；
- callback 正常返回；
- Smarties 返回 Coupling Driver 后 MPI 仍处于 initialized 且未 finalized 状态。

为完整走通 Smarties 通信协议，生命周期探针固定声明一个 observation 和一个有界 action：observation 是归一化模拟时间，action 被读取但不施加到鱼体，reward 固定为零，并在配置的 smoke 步数后发送 terminal。该协议只用于测试通信与退出，输出不得解释为学习效果。

## 6. 配置与渐进网格

不在 C++ 中硬编码网格课程。三个 fidelity 配置定义：

| 名称 | `N` | `MAX_LEVELS` | `REF_RATIO` | 用途 |
|---|---:|---:|---:|---|
| coarse | 32 | 2 | 4 | MPI/生命周期和快速 smoke |
| medium | 64 | 3 | 4 | 与原始 eel2d 基线接近 |
| fine | 128 | 3 | 4 | 后续高保真验证，第一阶段不要求运行 |

`input2d.in` 是模板。`run_node3.sh` 为每个运行目录渲染独立的 `input2d`，不会修改仓库模板。

课程阶段复用 Smarties 原生参数：

```text
--appSettings <coarse>,<medium>,<fine>
--nStepPappSett <coarse_steps>,<medium_steps>,0
```

第一阶段 `smoke.json` 只规定少量步数和 CPU learner 参数，不作为正式训练配置。

## 7. 单入口启动脚本

node3 用户入口为：

```bash
./couplings/ibamr/scripts/run_node3.sh smoke \
  --envs 4 \
  --ranks-per-env 2 \
  --fidelity curriculum \
  --training couplings/ibamr/configs/training/smoke.json
```

脚本负责：

1. 验证 `SMARTIES_ROOT`、`IBAMR_ROOT`、MPI 和运行文件；
2. 计算所需 MPI ranks，拒绝不一致的参数；
3. 创建 `runs/<UTC timestamp>-<git revision>/`；
4. 复制并渲染本次使用的输入和训练配置；
5. 写入 `manifest.txt`，包含 Git revision、文件 SHA-256、主机、编译器、MPI、IBAMR、命令和 rank 拓扑；
6. 调用现有 Smarties launcher；
7. 保留退出码并将标准输出、标准错误和 MPI 日志写入运行目录。

`build_node3.sh` 单独负责增量构建。`run_node3.sh` 在可执行文件不存在或 revision 不匹配时调用它，因此日常使用仍然是一个命令。

第一阶段只实现 `smoke` 子命令。`train` 子命令保留为稳定的后续入口，但在真实 observation/action/reward 规格批准前必须明确报错退出，不能静默执行无意义训练。

## 8. 本地归档和 node3 同步

`package_local.ps1` 从本地 Git 工作树生成带 manifest 的源码包。包中包含：

- 当前 commit 和 dirty 状态；
- 所有已跟踪文件；
- 当前任务明确选择的未跟踪耦合文件；
- 每个打包文件的 SHA-256。

包不包含 `.git/`、`.codebase-memory/`、`.artifacts/`、构建目录或运行输出。

上传目标采用不可覆盖目录：

```text
/data2/mjwu/local/coupling-src/<UTC timestamp>-<revision>/
```

node3 构建和运行均指向该目录。禁止直接在 `/data2/mjwu/local/smarties` 上形成无法回传的唯一修改。若 node3 上为了诊断产生补丁，必须立即下载到本地 `.artifacts/ibamr-smarties-investigations/<issue-id>/`，在本地重放后才能继续。

运行日志下载到本地 `.artifacts/ibamr-smarties-investigations/<run-id>/`。它们不是已验证经验。

## 9. 错误处理与退出

- 参数、文件或 communicator 校验失败：所有相关 ranks 输出一致错误并协调退出；进入分布式运行后使用 `MPI_Abort`。
- eel2d 数值失败但进程仍可控：第一阶段报告失败并停止 smoke run，不尝试自动 reset。
- 不可恢复 MPI/IBAMR 错误：相关 communicator 上调用 `MPI_Abort`，任何子组件不得调用 `MPI_Finalize()`。
- 正常退出：eel2d 对象 → IBAMR/SAMRAI/IBTK/PETSc → Smarties worker → Smarties Engine → Coupling Driver → `MPI_Finalize()`。

## 10. 测试阶段

### 10.1 本地静态与无 IBAMR 测试

- CMake 配置结构检查；
- 配置渲染和参数校验测试；
- 打包清单测试；
- 不要求 Windows 本机构建 MPI/IBAMR 二进制。

### 10.2 node3 MPI 单元测试

1. borrowed Engine 析构后 `MPI_Finalized()` 返回 false；
2. owning Smarties 路径仍只 finalize 一次；
3. communicator 成员、大小和释放责任正确；
4. 两次连续 smoke 运行均干净退出。

### 10.3 node3 eel2d smoke

按顺序验证：

1. build/link；
2. coarse 单环境、单 environment rank；
3. coarse 单环境、两个 environment ranks；
4. coarse 两个并行环境；
5. medium 单环境；
6. 人工触发输入错误，确认协调退出；
7. 每个成功拓扑至少重复三次。

fine 配置和长训练不属于第一阶段完成条件。

## 11. 第一阶段完成条件

全部满足才算完成：

- 所有新增源码和脚本存在于本地 Git 分支；
- node3 使用本地归档包构建，不存在服务器独占修改；
- borrowed-MPI 自动测试通过；
- coarse 和 medium 规定拓扑通过并正常退出；
- 失败注入路径没有独立 `MPI_Finalize()` 或挂起；
- 重复测试结果、命令、版本和日志已回传本地 artifacts；
- 没有把 smoke 成功表述为强化学习控制已完成；
- 只有通过经验准入门槛的原子结论才进入 `experience/verified/`。

## 12. 后续阶段

完成基础框架后，再单独设计 eel2d 的控制问题：首个动作候选为尾摆幅值缩放，观察候选为质心速度、姿态、角速度、运动相位和水动力摘要，奖励候选为目标方向速度减去控制变化与能耗惩罚。这些只是后续设计输入，不是本规格批准的实现范围。
