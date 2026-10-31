# task-004 验证记录

## ADC 流水与 FRSTDATA 仿真

- 工具：本机 Vivado Simulator 2025.1（`xvlog` → `xelab` → `xsim`）。
- 命令：`powershell -ExecutionPolicy Bypass -File .\co_project\Final_pro\ADC_transmission_flash_param_rate_project_clean\scripts\run_ad7606c_pipeline_sim.ps1`
- 正常帧测试通过：12 帧连续 1 MSPS 采集，BUSY 高电平模型为 21 个 32 MHz 时钟。每帧八个唯一数据字按 V1～V8 顺序进入缓冲，FRSTDATA 标记正确；CONVST 与 `sample_valid` 间隔均为 32 个时钟。
- 读时序余量：最后一个 RD 下降沿至少早于下一次 BUSY 下降 7 个时钟（约 219 ns），超过数据手册要求的 25 ns。
- 错位拒收测试通过：首字 FRSTDATA 故意为低后，控制器进入错误状态，不产生 `sample_valid`，也不会将该帧交给上层。

## Vivado 2025.1 完整实现与 bitgen

- 工程顶层：`fpga_adc_udp_flash_param_top`；器件：`xc7a100tcsg324-2`。
- 流程：RTL 综合 → 优化 → 布局 → 物理优化 → 布线 → 报告 → bitgen → BIN/MCS 配置镜像边界检查。完整输出目录：`D:\fpga+stm32_project\results\task004\final_bitstream\20261010_141613\`。
- 最终时序：WNS=`+0.217 ns`、TNS=`0`、WHS=`+0.046 ns`、THS=`0`；Vivado 报告 `All user specified timing constraints are met.`
- DRC：0 个 Error，5 个 Warning。Warning 为现有 RGMII RXC T11 非专用时钟布线约束、3 个未使用 Flash 输入缓冲和无负载诊断/计数网络；没有 FRSTDATA 引脚冲突。
- `report_io` 确认 `adc1_frstdata=K15`、`adc2_frstdata=F14`、`adc3_frstdata=G6`，均为 LVCMOS33 输入。
- 产物：`fpga_adc_udp_flash_param_rate.bit`（1,893,367 bytes）、`.bin`（1,893,212 bytes）、`.mcs`（5,325,168 bytes）和 `final_routed.dcp`。BIN/MCS 检查通过，结束地址 `0x1CE35C`，在 8 MiB 配置区内。
- BIT SHA-256：`340DB5026F4312BFD3241EC9B73359A9F777F1614DC8BF67C5F3683DBAF98307`。
- 构建脚本：`co_project/Final_pro/ADC_transmission_flash_param_rate_project_clean/scripts/build_task004_final_bitstream.ps1`；流程和清理说明见 `FPGA_BUILD.md`。

## 现有 smoke 仿真

此前运行项目 `scripts/run_smoke_sim.ps1` 时，LED、配置校验、UDP 最小帧、CDC 状态、系统运行控制、500 kSPS 顺序 ADC、1 MSPS 流水 ADC、采样率 CDC 和 START/STOP CDC 仿真均输出 PASS。其中 `tb_runtime_config_manager.v:39` 在 10 μs 报 `Fatal: timeout`，脚本仍返回 0，因此该整套 smoke 不能记作全绿；这个失败与本次 ADC 流水/FRSTDATA 修改无关。本次没有重跑整套 smoke。

## 验证边界

Vivado 2025.1 已识别板载 W25Q128JV（JEDEC `EF 40 18`），将本次 1,893,212 字节 BIN 写入并完成 Program/Verify；镜像结束地址为 `0x1CE35C`，仍在 `0x800000` bitstream 分区内。随后通过 `boot_hw_device` 从 QSPI 重新配置 FPGA，DONE=`1`。用户在该镜像部署后逐个测试通道，确认软件显示顺序与实际输入顺序一致。本次没有做整板断电后的冷启动确认，也没有重新采集同步 FRSTDATA/RD/BUSY 波形。

QSPI 分区和参数管理地址未改：A/B 参数区仍位于 `0x800000`、`0xC00000`；下载脚本使用 `PROGRAM.ADDRESS_RANGE=use_file`，参数分区不在此次擦写范围内。逐路通道顺序已由用户上板确认；根因定位有仿真、旧版 ILA 与修复后功能结果支持，但没有修复后同步 FRSTDATA/RD/BUSY 波形。
