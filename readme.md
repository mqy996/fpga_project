# 24通道同步采集与千兆以太网传输系统

基于 AMD Artix-7 XC7A100T-2CSG324I 和三片 AD7606C-16 的 FPGA 采集系统，支持每通道 250 kSPS、500 kSPS、1 MSPS。板端由纯 RTL 完成采样、CDC、FIFO、Ethernet/ARP/IPv4/UDP/ICMP 和 Flash 参数双副本管理；Qt 上位机完成设备发现、配置、实时波形、丢包统计与24路TXT记录。

仓库：https://github.com/mqy996/fpga_project 。发布快照日期：2026-10-31。

## 目录与提交内容

| 目录 | 内容 |
| --- | --- |
| fpga/ | 正式39个RTL、XDC、两个定向仿真平台、12个原脚本及可移植工具定位、XPR、已验证BIT/BIN/MCS、6份实现报告 |
| qt/ | 最新上位机全部C++源码、三个现有测试和cmakelists.txt |
| build/ | Qt从零构建与便携部署脚本 |
| board/ | 指定最终上位机EXE、历史QSPI写入/启动日志 |
| sim/ | 本轮复现结果及既有仿真/实现记录 |
| data/ | 现场原始录屏帧、照片、TXT前缀检查与来源索引 |
| skill/ | 可复用ADC帧首、CDC/Flash、UDP/TXT/版本检查技能包 |
| report/ | 设计报告、真实大模型协作节录与复现证据 |
| reference/ | 当前Final_pro中未进入正式闭包的模块、其他仿真、辅助CLI及历史脚本；不参与正式构建 |
| docs/ | 赛事提交核对、第三方说明与版本依据 |

所有提交路径采用英文小写。CMake工具要求的CMakeLists.txt由构建脚本在忽略的build_output目录生成；Codex技能入口skill.md安装到其他工程时再按说明改名为SKILL.md。指南推荐README.md与全小写规则的命名差异统一用readme.md说明。

## 最终版本依据

正式FPGA源文件与task-005已验证闭包一致。预编译镜像来自2026-10-10的完整实现和QSPI Program/Verify，BIN为1,893,212字节。不要使用原工作区Final_pro/output/release的2026-09-10旧镜像。FPGA工具版本为Vivado2025.1，按指南说明版本后使用可复现脚本。

最终上位机来自用户指定dist/QtControlHost_v6_txt，EXE SHA256为42a3f9889d73a9c2a69eb093ea1ccaf4fd14da9213d955346004fbe020e2a889，与当前build_v6输出逐字一致。board/qt_portable/qtcontrolhost_v6.exe为该已验证发布EXE。完整本地代码包还包含该目录原有动态库和插件；仓库只发布自有EXE和源码，Qt/MinGW等第三方运行库通过本机合法安装的Qt部署，不将项目MIT许可套用到第三方组件。

## 从零复现

1. 安装Windows PowerShell、Vivado2025.1、Qt6.8.3 MinGW64、MinGW13.1、CMake和Ninja。设置VIVADO_HOME、QT_ROOT和MINGW_BIN到实际安装目录；CMake/Ninja在PATH中，或给脚本对应参数。
2. 从仓库根目录运行以下命令。仿真和工程校验不访问板卡。

```powershell
$env:VIVADO_HOME='D:\vitis\2025.1\Vivado'
powershell -ExecutionPolicy Bypass -File ./fpga/scripts/run_pipeline_sim.ps1
powershell -ExecutionPolicy Bypass -File ./fpga/scripts/create_project.ps1
powershell -ExecutionPolicy Bypass -File ./fpga/scripts/validate_project.ps1
powershell -ExecutionPolicy Bypass -File ./fpga/scripts/build_minimal.ps1
powershell -ExecutionPolicy Bypass -File ./build/build_qt.ps1
powershell -ExecutionPolicy Bypass -File ./build/deploy_qt.ps1
```

3. FPGA完整构建在fpga/output下生成新时间戳目录。布线检查包括setup/hold、DRC和Flash镜像边界，保留preserve_frame_ram.tcl及OPT_DESIGN前置hook。已知当前报告仍有外部I/O约束覆盖限制，详见sim/historical_validation.md。
4. 接通目标板和JTAG后，按fpga/readme.md说明加载镜像。program_qspi.ps1仅擦写镜像文件范围并保留参数区；运行该命令会写硬件，应由实际操作者确认板卡后执行。本次材料整理未执行烧写。
5. PC千兆网卡设置为与设备相容的网段，例如192.168.0.3/24；设备默认192.168.0.2，控制UDP56556、数据UDP56555。发现设备后读取配置，先以250kSPS、24路上传、30组每包采集，再逐档切换。
6. 测试仪器每次外接一组八路受控信号，ADC1为CH00–07，ADC2为CH08–15，ADC3为CH16–23；24路硬件采集、上传掩码与显示选择是三个不同概念。保存演示的实际参数为500kSPS/22路上传/28组/Sequence7。
7. TXT记录须在采集前选定文件且24路上传全开。停止后生成最终文件，固定51列：包序号、样本索引、相对微秒时间、24组code/V。时间由序号和采样率重建，不是硬件绝对时钟。详见qt/readme.md。

## 验证与限制

已保存的实现结果为LUT10194、FF12357、6个RAMB36等效、WNS+0.217ns、WHS+0.046ns、DRC0Error/5Warning。新的复现检查见sim/current_validation.json及日志。已有整套smoke中runtime_config_manager曾超时但脚本返回0，不能称整套smoke全通过。两项ADC定向仿真、Qt测试、Skill样例及板级功能确认分别记录。

三档持续采集、冷启动、参数恢复和TXT写盘由团队确认；现场素材用于对应窗口的展示。两份TXT只扫描各前10000行，不能等同全文件校验。优化前后同条件的量化对照、整机模拟精度、功耗和跨ADC同步偏差尚未给出统一测量值。比赛视频格式与上传限制应以FPGA赛道实际提交页面为准。

## 开源与第三方

自有工程代码、脚本和技能采用MIT许可，见license。AMD/Vivado、Qt、MinGW和Windows组件仍受各自许可约束；vendor工具与运行库不属于本项目MIT授权。来源映射和逐文件校验见docs/source_provenance.json及sha256sums.txt。完整原始私人会话、缓存、巨大采集TXT和历史工程副本不进入本仓库。
