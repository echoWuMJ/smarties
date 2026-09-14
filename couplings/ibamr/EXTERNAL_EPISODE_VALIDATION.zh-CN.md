# 独立回合提交验证记录

## 范围

本次提交提供可继续开发的单机独立CFD回合耦合，不是近壁策略的正式研究发布。CPU Smarties保持常驻，CFD每回合以新MPI作业运行。未采用的同进程重建补丁、脚本和测试保存在本地`.artifacts/ibamr-smarties-investigations/near-wall-episode-reset/retired/`，不加入版本库。

## 已执行

- 2026-09-08，node03：1环境×2 CFD rank，完成11次独立作业启动、2次网络更新和正常退出。
- 2026-09-08，node03：2环境×16 CFD rank、learner 8线程，完成12次独立作业启动；10个短回合有一次动作推进，2个回合在初态交互后停止。所有作业退出码0；初始时间0、点数2932、随机高度不同；learner完成2次有限值更新。
- 无效CFD输入检查：CFD非零退出向上传播，管理程序返回失败并回收learner。没有将求解器错误伪装成物理终态。
- 2026-09-14：移除未使用的重建入口后，node03重新编译两个耦合可执行文件，通过8项相关CTest（近壁任务、尾摆相位、官方运动公式、控制任务、速度探针、控制测量、模型密度、逻辑分段）及3项Python进程管理测试。未重复无关长程测试。
- Git暂存区检查不包含运行场数据、临时压缩包、Python缓存或旧重建实验文件。

第一次8线程检查使用batchSize=4，触发原生Smarties的零OpenMP分块问题；检查配置已改为8，启动器加入`batchSize >= threads`和`minTotObsNum >= batchSize`检查。正式初始配置batchSize=32未降低。

提交审查修正两处退出竞态：代理先读取退出码再读取状态，避免丢判刚发布的终态；进程在poll和killpg之间退出时仍回收子进程，且单项清理错误不会跳过其他作业。后者有实际短生命周期子进程回归测试，修复前失败、修复后通过。

修复后的最终短回合检查位于`/data2/mjwu/local/coupling-runs/near-wall-prepush-20260914`，检查脚本报告`NEAR_WALL_CHECK_COMPLETE`，管理程序退出码0。两处修复通过独立只读代码复审。

## 复现入口

```bash
bash couplings/ibamr/scripts/build_near_wall_node3.sh
NEAR_WALL_ENVS=2 NEAR_WALL_RANKS=16 NEAR_WALL_LEARNER_THREADS=8 \
  bash couplings/ibamr/scripts/check_near_wall_node3.sh /absolute/new/check-directory
```

检查脚本使用很短的物理上限，仅验证回合轮换，不是完整训练。启动参数、消息文件和结果目录见[近壁说明](NEAR_WALL.zh-CN.md)。

node3证据目录：

- `/data2/mjwu/local/coupling-runs/near-wall-external-check-20260908`
- `/data2/mjwu/local/coupling-runs/near-wall-external-32rank-check2-20260908`
- `/data2/mjwu/local/coupling-runs/near-wall-external-failure-20260908`

本地证据压缩包：`.artifacts/ibamr-smarties-investigations/near-wall-episode-reset/near-wall-external-evidence-20260908.tar.gz`。

## 未覆盖

未证明长程训练稳定性、策略收敛、实际触壁后的数值可恢复性、所有姿态下探针处于鱼体外、近壁控制体受力精度或跨节点通信。当前进程级测试不能替代这些物理验证。
