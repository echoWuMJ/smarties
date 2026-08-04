# node3 smarties + uv 安装记录

记录日期：2026-08-03
服务器：`node03`（CentOS 7，x86_64，glibc 2.17）

## 1. 当前结论

node3 上已经完成以下基础安装：

- 本地 smarties 工作树已打包、上传并解压到 `/data2/mjwu/local/smarties`。
- `uv 0.12.1` 已安装到 `/data2/mjwu/local/uv/bin`。
- uv 管理的 `CPython 3.12.13` 已安装到 `/data2/mjwu/local/uv/python`。
- smarties 项目环境为 `/data2/mjwu/local/smarties/.venv`，其中已安装 `psutil==5.9.8`。
- smarties C++ 核心库已经编译为 `/data2/mjwu/local/smarties/lib/libsmarties.so`。
- `apps/cart_pole_cpp/exec` 已使用 OpenMPI 5.0.9 编译成功。
- `smarties.py --help` 可以由 Python 3.12 环境正常执行。

当前仍有一个不能忽略的运行限制：smarties 的 fork 型环境进程在训练结束后会卡在 OpenMPI 5.0.9 的 `MPI_Finalize()`。因此本记录不把 cart-pole 的端到端训练退出验证标为通过。IBAMR 耦合应优先采用显式 MPI worker/environment ranks，避免 smarties 的 fork 路径；该路径仍需结合真正的 IBAMR adapter 做独立验证。

## 2. 安装路径和版本

| 项目 | 实际值 |
|---|---|
| smarties 源码 | `/data2/mjwu/local/smarties` |
| smarties 构建目录 | `/data2/mjwu/local/smarties/build-node3` |
| smarties C++ 库 | `/data2/mjwu/local/smarties/lib/libsmarties.so` |
| uv | `/data2/mjwu/local/uv/bin/uv`，版本 0.12.1 |
| uv Python 安装目录 | `/data2/mjwu/local/uv/python` |
| 项目虚拟环境 | `/data2/mjwu/local/smarties/.venv` |
| Python | 3.12.13 |
| Python 包 | `psutil==5.9.8` |
| GCC/G++ | 8.5.0 |
| CMake | 3.30.6 |
| OpenMPI | 5.0.9 |
| BLAS | PETSc 3.23.3 自带 OpenBLAS 0.3.29 |

本地源码压缩包：

```text
/data2/mjwu/Downloads/smarties-offline/smarties-local-34c53d1.tar.gz
SHA256: 0d089568b6f9ac1f8f09606faf12b55f1a986acb38470b38a3ad030ea74ec9fd
```

uv 二进制缓存：

```text
/data2/mjwu/Downloads/smarties-offline/uv-x86_64-unknown-linux-musl.tar.gz
SHA256: 47823f814693bab8623308341369190de30b5c621eec5b1ee20352eae8c7982c
```

## 3. Python 环境

Python 3.12 由 uv 通过 npmmirror 的 python-build-standalone 镜像安装：

```bash
export UV_PYTHON_INSTALL_DIR=/data2/mjwu/local/uv/python

/data2/mjwu/local/uv/bin/uv python install 3.12 \
  --mirror https://registry.npmmirror.com/-/binary/python-build-standalone

cd /data2/mjwu/local/smarties
/data2/mjwu/local/uv/bin/uv venv --python 3.12 .venv

/data2/mjwu/local/uv/bin/uv pip install \
  --python .venv/bin/python \
  --index-url https://pypi.tuna.tsinghua.edu.cn/simple \
  psutil==5.9.8
```

验证结果：

```text
uv 0.12.1 (x86_64-unknown-linux-musl)
Python 3.12.13
psutil 5.9.8
physical_cpus=52
```

本次没有编译可选的 Python C++ extension：

```text
COMPILE_PY_SO=OFF
```

原因是本地工作树中的 `source/extern/pybind11` 子模块为空。当前 IBAMR 耦合目标直接使用 C++ `libsmarties.so`，Python 环境用于 `smarties.py` 和后续实验脚本。

## 4. C++ 构建配置

```bash
export PATH=/data2/mjwu/local/gcc-8.5.0/bin:/data2/mjwu/local/openmpi/bin:/data2/mjwu/autoibamr/packages/cmake-3.30.6/bin:$PATH

cmake -S /data2/mjwu/local/smarties \
      -B /data2/mjwu/local/smarties/build-node3 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCOMPILE_PY_SO=OFF \
  -DCMAKE_C_COMPILER=/data2/mjwu/local/openmpi/bin/mpicc \
  -DCMAKE_CXX_COMPILER=/data2/mjwu/local/openmpi/bin/mpicxx \
  -DCMAKE_CXX_FLAGS=-I/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/include \
  -DBLAS_LIBRARIES=/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib/libopenblas.so \
  -DCMAKE_BUILD_RPATH=/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib

cmake --build /data2/mjwu/local/smarties/build-node3 --parallel 8
```

CMake 实际识别结果：

```text
GNU C/C++ 8.5.0
MPI C/CXX 3.1 API via OpenMPI 5.0.9 wrappers
OpenMP 4.5
BLAS=/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib/libopenblas.so
COMPILE_PY_SO=OFF
```

构建完成输出：

```text
[100%] Built target libsmarties
/data2/mjwu/local/smarties/lib/libsmarties.so (约 1.8 MB)
```

cart-pole 示例构建命令：

```bash
export PATH=/data2/mjwu/local/gcc-8.5.0/bin:/data2/mjwu/local/openmpi/bin:$PATH
SMARTIES_ROOT=/data2/mjwu/local/smarties \
  make -C /data2/mjwu/local/smarties/apps/cart_pole_cpp \
  clean exec CXX=/data2/mjwu/local/openmpi/bin/mpicxx
```

## 5. 使用环境

每次使用 smarties 前执行：

```bash
export SMARTIES_ROOT=/data2/mjwu/local/smarties
export UV_PYTHON_INSTALL_DIR=/data2/mjwu/local/uv/python

export PATH=/data2/mjwu/local/uv/bin:$SMARTIES_ROOT/.venv/bin:/data2/mjwu/local/gcc-8.5.0/bin:/data2/mjwu/local/openmpi/bin:/data2/mjwu/autoibamr/packages/cmake-3.30.6/bin:$PATH

export LD_LIBRARY_PATH=$SMARTIES_ROOT/lib:/data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib:/data2/mjwu/local/gcc-8.5.0/lib64:/data2/mjwu/local/openmpi/lib:${LD_LIBRARY_PATH:-}
```

验证 Python 启动器：

```bash
$SMARTIES_ROOT/.venv/bin/python $SMARTIES_ROOT/bin/smarties.py --help
```

## 6. 动态链接验证

`libsmarties.so` 和 `apps/cart_pole_cpp/exec` 的所有依赖均可解析，没有 `not found`。关键依赖实际解析到：

```text
libopenblas.so.0 -> /data2/mjwu/autoibamr-v0.18.0/packages/petsc-3.23.3/lib/libopenblas.so.0
libmpi.so.40     -> /data2/mjwu/local/openmpi/lib/libmpi.so.40
libstdc++.so.6  -> /data2/mjwu/local/gcc-8.5.0/lib64/libstdc++.so.6
libgomp.so.1    -> /data2/mjwu/local/gcc-8.5.0/lib64/libgomp.so.1
libgfortran.so.5 -> /data2/mjwu/local/gcc-8.5.0/lib64/libgfortran.so.5
```

注意：不要用新的值覆盖整个 `LD_LIBRARY_PATH`。必须保留 GCC 8.5/OpenMPI 的原有目录，否则 CentOS 7 会误用系统旧版 `libstdc++.so.6`。

## 7. 端到端运行阻塞

两个 MPI ranks 的 CLI 初始化已经成功，smarties 可以打印完整参数和算法配置。`--help` 路径由示例代码明确写成：

```cpp
if (e.parse()) return 1;
```

因此帮助信息退出码 1 是示例自身的既有行为，不代表动态链接失败。

真实短训练可以完成以下阶段：

- 环境与 master 建立连接；
- 状态维度和动作维度注册成功；
- VRACER 网络创建成功；
- 收集到开始训练所需的全部数据；
- fork 环境打印 `App recvd end-of-training signal.`。

但是进程没有在 60 秒内退出。对残留进程执行 `gstack` 得到：

```text
#0 nanosleep()
#1 usleep()
#2 ompi_mpi_finalize() from OpenMPI 5.0.9 libmpi.so.40
#3 smarties::ExecutionInfo::~ExecutionInfo()
#4 smarties::Engine::~Engine()
#5 main()
```

代码根因是 smarties 先执行 `MPI_Init`，随后在 `Launcher::forkApplication()` 中 `fork()`；fork 子进程返回后，`ExecutionInfo::~ExecutionInfo()` 无条件执行 `MPI_Finalize()`。该 fork 后 finalize 路径在当前 OpenMPI 5.0.9 上无法正常结束。

已经清理本次验证遗留的孤儿 `exec` 进程；诊断日志保留在：

```text
/data2/mjwu/local/smarties/runs/install-smoke-20260803*
```

## 8. 后续处理建议

1. IBAMR 环境应采用 smarties 的显式 MPI environment ranks，即 `workerProcessesPerEnv >= 1`，不要使用 `forkApplication()`。
2. 在开始 IBAMR 长训练前，为 IBAMR adapter 做一个 1-10 步的完整启动、交互和正常退出测试。
3. 如果必须运行 fork 型 Python/C++ 环境，需要单独处理 OpenMPI 5 兼容性。候选方案是让 fork 子进程在环境 callback 返回后使用 `_exit(0)`，避免在 fork 子进程中调用 MPI 析构/finalize；这是源代码行为修改，本次没有擅自应用。
4. 另一候选方案是准备与该旧版 smarties 年代更接近的独立 MPI 版本，但不要替换现有 IBAMR 的 OpenMPI，避免破坏 IBAMR 工具链一致性。
