# Smarties–IBAMR 耦合项目技术报告

本文说明当前 `feature/ibamr-eel2d-coupling` 分支中 Smarties 与 IBAMR 0.18.0
耦合的代码结构、API、MPI 拓扑、安装流程、启动方法、输入输出和可调参数。文档以
eel2d 为已经实现的参考案例，但架构部分面向后续其他 IBAMR 案例的迁移。

当前基线使用 Smarties 原生 C++、V-RACER 和 CPU 神经网络。Python 由 `uv` 管理，
但 Python、pybind11、PyTorch 和 CUDA 都不在当前耦合可执行文件的运行链上。

当前已经实现的是：两个软件在同一个 MPI 作业中保持常驻，在每个控制时刻同步交换
状态、奖励和动作，IBAMR 在动作到达后继续推进，并能够保存、重新加载 Smarties
Agent。当前结论不等同于奖励已经物理标定、策略已经收敛或优于基准控制。

## 1. 项目全貌

一次标准的 16-rank eel2d 训练使用 17 个 MPI rank：

```text
mpiexec -n 17
│
├── world rank 0
│   └── Smarties master/learner
│       ├── V-RACER
│       ├── replay memory
│       ├── 原生 C++ 神经网络和优化器
│       └── checkpoint、训练统计和动作生成
│
└── world ranks 1..16
    └── 一个 16-rank IBAMR environment
        ├── environment rank 0：向 learner 发送状态并接收动作
        ├── environment ranks 1..15：参与 IBAMR/PETSc/SAMRAI 集体通信
        └── environment rank 0 将动作和结束信号广播给其他 15 个 rank
```

程序不是“每传一次动作就销毁并重启”。`ibamr_eel2d_smoke` 从启动到结束始终是同一
个 MPI 作业；IBAMR 网格、流场、鱼体和运动学对象也一直存活。程序只在完整控制区间
之间同步停在函数调用处等待 Smarties 完成动作交换，然后继续推进下一段 CFD 时间。

项目的主要目录如下：

```text
smarties/
├── source/smarties/                         Smarties 核心实现
├── include/smarties.h                       Smarties 公共头入口
├── couplings/ibamr/
│   ├── core/                                通用 MPI 所有权和耦合驱动
│   ├── cases/eel2d/                         eel2d 环境、adapter、控制任务
│   │   └── upstream/                        由官方 eel2d 派生的输入、几何和运动学
│   ├── configs/fidelity/                    网格档位
│   ├── configs/tasks/                       状态、动作、奖励和控制节拍
│   ├── configs/training/                    Smarties/V-RACER JSON 参数
│   ├── patches/                             SAMRAI 子通信器补丁
│   ├── scripts/                             安装、构建、输入渲染和启动脚本
│   ├── runs/                                每次运行的独立结果目录
│   └── TECHNICAL_REPORT.zh-CN.md             本报告
└── experience/verified/                     已验证且可复用的故障处理记录
```

## 2. 本项目使用的 Smarties API

### 2.1 顶层 Engine API

环境回调类型定义在 `source/smarties/Communicator.h`：

```cpp
using environment_callback_t =
  std::function<void(
    smarties::Communicator* smartiesCommunicator,
    MPI_Comm mpiCommunicator,
    int argc,
    char** argv)>;
```

四个参数的含义是：

| 参数 | 含义 |
|---|---|
| `smartiesCommunicator` | 环境向 Smarties 描述 MDP、发送状态/奖励和取得动作的接口 |
| `mpiCommunicator` | Smarties 为本环境划分的 `environment_app_comm`；IBAMR 只能在它里面通信 |
| `argc/argv` | Smarties 启动器传给环境案例的参数；当前包含 `--input-file`、`--eel-mode`、`--task-file` 等 |

`CouplingDriver::run()` 使用的是 Smarties 的“借用已有 MPI communicator”构造函数：

```cpp
smarties::Engine engine(mpi_.world(), argc_, argv_);
if (engine.parse()) return 2;
engine.run(callback);
```

这里实际用到三个顶层操作：

| API | 本项目用途 |
|---|---|
| `Engine(MPI_Comm, argc, argv)` | 借用 `CouplingDriver` 已初始化的 MPI；Smarties 不再初始化或终结 MPI |
| `Engine::parse()` | 读取 MPI 拓扑、训练预算、评估预算、checkpoint、线程数等命令行参数 |
| `Engine::run(callback)` | 划分 learner/environment communicator，并在环境 ranks 上执行 eel2d callback |

当前运行器通过命令行设置 Engine，而不是在 C++ 中逐个调用 `setNumThreads()`、
`setNumEnvironments()` 等 setter。这样资源和训练预算可以由启动脚本控制，无需每次
修改和重编译 C++。

### 2.2 Communicator API

eel2d 的真实控制路径在
`couplings/ibamr/cases/eel2d/EelSmartiesAdapter.cpp` 中使用以下接口：

| API | 调用时机 | 作用 |
|---|---|---|
| `envHasDistributedAgents()` | 第一次状态交换之前，所有环境 rank 调用 | 声明多个 MPI rank 共同实现同一个 agent；只有环境根与 master 交换状态，动作再在环境内广播 |
| `setStateActionDims(17, 1)` | 第一次状态交换之前 | 声明 17 维连续状态和一维动作 |
| `setActionScales({1.0}, {-1.0}, true)` | 第一次状态交换之前 | 声明动作范围为有界连续区间 `[-1, 1]` |
| `sendInitState(state)` | 每个 Smarties 逻辑段开始 | 发送初始状态，并在内部完成第一次状态/动作交换 |
| `sendState(state, reward)` | 非末尾 transition | 发送新状态及上一个动作产生的奖励，并在内部取得下一个动作 |
| `sendLastState(state, reward)` | 逻辑时间上限或 IBAMR 物理时间上限 | 发送“截断”状态；末态价值不被强制视为零 |
| `sendTermState(state, reward)` | 当前仅用于 lifecycle smoke | 发送真正终止状态；Smarties 按终止态处理其价值 |
| `recvAction()` | 紧跟在一次非终止 `send*State()` 之后 | 读取刚刚收到并缓存在 Agent 中的动作 |
| `terminateTraining()` | 循环边界和结束握手 | 检查 Smarties master 是否发来了 `KILL` |

一个容易误解的细节是：真正等待 learner 动作的阻塞过程发生在
`sendInitState()`/`sendState()` 调用的内部，而不是 `recvAction()` 内。源码中的
`Communicator::_sendState()` 会调用 `Worker::stepWorkerToMaster()`：环境根发送状态，
等待 master 的动作，再把动作广播到同一环境的其他 rank。随后 `recvAction()` 只是
返回已缓存的向量。

因此当前控制循环的准确顺序是：

```cpp
comm->sendInitState(state);             // 这里发送状态并等待第一条动作

while (...) {
  const auto action = comm->recvAction(); // 读取已经收到的动作
  const auto decision = task.applyAction(action[0]);
  environment.setTailBeatFrequencyRatio(decision.applied_ratio);
  const auto interval =
    environment.advanceControlInterval(task.controlInterval());

  state = task.makeState(...);
  const auto reward = task.reward(...);

  if (logical_segment_ends)
    comm->sendLastState(state, reward.total); // 发送 transition；没有下一动作
  else
    comm->sendState(state, reward.total);     // 发送 transition并等待下一动作
}
```

这是一条同步调用链。等待期间没有另一个后台线程偷偷推进 IBAMR；动作到达后，
IBAMR 才进入下一完整控制区间。

### 2.3 当前状态、动作和奖励

当前 Agent 的状态由 5 个运动/任务标量和 6 个局部流速探针组成，共 17 维：

```text
s[0] = forward_velocity / velocity_scale
s[1] = target_forward_speed / velocity_scale
s[2] = 当前已经应用的尾拍频率比
s[3] = sin(连续尾拍相位)
s[4] = cos(连续尾拍相位)
s[5 + 2*i] = probe[i].u / velocity_scale
s[6 + 2*i] = probe[i].v / velocity_scale, i=0,...,5
```

其中 `forward_velocity` 由一个控制区间起止时刻的鱼体质心位移计算：

```text
forward_velocity = dot(COM_end - COM_start, forward_direction)
                   / (time_end - time_start)
```

探针在鱼体坐标系中位于 `x/L=-0.35,0,+0.35` 三个纵向站位，每站分别取
`y/L=+0.10,-0.10`。`EelVelocityProbes` 根据当前质心和体轴角生成全局坐标；
`EelEnvironment::sampleVelocityProbes()` 将当前 side-centered 速度复制到具有 3 层
幽灵单元的专用变量，完成层间与边界填充，再用 IBTK `IB_4` 核逐点插值得到全局
`u,v`。逐点调用规避了 IBTK 0.18 多点 side-data 批量路径的段错误，同时所有环境
rank 仍按相同顺序参与每次集体采样。当前没有采样压力、涡量或速度梯度，也没有减去
鱼体速度或投影到鱼体坐标系。

新状态维数改变了网络输入层，因此旧 5 维 checkpoint 不能用于当前 17 维 adapter；
需要使用同一状态定义重新训练后再评估。

动作只有一个标量。Smarties 输出 `a in [-1, 1]` 后，`EelControlTask::applyAction()`
先裁剪，再线性映射到任务文件给出的频率比区间：

```text
target_ratio = min_ratio + 0.5 * (a + 1) * (max_ratio - min_ratio)
```

随后用 `maximum_ratio_delta` 限制一次决策能改变的最大频率比，最后才把
`applied_ratio` 写入运动学。

奖励为三个负的平方惩罚之和：

```text
r_tracking   = -tracking_weight
               * ((forward_velocity - target_forward_speed) / velocity_scale)^2
r_frequency  = -frequency_weight * (applied_ratio - 1)^2
r_smoothness = -smoothness_weight * (applied_ratio - previous_ratio)^2
r_total      = r_tracking + r_frequency + r_smoothness
```

当前奖励鼓励接近目标推进速度，同时抑制偏离基准频率和相邻动作突变。频率惩罚不是
真实功耗，当前 reward 也没有直接使用 `Drag_CV_strct_id_0`、压力功或推进效率。

## 3. IBAMR 侧的代码切入点

### 3.1 文件与职责

| 文件 | 切入点 | 新增作用 | 为什么有效 |
|---|---|---|---|
| `cases/eel2d/main.cpp` | 替换官方案例顶层 `main` | 只选择模式并进入 `CouplingDriver` | 防止 IBAMR 和 Smarties 各自重复管理 MPI |
| `core/MpiSession.cpp` | 整个程序最外层 | `MPI_Init_thread(MPI_THREAD_SERIALIZED)`，析构时唯一一次 `MPI_Finalize()` | MPI 生命周期只有一个所有者，避免两边来回初始化/终结 |
| `core/CouplingDriver.cpp` | `Engine` 构造与 callback 启动 | 把已经存在的 world communicator 借给 Smarties | Smarties 只划分派生 communicator，不拥有外部 MPI |
| `cases/eel2d/EelEnvironment.cpp` | 官方 eel2d 初始化与时间循环 | 把一次性 `main` 拆成 `initialize`、观测、应用动作、推进区间和 `shutdown` | adapter 可以在完整时间步之间插入控制，不改 CFD 积分器内部算法 |
| `cases/eel2d/EelVelocityProbes.cpp` | 每个控制边界的观测提取 | 定义 6 个鱼体随动点并生成其全局坐标 | 传感器位置随质心和朝向运动，同时不改拉格朗日鱼体离散 |
| `cases/eel2d/EelSmartiesAdapter.cpp` | 每个控制区间边界 | 定义 MDP、交换状态/动作、计算奖励、处理截断与结束 | 强化学习协议与 CFD 对象解耦，迁移其他案例时只需替换案例层 |
| `cases/eel2d/EelControlTask.cpp` | 动作映射与 reward | 裁剪、映射、变化率限制、状态和奖励 | 所有控制约束集中，避免任意动作直接破坏运动学 |
| `cases/eel2d/EelControlMeasurement.cpp` | 控制区间结束 | 从质心位移提取推进速度 | 只使用区间完整推进后的物理量，不读取半步状态 |
| `cases/eel2d/TailBeatPhase.cpp` | 运动频率变化时 | 保存动作时刻相位，再改变角频率 | 改频时相位连续，不会让鱼形瞬间跳变 |
| `cases/eel2d/upstream/IBEELKinematics.cpp` | 官方运动学解析器 | 新增 `PHI`、`OMEGA`，并提供频率比 setter | 仍沿用官方几何和 ConstraintIB 运动学路径，只替换相位演化速度 |
| `cases/eel2d/EelLogicalSegments.cpp` | Smarties episode 边界 | 把连续物理轨迹切成 replay 逻辑段 | 可以产生有界 trajectory，而不谎称流场已经重置 |

### 3.2 初始化时如何隔离 IBAMR communicator

`EelEnvironment::initialize()` 收到的不是 `MPI_COMM_WORLD`，而是 Smarties 为该
环境创建的 `environment_app_comm`。在任何 IBAMR 对象初始化前执行：

```cpp
environment_comm_ = environment_comm;
PETSC_COMM_WORLD = environment_comm_;
ibtk_init_.reset(new IBTKInit(argc_, argv_.data(), environment_comm_));
SAMRAI::tbox::SAMRAI_MPI::setCommunicator(environment_comm_);
```

这四步分别保证：

1. 案例保存自己的环境 communicator；
2. PETSc 对象和集体通信只看见环境 ranks；
3. IBTK 由同一个 communicator 初始化；
4. IBAMR 0.18 bundled SAMRAI 启动时会重置 active communicator，因此在
   `IBTKInit` 后立即恢复为环境 communicator。

随后构造 `AppInitializer`、Navier–Stokes integrator、`ConstraintIBMethod`、
`IBExplicitHierarchyIntegrator`、patch hierarchy、gridding algorithm、
`IBStandardInitializer`、运动学和水动力评估器。learner rank 从不构造这些对象。

### 3.3 动作插入的安全位置

动作只在一个控制区间开始、上一个 IBAMR 时间步已经完整结束时调用：

```cpp
environment.setTailBeatFrequencyRatio(decision.applied_ratio);
environment.advanceControlInterval(task.controlInterval());
```

`setTailBeatFrequencyRatio()` 把当前 `loop_time` 作为动作生效时间交给
`IBEELKinematics`。`advanceControlInterval()` 再循环调用官方时间推进顺序，直到
物理时间达到目标控制时刻：

```cpp
while (stepsRemaining() && loop_time_ < target_time) {
  advanceOneStep();
}
```

`advanceOneStep()` 保留了官方案例的关键次序：取得 `dt`、必要时重网格、更新控制体、
计算滞后动量积分、调用 `IBExplicitHierarchyIntegrator::advanceHierarchy(dt)`、更新
水动力量和质心，最后按输入配置输出数据。动作没有插进 PETSc 求解器或一个未完成的
时间步中，因此不会在一次集体通信中途让不同 rank 看到不同运动参数。

### 3.4 运动库如何接收频率动作

官方输入中的时间相位被改写为显式的 `PHI` 和 `OMEGA`：

```text
body_shape_equation =
  0.125*((X_0+0.03125)/1.03125)*sin(2*PI*X_0-PHI)

deformation_velocity =
  -0.125*OMEGA*((X_0+0.03125)/1.03125)
  *cos(2*PI*X_0-PHI)*N
```

每次运动学计算前：

```cpp
d_parser_phase = d_tail_beat_phase.valueAt(time);
d_parser_angular_frequency = d_tail_beat_phase.angularFrequency();
```

频率变化时先执行：

```cpp
anchor_phase_ = valueAt(effective_time);
anchor_time_ = effective_time;
ratio_ = ratio;
```

所以新频率从当前相位继续积分，而不是重新从零相位开始。`eel2d.vertex` 没有为了
网格档位或 MPI 传输而删点、抽稀或重采样；medium 案例已经记录的全局拉格朗日点数
为 2932，同一次运行中应保持不变。

### 3.5 逻辑段、物理终止和销毁

`episode_decisions` 只定义 Smarties replay 中一个逻辑段包含多少次决策。段尾使用
`sendLastState()`，但不会重建 patch hierarchy、流场、鱼体、物理时间或相位；下一
逻辑段继续同一条 CFD 时间线。

当 Smarties 达到训练/评估预算时，adapter 完成终止握手，写一次终态可视化，然后
按依赖逆序释放 IBAMR 对象，最后销毁 `IBTKInit`。只有 callback 返回、Smarties
释放派生 communicators 后，最外层 `MpiSession` 才执行唯一一次 `MPI_Finalize()`。

不可恢复的环境异常由所有环境 rank 收敛到 `MPI_Abort(environment_comm, 98)`；当前
没有定义“某一个 rank 抛错后独自返回并重建案例”的恢复协议。

## 4. 从空服务器安装完整环境

### 4.1 本节的服务器假设

以下命令按 node3 已验证目录编写，目标是让现有脚本无需改路径即可工作：

```text
/data2/mjwu/
├── Downloads/                              上传的源码压缩包
├── local/
│   ├── gcc-8.5.0/                          GCC/G++/GFortran 8.5.0
│   ├── openmpi/                            Open MPI 5.0.9
│   ├── uv/                                 uv 与 uv 管理的 Python
│   ├── coupling-src/smarties/              Git 工作树
│   ├── coupling-build/smarties/            耦合构建目录
│   └── coupling-deps/
│       └── ibamr-0.18.0-samrai-subcomm-v1/ 隔离的 patched IBAMR overlay
└── autoibamr-v0.18.0/                      基础 IBAMR 0.18.0 安装
```

这里的“空服务器”仍需是可登录的 x86_64 Linux，并允许安装基础构建工具。node3 的
已验证系统为 CentOS 7。其他发行版可使用等价软件包，但当前仓库脚本仍会严格要求
上述绝对路径和 GCC 8.5.0。

### 4.2 安装系统构建工具

CentOS/RHEL 系统可先安装：

```bash
sudo yum install -y \
  git unzip tar gzip bzip2 xz \
  make m4 patch gawk sed grep \
  autoconf automake libtool \
  gcc gcc-c++ gcc-gfortran \
  python3 perl wget curl \
  libtirpc-devel
```

这些系统编译器只用于引导构建 GCC 8.5.0；最终的 OpenMPI、AutoIBAMR 和耦合项目
必须统一使用 `/data2/mjwu/local/gcc-8.5.0`。

### 4.3 准备 GCC 8.5.0

把 `gcc-8.5.0.tar.xz` 以及 GCC 所需的 GMP、MPFR、MPC、ISL 源码上传到
`/data2/mjwu/Downloads/`。如果下载机器能访问 GCC 镜像，也可先在下载机器解压
GCC 并执行 `contrib/download_prerequisites`，然后把完整源码目录上传；不要在只能
访问国内网络的服务器上临时依赖该脚本联网。

源码齐全后执行：

```bash
mkdir -p /data2/mjwu/Downloads/src
cd /data2/mjwu/Downloads/src
tar -xf ../gcc-8.5.0.tar.xz

# 若上传的是完整依赖版源码，这一步应能离线完成或已经在下载机完成。
cd gcc-8.5.0
./contrib/download_prerequisites

mkdir -p /data2/mjwu/Downloads/build-gcc-8.5.0
cd /data2/mjwu/Downloads/build-gcc-8.5.0
../src/gcc-8.5.0/configure \
  --prefix=/data2/mjwu/local/gcc-8.5.0 \
  --enable-languages=c,c++,fortran \
  --disable-multilib

make -j8
make install
```

验证：

```bash
/data2/mjwu/local/gcc-8.5.0/bin/gcc -dumpfullversion -dumpversion
/data2/mjwu/local/gcc-8.5.0/bin/g++ -dumpfullversion -dumpversion
/data2/mjwu/local/gcc-8.5.0/bin/gfortran -dumpfullversion -dumpversion
```

三项都应输出 `8.5.0`。

### 4.4 准备 Open MPI 5.0.9

把 `openmpi-5.0.9.tar.gz` 上传到 `/data2/mjwu/Downloads/`，然后执行：

```bash
cd /data2/mjwu/Downloads/src
tar -xzf ../openmpi-5.0.9.tar.gz

mkdir -p /data2/mjwu/Downloads/build-openmpi-5.0.9
cd /data2/mjwu/Downloads/build-openmpi-5.0.9

../src/openmpi-5.0.9/configure \
  --prefix=/data2/mjwu/local/openmpi \
  CC=/data2/mjwu/local/gcc-8.5.0/bin/gcc \
  CXX=/data2/mjwu/local/gcc-8.5.0/bin/g++ \
  FC=/data2/mjwu/local/gcc-8.5.0/bin/gfortran \
  F77=/data2/mjwu/local/gcc-8.5.0/bin/gfortran \
  --enable-mpi-fortran

make -j8
make install
```

加载并验证 wrapper：

```bash
export PATH=/data2/mjwu/local/gcc-8.5.0/bin:/data2/mjwu/local/openmpi/bin:$PATH
export LD_LIBRARY_PATH=/data2/mjwu/local/gcc-8.5.0/lib64:/data2/mjwu/local/openmpi/lib:${LD_LIBRARY_PATH:-}

mpiexec --version
mpicc --showme:command
mpicxx --showme:command
mpif90 --showme:command
```

第一个命令应显示 Open MPI 5.0.9；后三个命令必须分别指向指定的 GCC、G++ 和
GFortran 8.5.0，不能混入系统编译器。

### 4.5 用 uv 安装 Python 3.12 环境

Python 不参与当前 C++ 耦合，但按项目约定由 uv 管理。把
`uv-x86_64-unknown-linux-musl.tar.gz` 上传到 `/data2/mjwu/Downloads/`：

```bash
mkdir -p /data2/mjwu/local/uv/bin
mkdir -p /data2/mjwu/Downloads/uv-unpack
tar -xzf /data2/mjwu/Downloads/uv-x86_64-unknown-linux-musl.tar.gz \
  -C /data2/mjwu/Downloads/uv-unpack

install -m 755 /data2/mjwu/Downloads/uv-unpack/uv-*/uv \
  /data2/mjwu/local/uv/bin/uv
install -m 755 /data2/mjwu/Downloads/uv-unpack/uv-*/uvx \
  /data2/mjwu/local/uv/bin/uvx

export UV_PYTHON_INSTALL_DIR=/data2/mjwu/local/uv/python
/data2/mjwu/local/uv/bin/uv python install 3.12 \
  --mirror https://registry.npmmirror.com/-/binary/python-build-standalone
```

此时只安装了 uv 管理的 Python 解释器；项目 `.venv` 会在取得 Smarties 源码后创建。

### 4.6 安装基础 AutoIBAMR 0.18.0

当前 overlay 构建脚本不仅需要已经安装的 IBAMR，还需要 AutoIBAMR 保留的两份
解压源码：

```text
/data2/mjwu/autoibamr-v0.18.0/tmp/unpack/IBSAMRAI2-2025.10.29
/data2/mjwu/autoibamr-v0.18.0/tmp/unpack/IBAMR-0.18.0
```

因此安装结束后不要删除 `tmp/unpack/`。

把支持 IBAMR 0.18.0 的 AutoIBAMR 源码包解压为
`/data2/mjwu/Downloads/autoibamr-0.18.0/`。node3 已验证安装使用的命令等价于：

```bash
cd /data2/mjwu/Downloads/autoibamr-0.18.0

export PATH=/data2/mjwu/local/gcc-8.5.0/bin:/data2/mjwu/local/openmpi/bin:$PATH
export LD_LIBRARY_PATH=/data2/mjwu/local/gcc-8.5.0/lib64:/data2/mjwu/local/openmpi/lib:${LD_LIBRARY_PATH:-}
export CC=/data2/mjwu/local/openmpi/bin/mpicc
export CXX=/data2/mjwu/local/openmpi/bin/mpicxx
export FC=/data2/mjwu/local/openmpi/bin/mpif90

SYSTEM_PY=$(command -v python3)

./autoibamr.sh \
  --prefix=/data2/mjwu/autoibamr-v0.18.0 \
  --ibamr-version=0.18.0 \
  --python-interpreter="$SYSTEM_PY" \
  --jobs=8 \
  --assume-yes
```

AutoIBAMR 的安装辅助脚本使用系统 Python 3；node3 已验证记录中是 Python 3.6。
Smarties 自己的 Python 工具环境仍严格使用上一节由 uv 管理的 Python 3.12。二者用途
不同，不要为了“统一版本”强行让旧 AutoIBAMR 安装脚本依赖 Python 3.12。

AutoIBAMR 会安装 CMake 3.30.6、HDF5 1.12.2、PETSc 3.23.3、Silo 4.11、
libMesh 1.7.8、IBSAMRAI2-2025.10.29 和 IBAMR 0.18.0。完成后验证：

```bash
source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh

test -f "$IBAMR_ROOT/lib64/cmake/ibamr/IBAMRConfig.cmake"
test -f /data2/mjwu/autoibamr-v0.18.0/tmp/unpack/IBSAMRAI2-2025.10.29/configure
test -f /data2/mjwu/autoibamr-v0.18.0/tmp/unpack/IBAMR-0.18.0/CMakeLists.txt

gcc -dumpfullversion -dumpversion
mpicc --showme:command
```

`enable.sh` 必须保留，并且 `gcc` 仍应为 8.5.0，`mpicc` 仍应由指定 GCC 支撑。

### 4.7 取得本项目源码

如果服务器能访问 GitHub：

```bash
mkdir -p /data2/mjwu/local/coupling-src
git clone \
  --branch feature/ibamr-eel2d-coupling \
  --single-branch \
  https://github.com/echoWuMJ/smarties.git \
  /data2/mjwu/local/coupling-src/smarties

cd /data2/mjwu/local/coupling-src/smarties
git status
```

如果服务器不能访问 GitHub，推荐用 Git bundle 保留分支和历史，而不是手工复制一个
无法继续版本管理的源码目录。在能访问 GitHub 的本地机器上执行：

```powershell
cd C:\Users\wumj\Project\smarties
git fetch origin
git bundle create D:\dataset_ib\smarties-ibamr.bundle `
  feature/ibamr-eel2d-coupling
scp D:\dataset_ib\smarties-ibamr.bundle mjwu@node3:/data2/mjwu/Downloads/
```

在服务器上执行：

```bash
mkdir -p /data2/mjwu/local/coupling-src
git clone \
  --branch feature/ibamr-eel2d-coupling \
  /data2/mjwu/Downloads/smarties-ibamr.bundle \
  /data2/mjwu/local/coupling-src/smarties

cd /data2/mjwu/local/coupling-src/smarties
git remote set-url origin https://github.com/echoWuMJ/smarties.git
git status
```

无论采用直接 clone 还是 Git bundle，源码就位后都在项目根目录创建 uv 环境：

```bash
cd /data2/mjwu/local/coupling-src/smarties
export UV_PYTHON_INSTALL_DIR=/data2/mjwu/local/uv/python

/data2/mjwu/local/uv/bin/uv venv --python 3.12 .venv
/data2/mjwu/local/uv/bin/uv pip install \
  --python .venv/bin/python \
  --index-url https://pypi.tuna.tsinghua.edu.cn/simple \
  psutil==5.9.8

.venv/bin/python --version
```

应得到 Python 3.12。当前 CMake 使用 `COMPILE_PY_SO=OFF`，因此没有 pybind11
扩展也不会阻止 Smarties–IBAMR C++ 耦合运行。

以后服务器有 GitHub 访问能力时可直接：

```bash
cd /data2/mjwu/local/coupling-src/smarties
git pull --ff-only origin feature/ibamr-eel2d-coupling
```

### 4.8 SAMRAI 补丁是什么、何时应用

补丁文件为：

```text
couplings/ibamr/patches/ibsamrai2-subcommunicator.patch
```

IBSAMRAI2-2025.10.29 的 `BinaryTree.C`、`BoxComm.C`、
`AsyncBergerRigoutsosNode.C` 和 `AsyncCommGroup.C` 中存在直接使用
`MPI_COMM_WORLD` 的通信路径。耦合作业的 world rank 0 是 learner，不参加
IBAMR 网格集体通信；若 SAMRAI 仍把消息发到 world communicator，会把环境局部
rank 当成 world rank，造成消息发错对象或死锁。

补丁把这些通信改为 SAMRAI 当前 active communicator。它只在“learner 和 IBAMR
共享一个 MPI job，IBAMR 只占 world 的子集”时需要；独立运行、所有 world ranks
都属于 IBAMR 的官方案例不需要该补丁。

不要把补丁直接打进共享 AutoIBAMR 安装。执行：

```bash
cd /data2/mjwu/local/coupling-src/smarties
chmod +x couplings/ibamr/scripts/*.sh

./couplings/ibamr/scripts/prepare_node3_ibamr.sh \
  --prefix /data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1
```

脚本会：

1. 读取 AutoIBAMR 保留的原始 SAMRAI 和 IBAMR 源码；
2. 把 SAMRAI 复制到隔离的 `coupling-deps` 目录；
3. 在副本上应用补丁；
4. 编译和安装 patched SAMRAI；
5. 重新编译 IBAMR 0.18.0，使其链接 patched SAMRAI；
6. 保持 `/data2/mjwu/autoibamr-v0.18.0` 不变。

正常使用时不必单独运行该命令，因为下一节的 `build_node3.sh` 会自动调用它；此处
列出是为了说明补丁发生在“基础 AutoIBAMR 完成之后、耦合程序编译之前”。

该补丁只针对 IBSAMRAI2-2025.10.29。更换 IBAMR/SAMRAI 版本时必须重新检查对应
源码：如果上游已经修复，就不应继续打旧补丁；如果调用位置发生变化，就要为新版本
建立另一份 overlay 和补丁，不能复用本目录的二进制安装。

### 4.9 编译耦合项目

执行：

```bash
cd /data2/mjwu/local/coupling-src/smarties

./couplings/ibamr/scripts/build_node3.sh \
  --source /data2/mjwu/local/coupling-src/smarties \
  --build /data2/mjwu/local/coupling-build/smarties
```

命令含义：

| 片段 | 含义 |
|---|---|
| `build_node3.sh` | 检查 node3 工具链、准备 patched overlay、配置并编译 |
| `--source DIR` | 指定当前 Git 工作树 |
| `--build DIR` | 指定与该工作树配套的 out-of-source 构建目录 |

该脚本使用的关键 CMake 设置是：

```text
CMAKE_BUILD_TYPE=Release
CMAKE_C_COMPILER=/data2/mjwu/local/gcc-8.5.0/bin/gcc
CMAKE_CXX_COMPILER=/data2/mjwu/local/gcc-8.5.0/bin/g++
COMPILE_PY_SO=OFF
BUILD_IBAMR_COUPLING=ON
BUILD_IBAMR_COUPLING_TESTS=ON
IBAMR_DIR=<patched overlay>/lib64/cmake/ibamr
```

默认并行编译数为 8，可按资源设置：

```bash
BUILD_JOBS=16 ./couplings/ibamr/scripts/build_node3.sh \
  --source /data2/mjwu/local/coupling-src/smarties \
  --build /data2/mjwu/local/coupling-build/smarties
```

主要产物为：

```text
/data2/mjwu/local/coupling-build/smarties/lib/libsmarties.so
/data2/mjwu/local/coupling-build/smarties/couplings/ibamr/ibamr_eel2d_smoke
/data2/mjwu/local/coupling-build/smarties/couplings/ibamr/smarties_cpu_learner_environment
```

第一个是 Smarties 动态库；第二个同时承担 eel2d smoke、训练和评估；第三个是纯
Smarties 合成环境验证程序，不是实际 IBAMR 案例。

## 5. 运行耦合案例

### 5.1 运行前检查

进入源码目录：

```bash
cd /data2/mjwu/local/coupling-src/smarties
source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
```

先用 `--dry-run` 检查路径、参数和派生 MPI 命令，不启动模拟：

```bash
./couplings/ibamr/scripts/run_node3.sh smoke \
  --source /data2/mjwu/local/coupling-src/smarties \
  --build /data2/mjwu/local/coupling-build/smarties \
  --envs 1 \
  --ranks-per-env 2 \
  --learner-ranks 1 \
  --learner-threads 1 \
  --fidelity medium \
  --smoke-steps 1 \
  --dry-run
```

如果构建与当前 Git 版本不匹配，正式运行时脚本会先调用 `build_node3.sh`。它不是在
每次运行都无条件重编译；只有构建缺失或与当前源码不一致时才构建。

### 5.2 最小生命周期 smoke

```bash
./couplings/ibamr/scripts/run_node3.sh smoke \
  --source /data2/mjwu/local/coupling-src/smarties \
  --build /data2/mjwu/local/coupling-build/smarties \
  --envs 1 \
  --ranks-per-env 2 \
  --learner-ranks 1 \
  --learner-threads 1 \
  --fidelity medium \
  --smoke-steps 1
```

该模式只验证真实 IBAMR 初始化、一个时间步、Smarties 状态/动作协议和正常退出；
动作维度会检查，但不会改变鱼的运动，reward 为零。它不是训练案例。

### 5.3 运行一条完整的 CPU V-RACER 训练链

以下命令使用一个 16-rank IBAMR 环境和一个单线程 learner rank，总 MPI rank 数为
17，IBAMR ranks 没有超过 32：

```bash
./couplings/ibamr/scripts/run_node3.sh train \
  --source /data2/mjwu/local/coupling-src/smarties \
  --build /data2/mjwu/local/coupling-build/smarties \
  --envs 1 \
  --ranks-per-env 16 \
  --learner-ranks 1 \
  --learner-threads 1 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/eel2d_longrun.json \
  --task couplings/ibamr/configs/tasks/eel2d_longrun.conf \
  --train-updates 32 \
  --end-time 20 \
  --long-run-output
```

各个非 IBAMR 原生命令参数的含义是：

| 参数 | 含义 |
|---|---|
| `train` | 进入真实的 17 维状态、一维频率动作和 V-RACER 更新路径 |
| `--envs 1` | 同时启动一个独立 IBAMR 环境 |
| `--ranks-per-env 16` | 该 IBAMR 环境内部使用 16 个 MPI rank |
| `--learner-ranks 1` | 使用一个 Smarties master/learner MPI rank |
| `--learner-threads 1` | learner rank 内的 OpenMP 线程数；不改变 IBAMR rank 数 |
| `--fidelity medium` | 使用 `N=64`、`MAX_LEVELS=3`、`REF_RATIO=4`；当前物理运行只允许此档 |
| `--training FILE` | 选择 Smarties 算法、网络、replay 和优化器 JSON |
| `--task FILE` | 选择动作映射、控制间隔、状态归一化和 reward 配置 |
| `--train-updates 32` | 初始 replay 数据收集完成后，精确执行 32 次额外优化器更新 |
| `--end-time 20` | IBAMR 物理时间安全上限；不是 Smarties 更新次数 |
| `--long-run-output` | 关闭全 transition 原始日志和周期性大规模 CFD 输出，只保留必要输入、日志、checkpoint 及初末场 |

`--train-steps N` 和 `--train-updates N` 只能二选一。前者按训练 transition 预算
结束，后者按优化器更新次数结束。若目的是确认网络确实完成固定数量更新，优先使用
`--train-updates`。

`--learner-threads` 大于 1 时，训练 JSON 中 `batchSize` 必须不小于线程数且能被线程
数整除。当前 `eel2d_longrun.json` 的 `batchSize=4`，所以最多直接设置 4；改成 8
线程前必须先把 JSON 中的 batch size 改为 8 或其倍数。

还应注意当前 `run_node3.sh` 在 `learner-threads>1` 时使用统一的
`--map-by slot:PE=4`，这个绑定会作用于整个 MPI 作业，而不是只作用于 learner rank。
它不能精确表达“learner 独占 8 核而每个 IBAMR rank 独占 1 核”。需要这种异构绑定
时应先改启动器的 rankfile/app-context 方案；仅把 `--learner-threads` 写成 8 不代表
Smarties 自动获得 8 个独占物理核。

### 5.4 用已有 Agent 驱动新的 eel2d 物理运行

训练结束后，最终 checkpoint 在训练 run 的 `learner-audit/final/`。先设置：

```bash
TRAIN_RUN=/data2/mjwu/local/coupling-src/smarties/couplings/ibamr/runs/<训练目录名>
```

执行冻结策略评估：

```bash
./couplings/ibamr/scripts/run_node3.sh eval \
  --source /data2/mjwu/local/coupling-src/smarties \
  --build /data2/mjwu/local/coupling-build/smarties \
  --envs 1 \
  --ranks-per-env 16 \
  --learner-ranks 1 \
  --learner-threads 1 \
  --fidelity medium \
  --training "$TRAIN_RUN/settings.json" \
  --task "$TRAIN_RUN/task.conf" \
  --checkpoint "$TRAIN_RUN/learner-audit/final" \
  --eval-episodes 40 \
  --end-time 10
```

这条命令没有加 `--long-run-output`，因此保留默认 IBAMR 结构、可视化、restart 和
timer 输出，适合需要完整查看 Agent 驱动效果的单次 10 s 运行。输出量会很大；如果
只想保留初态和终态，请加上 `--long-run-output`。

`eval` 仍使用同一个 `ibamr_eel2d_smoke` 二进制、同一个 `EelEnvironment` 和真实
CFD。Smarties 会加载权重与缩放数据、冻结优化器，并用策略进行动作选择。它不是
另外写的一套伪验证程序。

当前 eval 强制 `--envs 1`，以保证逻辑 episode 数精确。`--eval-episodes` 是
Smarties 逻辑段数；当前任务每段有 `episode_decisions` 次决策，段间仍延续同一条
物理时间线。

### 5.5 运行目录命名与文件分布

每次正式启动都会创建：

```text
couplings/ibamr/runs/eel2d-<UTC时间>-<Git短版本>-<启动进程号>/
```

例如：

```text
couplings/ibamr/runs/eel2d-20260824T082928Z-95834f4cad44-21851/
```

顶层文件和目录：

| 路径 | 产生者 | 用途 |
|---|---|---|
| `manifest.txt` | `run_node3.sh` | 本次模式、路径、资源拓扑、命令、输入和依赖版本 |
| `input2d` | 输入渲染脚本 | 从官方风格模板渲染出的本次 IBAMR 输入 |
| `eel2d.vertex` | 启动脚本 | 本次鱼体拉格朗日几何 |
| `settings.json` | 启动脚本 | 本次冻结的 Smarties JSON；learner 实际读取此文件 |
| `task.conf` | 启动脚本 | 本次冻结的控制任务；smoke 模式没有该文件 |
| `stdout.log` | 启动脚本 `tee` | 联合作业主日志，主要包含 Smarties master/learner 输出和运行器输出 |
| `exit_code.txt` | 启动脚本 | MPI 作业退出码；正常为 `0` |
| `processes-after.txt` | 启动脚本 | 结束后本次作用域内仍残留的进程；正常为空 |
| `problem_size.log` | Smarties learner | 状态维度、动作维度和策略向量维度 |
| `agent_00_*.raw` | Smarties 常规保存 | 当前/周期性网络、优化器、replay 和缩放数据；是否出现取决于保存时机 |
| `agent_00_stats.txt` | Smarties 统计器 | 每 1000 次优化器更新追加一次的训练统计；短训练通常不存在 |
| `learner-audit/learner_audit.log` | 本项目 learner audit | 初始化、每次权重更新、restart 和 final 的参数摘要 |
| `learner-audit/initial/` | 本项目 learner audit | 训练真正开始时的完整 learner checkpoint |
| `learner-audit/final/` | 本项目 learner audit | 正常训练/评估结束时的完整 checkpoint；评估加载此目录 |
| `simulation_000_00000/` | Smarties Launcher | 第 0 个环境第 0 次 callback 的实际 IBAMR 工作目录 |

`simulation_000_00000/` 中包含：

| 路径 | 用途 |
|---|---|
| `input2d`、`eel2d.vertex`、`settings.json`、`task.conf` | Smarties 从 run 根目录复制给该环境的输入 |
| `output_000` ... `output_015` | 16 个环境 MPI rank 被 Smarties 重定向后的标准输出；排查某一 IBAMR rank 时查看这些文件 |
| `Eel2dStr/` | ConstraintIB 结构标量输出，如质心、平动速度、阻力、力矩 |
| `Drag_CV_strct_id_0` | `IBHydrodynamicForceEvaluator` 基于控制体方法计算的结构 0 水动力 |
| `Torque_CV_strct_id_0` | 同一控制体评估器输出的结构 0 力矩 |
| `viz_eel2d_Str/` | VisIt/Silo 的 Eulerian 与 Lagrangian 可视化数据库 |
| `restart_IB2dStrDiv/` | IBAMR 物理 restart 数据；仅默认输出档按间隔生成 |
| `IB.log` 或案例日志文件 | IBTK/IBAMR 详细日志，具体名称受 AppInitializer 配置控制 |

若运行多个环境，目录依次为 `simulation_000_00000`、
`simulation_001_00000` 等。若同一个环境 callback 再次启动，末尾的五位计数递增；
当前 eel2d adapter 通过内部逻辑段和终止握手保持一次 callback，不依赖反复销毁重启。

### 5.6 输出量和中断恢复边界

默认短运行参数为：

```text
Smarties logAllSamples = 1
Eel2dStr output_interval = 1
viz_dump_interval = 40
restart_dump_interval = 150
timer_dump_interval = 100
```

它适合排查问题，但长时间训练会产生大量 transition、结构、可视化和 restart 数据。
`--long-run-output` 会改为：

```text
Smarties logAllSamples = 0
Eel2dStr output_interval = 1000000000
viz_dump_interval = 1000000000
restart_dump_interval = 0
timer_dump_interval = 0
```

环境仍会保存初态和显式终态可视化；learner audit 的初始/最终 checkpoint 也保留。

Smarties Agent checkpoint 与 IBAMR restart 是两类不同数据：

- `learner-audit/final` 可以重新加载策略；
- `restart_IB2dStrDiv` 才可能恢复 CFD 场和 IBAMR 时间；
- 当前 `run_node3.sh eval` 会从物理时间 0 创建新 IBAMR 环境并加载旧 Agent；
- 当前启动器没有实现“同时恢复 Smarties optimizer/replay 和某个 IBAMR restart
  时间点后继续同一训练”的一键断点续训；
- 使用 `--long-run-output` 时关闭了 IBAMR restart，因此作业中断后不能从中间物理
  场继续，只能用已有 Agent 从新的 IBAMR 初始场重新开始。

## 6. MPI 所有权、让渡和完整生命周期

### 6.1 唯一所有者

所有 world ranks 都先进入 `main()` 并构造 `CouplingDriver`。其成员 `MpiSession`
执行：

```cpp
MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided);
```

随后 Smarties 通过 borrowed-communicator 构造函数取得该 communicator。
`ExecutionInfo` 在这种构造方式下设置 `bOwnMPI=false`，析构时只释放自己创建的派生
communicator，不调用 `MPI_Finalize()`。最后由 `MpiSession` 析构并唯一调用：

```cpp
MPI_Finalize();
```

所以“MPI 让渡”不是把 MPI 所有权来回交给两个软件，而是：

```text
CouplingDriver 永久拥有 MPI 生命周期
        │
        └── Smarties 在生命周期内借用 world communicator
                │
                └── Smarties 把 environment subcommunicator 借给 IBAMR callback
```

### 6.2 17-rank 标准运行的每个 rank

命令参数：

```text
--learner-ranks 1 --envs 1 --ranks-per-env 16
```

派生关系：

```text
total_mpi_ranks = learner_ranks + envs * ranks_per_env
                = 1 + 1 * 16
                = 17
```

| world rank | Smarties 角色 | environment rank | 是否创建 IBAMR | 是否直接与 learner 交换状态/动作 |
|---:|---|---:|---|---|
| 0 | master + learner | 不属于环境 | 否 | learner 端 |
| 1 | worker，环境根 | 0 | 是 | 是 |
| 2 | worker，环境成员 | 1 | 是 | 否；从环境根广播取得动作 |
| 3 | worker，环境成员 | 2 | 是 | 否 |
| 4 | worker，环境成员 | 3 | 是 | 否 |
| 5 | worker，环境成员 | 4 | 是 | 否 |
| 6 | worker，环境成员 | 5 | 是 | 否 |
| 7 | worker，环境成员 | 6 | 是 | 否 |
| 8 | worker，环境成员 | 7 | 是 | 否 |
| 9 | worker，环境成员 | 8 | 是 | 否 |
| 10 | worker，环境成员 | 9 | 是 | 否 |
| 11 | worker，环境成员 | 10 | 是 | 否 |
| 12 | worker，环境成员 | 11 | 是 | 否 |
| 13 | worker，环境成员 | 12 | 是 | 否 |
| 14 | worker，环境成员 | 13 | 是 | 否 |
| 15 | worker，环境成员 | 14 | 是 | 否 |
| 16 | worker，环境成员 | 15 | 是 | 否 |

若使用两个 16-rank IBAMR 环境和一个 learner：

```text
--learner-ranks 1 --envs 2 --ranks-per-env 16
```

则总 MPI rank 数为 33：world rank 0 是 learner，world ranks 1..16 属于环境 0，
world ranks 17..32 属于环境 1；IBAMR 合计使用 32 个 MPI rank。两个环境拥有不同的
`environment_app_comm` 和不同的 `simulation_...` 工作目录，不应出现跨环境的
PETSc/SAMRAI 集体通信。

主要 communicator：

| communicator | 成员 | 用途 |
|---|---|---|
| `world_comm` | world ranks 0..16 | 由 `CouplingDriver` 拥有，Smarties 顶层划分依据 |
| `learners_train_comm` | 当前只有 world rank 0 | learner 侧网络更新；多 learner 时用于参数归并 |
| `master_workers_comm` | 当前 world ranks 0..16 | 环境根与 master 的状态/动作协议 |
| `environment_app_comm` | world ranks 1..16，局部 rank 0..15 | PETSc、SAMRAI、IBTK、IBAMR 以及动作/KILL 广播 |
| `workerless_masters_comm` | 当前为空 | 只有 master 多于拥有 worker 的 master 时使用 |

### 6.3 一次决策经过的 MPI 节点

1. 16 个环境 rank 同步完成上一个 IBAMR 控制区间。
2. 所有环境 rank 进入 `sendState()` 或 `sendInitState()`。
3. 环境局部 rank 0 将 state/reward 打包，通过 `master_workers_comm` 发给 world rank 0。
4. 环境局部 ranks 1..15 不向 master 重复发送状态，而是在
   `environment_app_comm` 的 `MPI_Bcast` 中等待。
5. world rank 0 把 transition 写入 replay memory。
6. V-RACER 依据当前策略选择下一动作；训练条件满足时，learner 的工作循环并行执行
   网络梯度和优化器更新。
7. world rank 0 把动作返回给 world rank 1。
8. world rank 1 在 `environment_app_comm` 中广播完整 action message。
9. world ranks 1..16 都得到同一个动作及同一个 learner 状态。
10. `sendState()` 返回，`recvAction()` 从每个环境 rank 的本地 Agent 缓存取得同一动作。
11. 所有环境 rank 在同一个安全点应用同一个频率比，并进入下一段 IBAMR 集体推进。

`envHasDistributedAgents()` 必须在第一次状态交换之前由所有环境 rank 调用。没有它，
Smarties 会把 16 个 rank 误当成 16 个各自拥有 agent 的独立 worker，不能保证状态、
动作和终止信号的统一。

### 6.4 正常结束为何不会死锁

Smarties master 达到训练预算后不会立即杀掉某个环境进程。master 的通信 handler
只等待每个分布式环境的根 worker。根 worker 在下一次状态交换中收到 `KILL`，然后
通过环境广播把它传给其余 15 个 rank；所有 rank 的 `terminateTraining()` 同时变为
true，adapter 不再推进 IBAMR，执行终态输出和逆序销毁。

此前出现过的结束死锁来自 master 为每一个原始 worker rank 都登记一次状态接收，
但分布式环境的非根 rank 从不直接发送状态。当前
`Master::spawnCallsHandlers()` 按 `workerProcessesPerEnv` 步进，只登记环境根：

```cpp
for (Uint worker = 0; worker < nCallingEnvs;
     worker += workerProcessesPerEnv)
  stateCallers.push_back(worker);
```

这与 adapter 的 `envHasDistributedAgents()` 缺一不可：前者修正 master 等待对象，
后者修正环境内动作和结束信号的广播语义。

### 6.5 MPI rank 与 CPU 线程不是同一个概念

`--ranks-per-env 16` 是 16 个独立 MPI 进程共同运行 IBAMR；
`--learner-threads 4` 是 learner 进程内部最多 4 个 OpenMP 训练线程。总 MPI rank
数不会因为 learner threads 增加而变化。

IBAMR 某些步骤只能利用部分 rank、某些 rank 又可能等待线性求解或集体通信，因此
系统监视器中不是每个逻辑 CPU 都长期 100%。这不等于 MPI 丢进程。判断耦合是否正常
应看物理时间、控制决策和通信是否持续推进，而不是要求所有 CPU 图始终满载。

## 7. Smarties、V-RACER 和当前任务的可调参数

### 7.1 参数从哪里读取

启动脚本把 `--training` 指定的文件复制成 run 根目录的 `settings.json`。
`AlgoFactory` 只读取该文件；缺少的键由编译进
`source/smarties/Settings/HyperParameters.h` 的默认值补齐。

仓库中的 `settings/default.json` **不会自动与本次文件合并**，并且其中个别数值与
C++ 默认成员不同。因此正式实验不应假定 `settings/default.json` 是隐式基线；重要
参数应在自己的训练 JSON 中显式写出，并以 run 目录冻结的 `settings.json` 为准。

修改 JSON、task conf、`--end-time`、MPI ranks 或 learner threads 不需要重新编译；
修改 C++ 状态维度、运动学、Smarties 核心或 IBAMR 案例实现需要重新编译。

### 7.2 当前提供的训练配置

`configs/training/speed_tracking.json`：

```json
{
  "learner": "VRACER",
  "batchSize": 1,
  "encoderLayerSizes": [0],
  "maxTotObsNum": 512,
  "minTotObsNum": 1,
  "nnLayerSizes": [16, 16],
  "obsPerStep": 1,
  "saveFreq": 64
}
```

这是短流程配置，batch 为 1，不适合多 learner 线程。

`configs/training/eel2d_longrun.json`：

```json
{
  "learner": "VRACER",
  "batchSize": 4,
  "encoderLayerSizes": [0],
  "maxTotObsNum": 256,
  "minTotObsNum": 8,
  "nnLayerSizes": [16, 16],
  "obsPerStep": 1,
  "saveFreq": 8
}
```

这是当前长程流程使用的轻量配置：收集 8 个 transition 后开始学习，replay 最多
256 个 transition，网络为两个 16 单元隐藏层，常规 checkpoint 每 8 次更新保存。
这些数值优先满足耦合流程和较低计算/存储成本，不代表已经调优。

`configs/training/cpu_learner_eel_activity.json` 仅用于两次更新的 learner 活动验证，
不是正式训练配置。

### 7.3 JSON 超参数手册

下表列出当前 `HyperParameters::initializeOpts()` 能读取的全部键。表中“C++ 默认值”
表示该键在本次 `settings.json` 中缺失时的实际默认值。

| JSON 键 | C++ 默认值 | 含义和使用建议 |
|---|---:|---|
| `learner` | `VRACER` | 学习算法。可选 `RACER`、`VRACER`、`PPO`、`DPG`、`ACER`、`NAF`、`DQN`、`CMA`、`PYTORCH`；当前只验证原生 CPU `VRACER` |
| `ERoldSeqFilter` | `oldest` | replay 满时删除旧 episode 的策略；还支持 `farpolfrac`、`maxkldiv`、`minerror`、`default` |
| `dataSamplingAlgo` | `uniform` | replay 采样；支持 `uniform`、`PERrank`、`PERerr`、`PERseq` |
| `returnsEstimator` | `default` | return 估计；支持 `retrace`、`retraceExplore`、`GAE`、`none`；V-RACER 的 `default` 会转为 `retrace` |
| `explNoise` | `sqrt(0.2)`，约 0.4472 | 连续策略的初始标准差/探索强度；eval 时 Smarties 冻结训练并按评估模式选动作 |
| `gamma` | `0.995` | 折扣因子，合法范围 `[0,1]` |
| `lambda` | `1` | off-policy return estimator 的 lambda |
| `obsPerStep` | `1` | 观测 transition 与梯度步的比；`0.1` 表示每个 observation 可做约 10 个梯度步 |
| `clipImpWeight` | `sqrt(dimA/2)` | off-policy importance weight 裁剪；当前一维动作默认约 0.7071 |
| `penalTol` | `0.1` | 自适应 off-policy 惩罚容差，ReF-ER Rule 2 使用 |
| `klDivConstraint` | `0.01` | KL divergence 约束目标 |
| `targetDelay` | `0` | `0` 禁用 target net；大于 1 表示间隔复制；小于 1 表示每步指数平均率 |
| `epsAnneal` | `5e-7` | 算法相关 annealing 率；大于 `1e-4` 会被代码改回 `5e-7` |
| `minTotObsNum` | `0` | 开始训练前的最少 transition；`0` 会在初始化时变成 `maxTotObsNum` |
| `maxTotObsNum` | `2^14*sqrt(dimA+dimS)` | replay 最大 transition 数；当前 5+1 维问题默认约 40132 |
| `saveFreq` | `50000` | 常规 learner checkpoint 间隔，单位为优化器更新次数；当前项目配置都显式覆盖 |
| `encoderLayerSizes` | `[0]` | 非卷积 encoder 层；`[0]` 表示不增加 encoder |
| `nnLayerSizes` | `[128,128]` | 主网络隐藏层尺寸 |
| `batchSize` | `256` | 每次网络更新的 batch；多线程/多 learner 时需满足可整分 |
| `ESpopSize` | `1` | evolution strategies population；小于 2 时使用 Adam |
| `nnBPTTseq` | `16` | RNN/LSTM 的反向传播序列长度；FFNN 基线基本不使用 |
| `nnLambda` | `float epsilon` | 网络权重正则项系数，实际更新中还乘学习率 |
| `learnrate` | `1e-4` | 学习率，代码要求 `[0,1]` |
| `outWeightsPrefac` | `1e-3` | 输出层权重初始化相对 fan-in 的缩放 |
| `nnOutputFunc` | `Linear` | 输出层激活函数 |
| `nnFunc` | `Tanh` | 隐藏层激活函数；还支持源码 Builder 中注册的 ReLU、SoftSign 等 |
| `nnType` | `FFNN` | 网络类型；`RNN`、`LSTM`、`MGU`、`GRU` 被识别为 recurrent，其他值走 FFNN |

当前网络由 CMake 默认 `SINGLE_PRECISION=ON` 编译，因此 Smarties 网络参数使用
float32；IBAMR/PETSc 的物理计算精度由其自身构建决定，不因为网络 float32 而改成
单精度。

### 7.4 启动级训练和资源参数

这些参数不在 JSON 中，而由 `run_node3.sh` 转换为 Smarties Engine 参数：

| 运行器参数 | Smarties 参数 | 作用 |
|---|---|---|
| `--learner-threads N` | `--nThreads N` | 每个 learner rank 的训练线程数 |
| `--learner-ranks N` | `--nMasters N` | learner/master MPI ranks |
| `--envs N` | `--nEnvironments N` | 环境数量 |
| `--ranks-per-env N` | `--workerProcessesPerEnv N` | 每个分布式环境的 MPI ranks |
| `--train-steps N` | `--nTrainSteps N` | transition 训练预算 |
| `--train-updates N` | `--nTrainUpdates N` | 精确的额外优化器更新预算；正数时替代 train steps |
| `--eval-episodes N` | `--nEvalEpisodes N` | 冻结网络、关闭训练，收集指定逻辑段 |
| `--checkpoint DIR` | `--restart DIR` | 从该目录读取 `agent_00_*` learner 数据 |
| `--long-run-output` | `--logAllSamples 0` 加稀疏 CFD 输出 | 控制存储量，不改变状态/动作/reward |

`--randSeed`、`--appSettings`、`--nStepPappSett`、
`--redirectAppStdoutToFile` 等是 Smarties Engine 原生参数，但当前 `run_node3.sh` 没有
全部暴露成同名外层选项。需要可复现实验种子时，应先把 `--randSeed` 明确加入运行器
参数转发；当前未指定时由 Smarties 生成随机 seed 并在启动日志打印。

### 7.5 eel2d task 参数手册

当前模板为 `configs/tasks/speed_tracking.example.conf`，长程任务为
`configs/tasks/eel2d_longrun.conf`。

当前长程任务的实际值是：

```text
baseline_angular_frequency = 6.28
minimum_frequency_ratio    = 0.5
maximum_frequency_ratio    = 1.5
maximum_ratio_delta        = 0.1
decisions_per_baseline_period = 8
target_forward_speed       = 0.2
forward_direction          = (1, 0)
velocity_scale             = 0.5
tracking_weight            = 2.0
frequency_weight           = 0.05
smoothness_weight          = 0.05
warmup_cycles              = 0
episode_decisions          = 2
```

因此当前动作 `-1` 和 `1` 分别对应目标频率比 0.5 和 1.5，但实际频率比每个决策
最多变化 0.1；控制间隔约为 0.125 s；每两个决策结束一个 Smarties 逻辑段。

| task 键 | 作用 |
|---|---|
| `baseline_angular_frequency` | 官方基准角频率；当前代码要求严格为 6.28 |
| `minimum_frequency_ratio` | 动作映射后的最小频率比，必须为正且区间包含 1 |
| `maximum_frequency_ratio` | 动作映射后的最大频率比，区间必须包含 1 |
| `maximum_ratio_delta` | 每次决策允许的最大频率比变化 |
| `decisions_per_baseline_period` | 一个基准尾拍周期内的决策数 |
| `target_forward_speed` | reward 中的目标推进速度 |
| `forward_direction_x/y` | 推进速度投影单位向量 |
| `velocity_scale` | 状态与速度误差归一化尺度，必须为正 |
| `tracking_weight` | 速度跟踪平方惩罚权重 |
| `frequency_weight` | 偏离频率比 1 的平方惩罚权重 |
| `smoothness_weight` | 相邻频率比变化的平方惩罚权重 |
| `warmup_cycles` | 第一次受控动作前按频率比 1 推进的周期数 |
| `episode_decisions` | 一个 Smarties 逻辑段的决策数，不触发物理 reset |

控制间隔为：

```text
2*pi / (decisions_per_baseline_period * baseline_angular_frequency)
```

### 7.6 为什么当前目录看不到 RMSE 等训练过程

Smarties 的 `Learner::freqPrint` 当前固定为 1000，未暴露为 JSON 或命令行参数。
`Learner::logStats()` 只有在第 1000、2000、3000……次优化器更新时才调用
`processStats()`。届时同一行统计会：

1. 打印到 master 的标准输出，因此出现在 run 根目录的 `stdout.log`；
2. 追加到 run 根目录的 `agent_00_stats.txt`。

此前的长程流程只有 32 次优化器更新，远小于 1000，所以没有
`agent_00_stats.txt`，也不会在终端出现 RMSE 行。这不是训练结果丢失，也不是输出只
存在于已经关闭的终端。

`saveFreq` 只控制常规 checkpoint 频率，不控制统计打印频率；把 `saveFreq` 改为 1
也不会让 RMSE 每步输出。

统计行主要字段为：

| 字段 | 含义 |
|---|---|
| `avgR` | 最近统计窗口的平均累计回报 |
| `avgr` / `stdr` | 单步 reward 的均值和标准差 |
| `DKL` | 当前数据/策略相关的平均 KL divergence |
| `RMSE` | Q/V 近似器在采样数据上的均方误差平方根；不是一个单独命名的 PyTorch loss |
| `maxErr` | 近似误差最大绝对值 |
| `dRet` | return estimate 更新误差；有对应更新时才出现 |
| `stdQ` / `avgQ` / `minQ` / `maxQ` | Q/V 估计分布 |
| `nEp` / `nObs` | 当前 replay 中 episode 和 transition 数 |
| `totEp` / `totObs` | 累计看到的 episode 和 transition 数 |
| `nFarP` | 被判定为 far-policy 的 transition 数 |
| 网络名列 | 网络权重 L2 norm；启用 target net 时还包含与 target 的距离 |

当前项目额外启用的 `learner-audit/learner_audit.log` 每次更新都会写一条：

```text
SMARTIES_NETWORK_AUDIT stage=update network=... step=... threads=...
precision_bytes=... params=... digest=... sum=... sum_squares=...
max_abs=... finite=1
```

它用于证明网络参数确实发生有限数值更新、记录更新步数和线程数，不计算 RMSE、
policy loss 或 value loss。`learner-audit/initial` 和 `final` 保存完整 checkpoint。

实时查看当前运行可使用：

```bash
RUN=/data2/mjwu/local/coupling-src/smarties/couplings/ibamr/runs/<run目录>

tail -f "$RUN/stdout.log"
tail -f "$RUN/learner-audit/learner_audit.log"
```

运行达到 1000 次更新后：

```bash
tail -f "$RUN/agent_00_stats.txt"
```

若实验必须每 10 或 100 次更新记录 RMSE，需要把 `freqPrint` 做成正式配置或修改
C++ 默认值并重新编译。当前 JSON 没有这个开关；不能通过 `saveFreq` 替代。

## 8. 迁移到其他 IBAMR 案例

通用架构可以迁移，但不是把 eel2d 文件名替换掉就结束。新案例应保持以下分层：

```text
官方案例
  ├── CaseEnvironment
  │   ├── initialize(environment_comm)
  │   ├── observe()
  │   ├── applyAction()      只在完整时间步之间
  │   ├── advanceControlInterval()
  │   ├── reset()            只有确实完整定义时才提供
  │   └── shutdown()
  ├── CaseSmartiesAdapter
  │   ├── state/action 维度和缩放
  │   ├── reward
  │   ├── send/receive 协议
  │   └── terminal/truncation 语义
  └── thin main + CouplingDriver
```

迁移时必须逐项确定：

1. 状态具体来自哪个物理量、什么时间点、什么单位和归一化；
2. 动作改变哪个案例参数、合法范围、变化率和安全生效位置；
3. 一次动作持续多少物理时间或多少完整求解器步；
4. reward 中哪些是真实物理测量，哪些只是正则项；
5. Smarties 逻辑段结束时物理是否继续；
6. 若声称 episode 独立，如何完整恢复网格、流场、结构、时间和控制器状态；
7. learner ranks 是否完全不创建 PETSc/SAMRAI/IBTK/IBAMR 对象；
8. 所有案例依赖是否都使用 `environment_app_comm`；
9. 多 rank 环境是否在第一次交换前调用 `envHasDistributedAgents()`；
10. 正常结束和一个相关故障路径是否能让所有 rank 一致退出。

新 IBAMR/SAMRAI/PETSc 版本必须重新适配 API，并重新检查是否还有写死的
`MPI_COMM_WORLD`。通用的是 MPI 所有权、环境 communicator 和安全控制点，不是
当前版本的 SAMRAI patch 或 eel2d 运动学源码。

## 9. 当前能力边界与常见判读

| 现象 | 含义或处理 |
|---|---|
| `EEL_CONTROL_COMPLETE ... stopped_by=smarties` 且 `exit_code.txt=0` | Smarties 达到预算，IBAMR 正常销毁，MPI 正常结束 |
| `learner-audit.log` 有 `stage=update` 和 `stage=final` | 原生网络完成更新并保存最终 checkpoint |
| eval 日志有 `stage=restart` 且没有 `stage=update` | 已加载冻结 Agent，没有继续训练 |
| 没有 `agent_00_stats.txt`，但 audit 有 32 次 update | 更新数未达到固定的 1000 次统计输出周期，不是训练失败 |
| `IBAMR end time reached before Smarties training termination` | `--end-time` 太短，物理时间先耗尽；不是 MPI 死锁 |
| `lagrangian_points` 突然变化 | 几何/input/布局出现问题；背景网格粗化不能解释拉格朗日点丢失 |
| `processes-after.txt` 非空 | 本次作业仍有残留进程，不能判定正常清理完成 |
| 只有部分 CPU 很忙 | MPI/求解器负载和等待不均衡；应结合物理时间和控制日志判断是否推进 |
| run 根目录没有 `Eel2dStr/` | 正常；IBAMR 实际工作目录是 `simulation_000_00000/` |
| `learner-audit/` 尚未创建 | 作业还没收集到 `minTotObsNum` 并初始化 learner，或在此前已经失败；目录由第一次 audit/checkpoint 写入时创建 |
| `simulation_000_00000/Eel2dStr/` 很久不更新 | 使用 `--long-run-output` 时结构输出间隔被设为十亿步，这是有意的存储控制；看 `EEL_CONTROL` 和物理时间判断推进 |

当前没有纳入基线的能力：

- PyTorch learner 和 CUDA；
- Python/pybind11 直接驱动耦合；
- 周围 Eulerian 流场作为 observation；
- 多个独立物理 episode 的完整 reset；
- Smarties 与 IBAMR 同时从中间时刻一键断点续训；
- 已标定的推进效率 reward；
- 已证明的策略收敛、最优性或跨网格泛化；
- IBAMR 0.18.0 之外版本的直接二进制兼容。

这些边界不影响当前“Smarties 与 IBAMR 在同一 MPI 作业中正确交换状态、动作和
reward，持续推进真实 eel2d，并保存/加载原生 CPU Agent”的耦合目标。
