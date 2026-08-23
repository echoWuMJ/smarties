# Smarties-IBAMR eel2d 耦合使用说明

本文对应仓库分支 `feature/ibamr-eel2d-coupling`，目标机器为 node3 上已部署的
IBAMR 0.18.0 环境。当前实现使用 Smarties 原生 CPU learner；不启用 Python
binding、PyTorch 或 CUDA。它已支持单个持续 eel2d 物理时间线上的频率控制与
Smarties 训练通信，但不把这里的诊断任务当作已校准的游动策略或独立 episode
重置方案。

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
不会参加 IBAMR 的集体/点对点通信，程序就可能卡死。

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

运行器为每次启动在 `couplings/ibamr/runs/` 创建独立目录，其中包括：

- `manifest.txt`：源码、可执行文件、库、overlay 补丁和启动拓扑的身份信息；
- `input2d`、`eel2d.vertex`、`settings.json`、`task.conf`：本次冻结输入；
- `stdout.log`、退出码和 learner 审计目录。

正常的训练诊断结束应出现 `EEL_CONTROL_COMPLETE ... stopped_by=smarties`。
每条 `EEL_CONTROL` 还会记录 `lagrangian_points`；medium 既有验证实例为 2932。
若 IBAMR 先达到 `--end-time`，程序会发送最后一个截断状态后协调报错退出，而不
重建 eel 环境。这是为了避免把未定义的物理重置伪装成正常训练完成。

`--dry-run` 可以先检查环境、输入与派生 MPI 启动命令而不实际运行；把它追加到
上面任一完整的 `run_node3.sh` 命令末尾即可。

## 6. IBAMR 侧改造位置

官方 eel2d 基线及来源哈希在
`couplings/ibamr/cases/eel2d/upstream/PROVENANCE.md`。耦合版本没有通过删减或
重采样 `eel2d.vertex` 来适配网格：`EelEnvironment.*` 将官方示例的初始化和
时间推进封装为环境；`TailBeatPhase.*` 保证频率动作切换时相位连续；
`upstream/IBEELKinematics.*` 将原时间项替换为 `PHI`/`OMEGA`；
`EelSmartiesAdapter.*` 在控制安全点做状态、动作、奖励传递；`main.cpp` 仅将
模式交给唯一的 MPI 所有者 `CouplingDriver`。详细约束见仓库 skill 的
`references/eel2d-ibamr-case-map.md`。

### 动作在何处插入，IBAMR 又在何处等待

真实控制循环位于 `cases/eel2d/EelSmartiesAdapter.cpp`。环境先通过
`comm->sendInitState(state)` 将当前五维状态交给 Smarties，然后执行：

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
