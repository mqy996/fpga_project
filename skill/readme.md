# FPGA acquisition evidence skill pack

本包把“ADC帧首错位 → 采样/网络跨域边界 → UDP接收与TXT写盘 → 构建版本核对”中的经验提炼为可复用工作流和只读校验工具。适用于并行ADC、多通道FPGA采集、UDP主机接收和分区Flash交付；不绑定某块板卡的引脚。它不是PYNQ Overlay/DMA技能，不声称获得通用PYNQ技能加分。

## 提交与安装的文件名约定

赛事指南3.3.5.2要求`skill/README.md`，同指南3.3.5.4又要求所有文件名小写。为统一遵守小写路径，本提交以`skill/readme.md`对应README说明，以`fpga-acquisition-evidence/skill.md`保存Codex入口正文。赛事推荐目录不是强制结构；此处给出明确对照。

提交包可直接阅读、执行脚本；**它不是未经转换即可被Codex发现的安装目录**。在用户另行决定安装后，将`fpga-acquisition-evidence/`复制到用户选择的技能目录，再在该安装副本将`skill.md`重命名为`SKILL.md`。Windows可先改名为`entrypoint.tmp`再改为`SKILL.md`，避免仅改大小写时的文件系统歧义。Codex要求这个大写入口；不要同时保留大小写两个入口。本任务未安装技能、未修改任何全局配置。`agents/openai.yaml`是可选元数据，本包不包含它。

## 适用范围、方法、效果与失效条件

| 项目 | 适用范围和使用方法 | 已验证效果 | 失败/观察来源与失效条件 |
| --- | --- | --- | --- |
| 帧首诊断工作流 | 并行ADC存在固定通道循环偏移时，按`references/adc-frame.md`建立BUSY、读帧、FRSTDATA与物理通道映射 | 原工程定向仿真通过12帧1MSPS及首字FRSTDATA错误拒收；用户逐路确认通道顺序正确 | 来自读帧触发与结果更新错配的观察；不同ADC的FRSTDATA语义和时序须重建，不能照抄引脚/周期 |
| CDC/Flash边界工作流 | 按`references/cdc-flash.md`检查整组握手、复位、背压和参数A/B提交顺序 | 原工程具有整组异步FIFO、地址白名单、CRC与最后提交设计；用户确认正常保存恢复与冷启动通过 | 参数A/B不是启动镜像A/B；未做任意断电故障注入/寿命认证，普通保存恢复不能替代此测试 |
| UDP校验/吞吐预算 | 使用`check_udp.py`检查JSONL中的纯UDP应用负载，或计算理论链路预算 | 合成回绕、重复、乱序、缺口和坏包验证，见`validation.json` | 来自接收序号连续不等于ADC持续采样的边界；固定12字节头，协议不同需适配；不直接读取pcap |
| TXT流式校验 | 使用`check_txt.py`检查现有51列格式、序号构造、时间列和码值/电压关系 | 小型正常/错误/回绕/截断扫描样例均有自动断言，见`validation.json` | 来自大文件、独立写盘队列和格式误认风险；仅适配全24通道布局，不能据此证明真实持续写盘速率 |
| 构建交付核对 | 使用`check_build.py`核对显式清单的SHA256、原始BIN分区边界与报告头字段 | 正常、越界、错误工具版本、错误哈希和输入缺失样例通过预期判定 | 来自旧release/旧报告与新镜像混用风险；不解析bit/MCS烧写地址，不检查烧写擦除策略，不替代构建溯源 |

“原工程”依据来自随作品报告整理的task004、task006和task008记录及当前源码。2026-10-22用户补充确认：最新版三档250/500/1000 kSPS、全24通道持续采集、整板冷启动、保存参数恢复及TXT写盘均测试正常。该条属于**用户确认通过**；未附本轮原始日志、测试时长和故障注入数据。本包没有据此编造量化验收结果。合成fixtures仅验证脚本行为，不是板上采样记录。

## 陌生队伍从零使用

需要Python 3.10或更新版本，仅使用标准库。以下命令从`skill/`目录执行，`python`替换为实际Python路径。所有工具只读输入，JSON结果输出到stdout；退出码0表示本次检查通过，1表示有效输入中发现校验问题，2表示调用/输入读取/清单结构失败。非零返回不得写成通过。

```powershell
python fpga-acquisition-evidence/scripts/check_udp.py budget --rate 1000000 --mask 0xffffff --groups 30
python fpga-acquisition-evidence/scripts/check_udp.py check --input fpga-acquisition-evidence/fixtures/udp-observation.jsonl --groups 2
python fpga-acquisition-evidence/scripts/check_txt.py --input fpga-acquisition-evidence/fixtures/txt-good.txt --rate 500000 --groups 2
python fpga-acquisition-evidence/scripts/check_build.py --manifest fpga-acquisition-evidence/fixtures/build-good.json
python fpga-acquisition-evidence/scripts/validate_examples.py
```

前三个校验脚本不会写文件、联网、调用Vivado/Qt或访问板卡；最后的验证驱动只重写包内`validation.json`，不触碰工程源码。保存实际检查输出可由调用方用stdout重定向完成。不要将扫描上限结果描述为全文件通过。

随包的`fpga-acquisition-evidence/validation.json`记录本次实际执行的22项断言结果（22/22符合预期），`package-validation.json`记录Codex入口校验、Python语法、相对链接及小写路径检查。入口校验在临时副本转换成`SKILL.md`后完成并删除临时目录；指定Python运行时缺少PyYAML时，只读借用了本机已有依赖，没有安装到全局。`validation-history.json`保留首次20/22的fixture哈希失败及修正：Windows写入CRLF后应对实际落盘字节计算SHA256，不能用写入前的LF字符串替代。全部测试均为合成数据，未测大文件性能。

默认UDP配置是本项目的24位掩码、三档采样率、1～30组、MTU1500；其它相同头格式的项目可显式设置`--channels`、`--rates`、`--max-groups`、`--mtu`。TXT工具可设置`--rate`、`--groups`、`--full-scale`、`--tolerance`，但表头固定24路，改变布局需适配代码。构建工具的分区、期望哈希和报告字段均由清单给出，不把本板地址写死在脚本。

UDP JSONL每行如`{"payload_hex":"000000010007a120000000010001"}`，表示序号1、500000 SPS、掩码1、一个16位样本；只提供应用负载，不带IP/UDP头。序号分析假设一个无复位会话，步长小于2^31。`unobserved_within_sequence_span`仅指已扫描观察跨度内未见的序号；乱序包稍后补齐时会消除对应缺口，重复和乱序分别计数，不把临时跳号直接当作最终丢包。

构建清单的区间全部采用`[start, end_exclusive)`，详见`fixtures/build-good.json`。期望SHA256必须来自事先固定的目标版本；现算现填只能检查当前快照，不能证明它属于正确版本。报告头采用精确匹配，工具版本/器件格式不同时由队伍明确更新期望值。

## 可复用提示词

```text
使用 fpga-acquisition-evidence 分析这份采集工程和给定输出。
先建立协议/采样时序/Flash分区契约，只运行与给定输入匹配的只读检查。
把设计事实、仿真结果、工具结果、用户确认和原始板测证据分别列明。
遇到序号缺口、TXT时间跳跃或通道错位时，指出目前能区分的原因和最小补证动作。
输出实际扫描范围、返回码、观察结果和结论边界；没有原始输入就不要虚构测试通过。
```

本技能自有内容随本仓库采用MIT许可。使用本技能不等于获得操作其他项目硬件或发布其资料的授权。第三方复用前仍应核对其协议和硬件手册；项目修改、硬件操作或外部发布按该项目的已有授权执行。
