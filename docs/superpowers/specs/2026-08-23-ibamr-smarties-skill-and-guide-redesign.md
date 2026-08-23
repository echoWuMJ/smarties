# IBAMR-Smarties 通用耦合 Skill 与使用说明重构设计

## 目标

将现有文档重构为两类稳定资料：

1. 面向未来任意 IBAMR 案例的通用耦合 skill；
2. 面向当前仓库和 node3 环境的中文安装、编译、启动与参数手册。

内容只采用仓库代码、已确认架构决策和已验证结果能够支持的结论。eel2d 作为
已实现参考，不定义通用架构。

## 信息分层

### 主 Skill

`.agents/skills/ibamr-smarties-coupling/SKILL.md` 保持短小，包含：

- 适用场景与参考资料路由；
- MPI、通信器和库生命周期的不变量；
- 通用案例接入顺序；
- 控制安全点与同步等待语义；
- 正常退出和分布式致命错误路径；
- 从小到大的验证顺序；
- 经验准入规则。

主 skill 不包含 node3 固定路径、eel2d reward 公式、具体模型点数或安装命令。

### 通用参考资料

- `architecture-contract.md`：MPI 所有权、rank 拓扑、通信器、控制边界和退出协议。
- `case-porting-playbook.md`：把任意官方 IBAMR 案例拆成薄入口、环境层和 Smarties
  适配层；定义状态、动作、reward、控制区间、终止和物理 reset 的设计检查项。
- `validated-lessons.md`：仅记录当前实现已经支持的通用结论及其适用边界，包括
  borrowed MPI、IBAMR 子通信器、同步阻塞动作、持续物理时间线和输出控制经验。
- `experience-admission.md`：保留经验准入标准。

### eel2d 参考资料

将现有 eel2d 参考内容合并为 `eel2d-reference.md`，包含：

- IBAMR 0.18.0 官方案例来源；
- `EelEnvironment`、`EelSmartiesAdapter`、`TailBeatPhase` 和
  `IBEELKinematics` 的职责；
- 动作插入点、五维状态、频率控制和 reward 公式；
- 逻辑段不重置物理环境的语义；
- 已验证的 node3 拓扑和结果边界；
- 尚未验证的长时间训练、多环境大 rank 拓扑、策略质量和其他版本兼容性。

删除被合并后的 `eel2d-continuing-coupling.md` 和
`eel2d-ibamr-case-map.md`，并更新所有引用。

## 中文使用说明

`couplings/ibamr/README.zh-CN.md` 按实际使用顺序重写：

1. 支持范围和已验证版本；
2. Git 下载、本地打包和上传；
3. node3 依赖与版本检查；
4. SAMRAI 子通信器补丁的作用、自动应用时机和 overlay；
5. 从未编译源码到构建产物；
6. smoke 与 train 启动命令；
7. 所有 launcher 参数的含义、约束和总 MPI rank 计算；
8. 动作等待、IBAMR 推进和状态回传顺序；
9. 当前 eel2d 状态、动作、reward 和控制区间；
10. replay、checkpoint、日志、VisIt/Silo、restart 等输出及长任务数据量风险；
11. 正常完成、IBAMR 提前结束和 MPI 故障的识别；
12. 迁移到其他 IBAMR 案例和版本的步骤。

手册使用确定句式。版本限制、诊断配置和未验证范围直接标注，不加入讨论过程、
第一人称判断或推测性结论。

`couplings/ibamr/README.md` 保留英文概览和中文手册入口，不在本次重写完整英文
手册。

## 事实边界

可以写为当前结论：

- `CouplingDriver` 唯一拥有 MPI 初始化和终结；
- Smarties borrowed mode 不终结外部 MPI；
- learner 与 IBAMR environment 使用独立 ranks；
- PETSc、SAMRAI、IBTK 和 IBAMR 使用 environment communicator；
- `recvAction()` 同步阻塞时 IBAMR 不推进；
- eel2d 一次动作后推进一个完整控制区间；
- eel2d 逻辑训练段复用同一物理环境；
- 当前 node3 bounded 验证覆盖的明确结果。

不得写为已验证结论：

- eel2d 策略质量、收敛性或 reward 标定；
- 长时间训练稳定性；
- 两个 16-rank IBAMR 环境；
- 独立物理 episode reset；
- PyTorch、CUDA 或 Python binding；
- 非 IBAMR 0.18.0 版本的源码或二进制兼容性。

## 验证

- 运行 skill `quick_validate.py`；若 Windows Python 启动器不可用，记录原因并执行
  等价的 frontmatter、名称、引用和未完成标记检查；
- 检查 skill 中每个 reference 链接存在，仓库内无旧文件引用；
- 检查中文手册中的脚本、参数、默认值和路径与当前源码一致；
- 运行 `git diff --check`；
- 文档重构不触发 IBAMR 重新编译或长时间模拟。

## 提交范围

只提交 skill、其 references、中文手册、英文入口和本设计/实施计划。保留并排除
现有未跟踪文件 `docs/superpowers/plans/2026-08-03-node3-smarties-uv-install.md`。

