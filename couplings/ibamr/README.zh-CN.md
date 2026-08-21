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
