# FPGA ADC 采集卡最小工程包

本包包含已修复通道顺序的 FPGA RTL、Vivado 工程、可复建脚本和已验证的 bitstream。工程针对 **Vivado 2025.1** 与 **`xc7a100tcsg324-2`**，顶层为 **`fpga_adc_udp_flash_param_top`**。

## 目录内容

- `rtl/`：从顶层递归得到的 39 个 RTL 源文件。
- `constraints/`：完整 XDC，含管脚、时钟、ADC 输入时序和配置启动参数。
- `vivado_project/fpga_adc_udp_flash_param_minimal.xpr`：可打开的 Vivado Project Mode 工程。
- `scripts/`：创建/校验工程、完整构建、仿真、清理生成物和 QSPI 写入脚本。
- `tb/`：1 MSPS 流水采集顺序及 FRSTDATA 防错 testbench。
- `bitstream/`：已通过 QSPI 写入与校验的 `.bit`、`.bin`、`.mcs`。
- `reports/`：对应已验证 bitstream 的时序、DRC、I/O 和资源报告。
- `source_manifest.txt` 与 `sha256sums.txt`：RTL 清单及包内文件校验值（校验文件自身除外）。

Vivado 2025.1 自带 XPM FIFO、Xilinx 器件原语和仿真器，无需额外 RTL/IP 仓库。工程不含完整的原始 `Final_pro` 目录、旧版顶层和未被当前顶层引用的模块。

## 固定配置

- ADC `FRSTDATA`：ADC1=`K15`、ADC2=`F14`、ADC3=`G6`。
- QSPI：W25Q128JV，SPIx4，启动 bitstream 从 `0x000000` 加载；参数 A 为 `0x800000–0xBFFFFF`，参数 B 为 `0xC00000–0xFFFFFF`。本次修复没有更改分区或启动配置。
- QSPI 写入默认使用 `.bin`；镜像保护脚本可检查 `.bin` 和 `.mcs`，并将数据/擦除范围限制在 bitstream 分区前 `0x800000` 字节内；参数区不在镜像地址范围内。
- 当前预编译 `.bin` 为 1,893,212 字节。随包的 bitstream 来自已在板上写入并通过校验的版本。

## 环境要求

- Windows PowerShell。
- Vivado 2025.1，默认安装路径 `D:\vitis\2025.1\Vivado\bin\vivado.bat`。
- QSPI 写入还需要连接目标板并可通过 JTAG 访问 XC7A100T。

如果Vivado安装位置不同，设置VIVADO_HOME环境变量；工具通过scripts/toolchain.ps1定位。

## 打开和校验工程

在解压后的 `fpga/` 目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validate_project.ps1
```

脚本使用本机 Vivado 2025.1 打开 `.xpr`，核对器件、顶层、39 个 RTL 源文件、XDC 和 frame RAM 实现 hook。要在 GUI 打开工程：

```powershell
& 'D:\vitis\2025.1\Vivado\bin\vivado.bat' .\vivado_project\fpga_adc_udp_flash_param_minimal.xpr
```

也可以运行 `./scripts/create_project.ps1` 重新生成 `.xpr`，再运行校验脚本。

## 从源文件重新构建

推荐使用随包的非工程模式构建脚本；它从 `rtl/` 和 `constraints/` 读取源文件，运行综合、布局布线、时序/DRC 检查，再生成 bit/bin/mcs：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_minimal.ps1
```

成功时会在 `output\<时间戳>\` 生成 `final_routed.dcp`、timing/utilization/DRC/CDC/methodology/I/O 报告及 `fpga_adc_udp_flash_param_rate.bit/.bin/.mcs`。脚本要求 setup/hold slack 均非负、DRC 无 Error，并检查镜像不越过 QSPI bitstream 分区。

清理某一次构建的输出：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\clean_output.ps1 -RunDirectory .\output\<时间戳>
```

清理脚本只允许删除 `output` 下单个直接子目录，并要求目录中存在 Vivado journal 和 bitstream。

## 仿真

运行两个随包 testbench：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_pipeline_sim.ps1
```

仿真器会检查 1 MSPS 流水帧顺序，并验证 FRSTDATA 不匹配时不会发布有效采样。仿真日志和 `xsim.dir` 会写在工程包目录。

## 将 bitstream 写入 QSPI

默认写入随包已验证的 BIN：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\program_qspi.ps1
```

也可指定从源文件新构建的 BIN：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\program_qspi.ps1 -ImagePath .\output\<时间戳>\fpga_adc_udp_flash_param_rate.bin
```

脚本默认检查并写入随包 BIN；也可传入其他经验证的 BIN 或 MCS。它会检查镜像边界、连接 JTAG、擦写/校验镜像覆盖的地址范围，并拒绝越过 `0x800000` 的镜像。需在目标板已连接且可被 Vivado Hardware Manager 识别时执行。

## 已有实现结果

随包报告对应已验证的路由后 bitstream：WNS=`+0.217 ns`、WHS=`+0.046 ns`、无 setup/hold 失败端点；DRC 有 0 个 Error（另有 Warning，详见 `reports/drc.rpt`）。I/O 报告确认 `adc1_frstdata=K15`、`adc2_frstdata=F14`、`adc3_frstdata=G6`。板上写入与 QSPI Verify 已通过，用户随后逐通道测试确认显示通道顺序正确。

## 失败恢复

1. 工程打开/校验失败：从 `fpga/` 目录运行 `scripts/create_project.ps1`，再运行 `scripts/validate_project.ps1`；若仍失败，查看 `vivado_project\validate_project.log` 和 `.jou`。
2. 综合或实现失败：保留本次 `output\<时间戳>`，查看其中的 `vivado.log`、`vivado.jou` 和已生成报告；修正源文件/约束后使用新的输出目录重跑，避免覆盖失败现场。
3. 时序或 DRC 门槛未通过：脚本会在生成最终 bitstream 前报错；根据输出报告修复后重新构建。
4. QSPI 写入失败：检查 JTAG 目标、板卡供电和 Vivado Hardware Manager 连接，再用已知有效 BIN 重试；脚本的地址保护和上界检查应保持开启，不要改为全片擦除。

