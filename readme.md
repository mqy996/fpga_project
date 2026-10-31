# 24通道同步数据采集与千兆以太网传输系统

我们面向多通道高速信号采集与实时传输场景，设计了一套基于 AMD Artix-7 XC7A100T FPGA 的采集系统。系统使用三片 AD7606C-16，支持 24 通道同步采集，采样率可在 250 kSPS、500 kSPS 和 1 MSPS 三档切换。

FPGA 完成 ADC 时序控制、通道数据拼接、跨时钟域传输与 FIFO 缓存，并通过 RGMII 连接千兆以太网 PHY。板端以 RTL 实现 Ethernet、ARP、IPv4、UDP 和 ICMP 协议功能，以及带 CRC 校验的 Flash 参数双备份。配套 Qt 上位机提供设备发现、参数配置、实时波形、接收统计和 24 路 TXT 记录。实时采集与传输数据通路不依赖 CPU 或软核。

## 项目内容

| 目录 | 主要内容 |
| --- | --- |
| `fpga/` | 正式工程的 39 个 RTL 文件、约束、两个定向仿真、构建脚本、Vivado 工程、已验证镜像和实现报告 |
| `qt/` | 上位机 C++ 源码、三个现有测试及 CMake 构建文件 |
| `build/` | 上位机构建和便携部署脚本 |
| `board/` | 最终 TXT 版上位机 EXE，以及既有 QSPI 写入和启动日志 |
| `sim/` | 复现检查、定向仿真结果及历史验证记录 |
| `data/` | 测试照片、录屏截图和 TXT 抽检记录 |
| `skill/` | 从 ADC 帧对齐、CDC、Flash 和 UDP/TXT 检查中提炼的可复用技能包 |
| `report/` | 设计报告、大模型协作记录及相关现场材料 |
| `reference/` | 最终工程中未进入正式构建闭包的源码、其他测试和历史辅助脚本 |
| `docs/` | 赛事提交核对、第三方组件说明和文件来源 |

仓库地址：<https://github.com/mqy996/fpga_project>。仓库路径使用英文小写；CMake 所需的 `CMakeLists.txt` 由构建脚本在 `build_output/` 中生成。技能入口在提交包中命名为 `skill.md`，安装到 Codex 时按 `skill/readme.md` 的说明改为 `SKILL.md`。

## 版本与运行环境

正式 FPGA 源码与已验证的 task-005 工程闭包一致。随包 BIT、BIN、MCS 来自 2026-10-10 的完整实现版本；对应 BIN 为 1,893,212 字节，曾完成 QSPI 写入与校验。旧工作区 `Final_pro/output/release` 中的镜像属于另一较早版本，不作为本次发布镜像。

`board/qt_portable/qtcontrolhost_v6.exe` 是最终 TXT 版上位机，其 SHA-256 为 `42a3f9889d73a9c2a69eb093ea1ccaf4fd14da9213d955346004fbe020e2a889`，与原 `QtControlHost_v6_txt` 目录及 `build_v6` 中的 EXE 逐字一致。完整本地代码包附有该程序原有的 DLL 和插件；GitHub 仓库提供项目源码与自有 EXE，可按下述步骤部署运行库。

复现环境为 Windows PowerShell、Vivado 2025.1、Qt 6.8.3 MinGW 64 位版、MinGW 13.1、CMake 和 Ninja。请将 `VIVADO_HOME`、`QT_ROOT` 和 `MINGW_BIN` 设置为本机安装目录，并将 CMake 和 Ninja 加入 PATH；也可通过上位机构建脚本参数指定工具位置。

## 构建与使用

在仓库根目录执行以下命令。路径仅为示例，请先修改环境变量以匹配本机安装位置。

```powershell
$env:VIVADO_HOME='D:\vitis\2025.1\Vivado'
$env:QT_ROOT='D:\Qt\6.8.3\mingw_64'
$env:MINGW_BIN='D:\Qt\Tools\Tools\mingw1310_64\bin'
powershell -ExecutionPolicy Bypass -File ./fpga/scripts/run_pipeline_sim.ps1
powershell -ExecutionPolicy Bypass -File ./fpga/scripts/create_project.ps1
powershell -ExecutionPolicy Bypass -File ./fpga/scripts/validate_project.ps1
powershell -ExecutionPolicy Bypass -File ./fpga/scripts/build_minimal.ps1
powershell -ExecutionPolicy Bypass -File ./build/build_qt.ps1
powershell -ExecutionPolicy Bypass -File ./build/deploy_qt.ps1
```

前两项定向仿真和 Vivado 工程校验不访问板卡；完整 FPGA 构建在 `fpga/output/` 下生成新的时间戳目录，并保留帧缓存 RAM 的实现 hook。历史实现报告仍有外部 I/O 约束覆盖限制，详见 `sim/historical_validation.md`。上位机部署完成后，可从 `build_output/qt_portable/` 运行。

连接目标板和 JTAG 后，可按 `fpga/readme.md` 中的步骤加载镜像。QSPI 写入脚本检查镜像边界，并按镜像覆盖范围擦写，保留参数区；请先确认所连接的目标板和镜像版本。

将电脑千兆网卡配置在设备网段，例如 `192.168.0.3/24`。设备默认地址为 `192.168.0.2`，控制 UDP 端口为 56556，数据 UDP 端口为 56555。发现设备并读取配置后，可从 250 kSPS、24 路上传、每包 30 组开始采集，再按需切换档位。详细操作和参数说明见 `qt/readme.md`。

如需保存 TXT，请在开始采集前选择保存路径，并启用全部 24 路上传。停止采集并完成收尾后生成文件，每行共 51 列：包序号、样本索引、相对时间，以及 24 路码值和电压。相对时间由包序号和采样率重建，并非硬件绝对时间戳。

## 验证结果与边界

已保存的实现报告记录 LUT 10,194、FF 12,357、6 个 RAMB36 等效资源，WNS 为 +0.217 ns，WHS 为 +0.046 ns，DRC 为 0 Error、5 Warning。两项 ADC 定向仿真、Qt 三项现有测试和 Skill 合成样例检查的结果见 `sim/current_validation.json` 与相应日志。既有完整 smoke 中，`runtime_config_manager` 曾超时而脚本返回 0，因此不能将整套 smoke 表述为全部通过。

团队已确认三档持续采集、冷启动、参数恢复和 TXT 写盘功能正常；这些确认未附完整时长和量化统计。测试仪器一次只能向一组八路输入受控信号，三组分别接入 ADC1 的 CH00–07、ADC2 的 CH08–15 和 ADC3 的 CH16–23。现场参数保存与恢复画面实际为 500 kSPS、22 路上传、每包 28 组、Sequence 7。两份大 TXT 文件各只检查了前 10,000 行。

当前材料尚缺同条件的优化前后量化对照，以及统一的整机模拟精度、功耗和跨 ADC 同步偏差测量。视频格式和上传限制以 FPGA 赛道实际提交页面为准。

## 许可与来源

项目自有代码、文档和技能采用 MIT 许可，见 `license`。AMD/Vivado、Qt、MinGW 和 Windows 组件遵循各自许可；第三方运行库的说明见 `docs/third_party.md`。文件来源和校验值见 `docs/source_provenance.json` 与 `sha256sums.txt`。
