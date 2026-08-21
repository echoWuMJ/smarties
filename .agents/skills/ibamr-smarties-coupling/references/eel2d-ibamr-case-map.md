# eel2d 的 IBAMR 改造地图

本页适用于基于 IBAMR 0.18.0 官方 `examples/ConstraintIB/eel2d/` 构建
Smarties 频率控制案例时。先读架构契约；本页只规定案例层的边界，不改变
MPI 所有权或 rank 分区。

## 基线与可修改边界

- `couplings/ibamr/cases/eel2d/upstream/` 保留官方 0.18.0 eel2d 的输入、
  拉格朗日点和运动学派生物；其来源和原始哈希在同目录
  `PROVENANCE.md`。不要把这些来源哈希误称为修改后文件的哈希。
- `eel2d.vertex` 是未修改的官方模型点文件。背景 AMR 网格密度由
  `configs/fidelity/medium.conf` 和渲染输入控制，不能通过重采样 vertex
  文件来“适配”网格。
- 对运动规律的改动限于时间相位/频率：官方几何、幅值包络、机动逻辑和法向
  保持不变。频率比为 1 时，运动公式必须与官方 `6.28` 角频率等价。
  `official_eel_formula_test` 是此约束的快速检查。

## 代码接入点

| 位置 | 职责 | 修改时必须保持的条件 |
|---|---|---|
| `upstream/IBEELKinematics.*` | 官方 `ConstraintIBKinematics` 派生类；把解析器变量 `PHI`、`OMEGA` 绑定为连续相位和受控角频率 | 仅在 IBAMR 安全控制点用 `setTailBeatFrequencyRatio(ratio, effective_time)` 更新；不得造成相位跳变 |
| `TailBeatPhase.*` | 以锚点时间和锚点相位实现分段连续相位 | 新命令先保留 `valueAt(effective_time)`，再改变频率；不接受倒退时间或非正/非有限频率 |
| `EelEnvironment.*` | 将官方示例的初始化、层级推进、COM/水动力输出和销毁封装成环境 | 只在环境子通信器初始化 PETSc/IBTK/IBAMR；设置 `PETSC_COMM_WORLD`，并在 `IBTKInit` 后恢复 SAMRAI 的环境通信器 |
| `EelSmartiesAdapter.*` | Smarties 状态/动作/奖励与 `EelEnvironment` 控制区间之间的协议 | 一次动作后推进完整控制区间；使用实际起止时间和 COM 计算速度；逻辑段结束用 `sendLastState()`，不得重建环境 |
| `main.cpp` | 替代官方单体 example 主程序的薄入口 | 只解析 eel 模式并交给 `CouplingDriver`；不得直接初始化或终结 MPI |

`couplings/ibamr/CMakeLists.txt` 将它们分为运动控制、IBAMR 支持、环境、
适配器和可执行程序几个 target。新增案例功能时优先放入对应层，而不是把
IBAMR 对象泄漏到 Smarties learner 侧。

## 验证和边界

- 运动层改动至少检查相位连续性、频率比 1 的官方公式等价性，以及渲染输入。
- 真实 eel2d 运行应记录并检查每个 `EEL_CONTROL` 的拉格朗日点数；官方
  medium 当前的已验证实例为 2932。点数异常时先停止，不把它解释为背景网格
  正常粗化。
- 当前案例是持续物理时间线，不支持由 Smarties 每个逻辑段独立重置 IBAMR。
  IBAMR 先到 `END_TIME` 也不是正常完成，应走协调失败路径。
- IBSAMRAI2 的子通信器补丁不修改共享 autoibamr 安装；由
  `prepare_node3_ibamr.sh` 在独立 overlay 的源副本上应用并重编译。
