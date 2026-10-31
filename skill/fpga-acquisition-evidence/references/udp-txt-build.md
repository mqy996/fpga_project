# UDP, TXT and build checks

## UDP契约与序号解释

本例应用负载为大端`u32 sequence, u32 sample_rate, u32 channel_mask`，接着是`groups × enabled_channels`个16bit补码，先组后通道升序。组数不在头内，按`(payload_bytes-12)/(2×popcount(mask))`推导，并与外部配置核对。默认24位掩码、250000/500000/1000000 SPS、1～30组，IPv4无选项MTU1500。

转换pcap等输入时由调用方提取**指定源设备/会话**的UDP纯负载，不混入控制UDP、其它设备或IP/UDP头。工具不执行联网抓包。`fixtures/udp-observation.jsonl`演示回绕附近顺序`0xfffffffe, 0, 0xffffffff, 0, 2`：重复1、独立乱序1、正向回绕1，最后观测跨度内只缺序号1；最初跳号的一部分由乱序包补齐。

序号采用32bit串行数的就近展开，每次相对最高序号距离须小于2^31；相等半范围报错。设备复位/重启不能凭序号区分，须拆会话。未见序号可能来自采集边界、捕获丢失或网络丢失，不能仅凭输入归因。`ok`只表示载荷有效，序号缺口/重复是单列观察项。

理论预算：全24路30组负载1452byte，1MSPS为33333.33pps；原始样本384Mb/s，含UDP/IPv4/Ethernet/FCS/前导码/IFG的估算线速404.8Mb/s。250/500kSPS相应101.2/202.4Mb/s。小帧预算包含以太网最小帧填充。不含VLAN/IP选项/额外控制业务，不能把该计算当作测得的接收或磁盘速率。

## TXT契约

当前`csvrecorder.cpp`的表头是`packet_sequence, sample_index, time_us`，后接`CH00_code, CH00_V`至`CH23_code, CH23_V`，共51列，UTF-8可带BOM、制表符分隔。记录器要求全部24通道，故稀疏UDP掩码不能直接套此TXT检查器。

对每个文件从序号epoch0开始；正向32bit回绕增加epoch；延迟到达的回绕前包归上一epoch。每包`packet_sample_index=max(extended_sequence-1,0)×groups`，每行再加组内偏移；`time_us=floor(sample_index×1000000/rate)`。这些坐标由序号推导，不是独立硬件时间戳，丢包造成的时间空白不应压缩。

码值范围[-32768,32767]，默认`V=code×10/32768`，写出4位小数。检查器以0.000051V绝对误差覆盖四位量化；其它换算范围显式指定`--full-scale`。这不是增益/偏置标定。非递增样本索引单独报告，可能对应重复/乱序，不直接当内容格式失败；完整组块、码值范围、换算与时间公式不符会返回1。

`--limit N`只扫描前N条数据行，报告是否还有未扫描行、最后扫描行和scope；不能将prefix检查写成全文件验收。流式实现不把文件整体读入内存。单行损坏后的包块位置可能产生后续错误，先修复或定位最早错误，不把级联计数当独立故障数。

## 构建契约与报告

参考`fixtures/build-good.json`：`build_id`标识目标；`partitions`定义半开区间；`artifacts`为显式`path/kind/sha256`。`raw_image`还要`start/partition`，`report`还要`expected_headers`，可选`size_bytes`。相对路径以清单所在目录解析，可改为实际交付位置。期望值必须先由可信目标版本固定，不能边检查边改成观察值。

报告只在前80行查找Vivado风格`| 字段 : 值`，按字段精确比对版本、Design、Device、Design State等；器件在不同报告中的拼法可能不同，分别给出预期。哈希匹配证明字节一致，不能单独证明同一次运行来源。报告“Routed”且正WNS也不能替代检查no_input_delay/no_output_delay、DRC及板级时序。

失败来源：原工程存在旧文档“只支持500000”与当前三档实现不一致；旧截图/旧release不代表新镜像验收；曾有仿真timeout但外层脚本仍返回0。故报告必须读取实际结果、工具状态和版本，而非只看进程成功。这个包不解析所有Vivado错误、不重跑工具、不签核约束。
