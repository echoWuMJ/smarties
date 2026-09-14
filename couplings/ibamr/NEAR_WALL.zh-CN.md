# eel2d 近壁独立回合

本模块为`--eel-mode near-wall`，与原有`speed-tracking`模式分开。当前实施和验证状态以实际运行记录为准；能够编译不等于已完成长期训练验证。

## 回合定义

下壁面为y=-1.52，y方向取消周期并采用输入文件中的无滑移条件，上壁面也是无滑移。x方向保持周期，鱼体接近接缝前结束当前回合。保持官方N=64、三级网格、细化比4及2932个拉格朗日点。

每回合根rank从[0.25L,0.60L]均匀抽取质心壁距并广播，使用IBStandardInitializer的posn_shift整体平移原鱼体。每回合启动一个全新的IBAMR MPI作业；其流场、物理时间、积分器、频率控制历史和PETSc/IBTK均重新初始化。只有Smarties、网络、优化器和经验池保持存活。回合内每次动作交互不重启进程。

每个完成的CFD步检查，优先级为：触壁、质心壁距>=0.7L、计算域安全边界、前进4L、时间达到10T0。没有强制运行6T0的下限。触壁、离壁及到达目标使用sendTermState；时间和计算域限制使用sendLastState。

## 奖励与状态

Fx为IBHydrodynamicForceEvaluator计算的整体水动力x分量。鱼向负x前进，采用`CT=-Fx/(0.5*rho*(L/T0)^2*L)`；二维力按单位展长解释，L=1、rho=1、T0=2*pi/6.28。各CFD步以实际dt累计CT，除以名义动作间隔T0/8；触壁或离壁额外一次-1。不会使用合力绝对值，也不加入旧的速度跟踪奖励。

25维状态排列：

|下标|变量|
|---|---|
|0–1|质心壁距/L、鱼体最小壁面间隙/L|
|2–3|负x前进速度/Uref、正y法向速度/Uref|
|4–6|体轴相对前进方向的sin、cos，角速度*T0|
|7–8|尾摆相位sin、cos|
|9–10|当前实际频率比、上次实际频率比|
|11–22|p0至p5处相对鱼体平移的流速，先负x分量再正y分量，除以Uref|
|23|剩余前进距离/L|
|24|剩余回合时间比例|

探针原始全局坐标和绝对速度保存在CSV。真终态不需要价值自举；若使用最后一次有效流速，CSV中的flow_sample_current=0会明确标记。25维checkpoint与原17维、5维网络不兼容。

## 代码切入点

- EelNearWallTask：25维状态、奖励、终态判断。
- EelNearWallAdapter：独立CFD可执行文件入口、随机初态及单回合物理推进；不运行learner。
- EelExternalAdapter：常驻Smarties代理，每环境一个rank，转发状态、动作及终态。
- EpisodeMailbox：带序号的小消息文件，以原子rename发布，state/action覆盖使用。
- external_episode_manager.py：不初始化MPI；启动和回收彼此独立的MPI作业。
- EelEnvironment::initializeNearWall：借用本次CFD作业的运行环境，修改初始化数据库。
- EelEnvironment::nearWallObservation：从当前COM、速度及分布式拉格朗日坐标提取状态，以环境通信器归约几何范围。
- 新入口不清空库级单例，不在同一进程内重建第二个物理回合。

## node3 构建与启动入口

`scripts/build_near_wall_node3.sh`使用GCC8.5及已有samrai-subcomm依赖编译`ibamr_eel2d_smoke`和`eel_near_wall_episode`。脚本包含本次node3目录；移植时要修改路径。

未通过的同进程重建补丁和测试已移入本地调查存档，不属于本方案，也不要求安装额外的episode-release补丁。

## MPI所有权

管理程序运行在普通Python进程中，不导入MPI。Smarties作业包含一个learner rank和每环境一个代理rank，由CouplingDriver拥有MPI；这些代理不初始化CFD。每个独立CFD作业由自身main中的MpiSession拥有MPI，16个rank只参与本作业的CFD通信。主rank收发小消息，动作通过本作业MPI广播。旧CFD进程组退出且回收后，管理程序才启动替代回合；CFD异常退出使本次训练失败，不伪造正常终态。

当前文件通道限定node3单机、同一用户、私有运行目录；并未声明跨节点文件系统性能或安全性。无物理推进超时限制。取消时管理程序只向自己创建的进程组发送终止信号。

验证后启动示例：

```bash
NEAR_WALL_ENVS=2 NEAR_WALL_RANKS=16 NEAR_WALL_LEARNER_THREADS=8 \
NEAR_WALL_STEPS=8192 bash couplings/ibamr/scripts/run_near_wall_node3.sh \
  /data2/mjwu/local/coupling-runs/NEW_RUN_NAME
```

这些环境变量分别控制环境数、每环境MPI rank数、learner线程数和训练动作预算。IBAMR rank乘积不得超过32；CFD回调使用一个OpenMP线程。CPU亲和性由调度器、cpuset或调用前的taskset设置，默认启动脚本不为每个CFD rank占用四个核心。使用Smarties原生CPU网络，不接入PyTorch。

初始网络64×64，batchSize=32，最少128个replay观测后学习，replay容量20000。配置在configs/training/near_wall.json；不能由这些初值推断策略已收敛。

本启动器固定一个learner rank；原生Smarties要求batchSize不小于learner线程数，minTotObsNum不小于batchSize。启动器在创建进程前检查这两项，避免OpenMP分块大小为0。

## 验证范围

node3于2026-09-08完成两个环境各16个CFD rank、learner 8线程的短回合检查：12个独立CFD作业全部正常退出，其中10个回合完成一次动作推进，另外2个接收停止指令后退出；初始时间均为0，鱼体点数均为2932，初始高度各异。learner完成2次有限值网络更新并保存final审计checkpoint。运行目录为`/data2/mjwu/local/coupling-runs/near-wall-external-32rank-check2-20260908`。

故意提供无效CFD输入的独立检查验证了非零退出传播及learner回收。代码和小型日志在本地保留，完整CFD证据未加入Git。

这些证据只覆盖短回合进程轮换和协议，不覆盖长程轨迹、真实触壁数值稳定性、全部姿态下探针位于鱼体外的有效性、近壁控制体受力精度或策略收敛。当前探针越出计算域会使作业失败；仍需在长程研究中核查这些物理边界，不应将本提交视为已校准的近壁研究结果。

## 文件布局

运行根目录包含input2d、eel2d.vertex、task.conf、settings.json、process.log（learner日志）、launcher.pid（learner作业PID）、exit.status（learner退出码）、manager.exit.status（管理程序退出码）和learner-audit。原生Smarties checkpoint仍由Smarties在其工作目录中生成。

`env_1/episode_1/`等目录保存每个CFD作业的process.log、launcher.pid、exit.status、输入副本及覆盖使用的state/action消息。该目录下`cfd/`保存实际CFD输入、episode.conf、transitions.csv、结构标量及可视化。每个环境的首回合每2000步保留可视化，其余回合关闭全场输出，不写CFD restart。目录中的episode编号才是物理回合编号；单回合可执行文件内部计数始终从1开始。

transitions.csv包括壁距、最小间隙、进度、速度、姿态、角速度、频率、Fx、CT奖励、总奖励、结束原因，以及六探针的原始坐标和速度。Agent checkpoint只能恢复策略/相应学习状态，不代表能够恢复任意时刻的CFD场。
