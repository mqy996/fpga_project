# 250/500/1000 kSPS切换说明

## 配置流程

采样率是现有 `SET_CONFIG` 28字节负载中的 `SampleRate` 字段，单位为
samples/second。FPGA只接受：

| 字段值 | 采样率 | 32 MHz分频 |
|---:|---:|---:|
| `250000` | 250 kSPS | 128 |
| `500000` | 500 kSPS | 64 |
| `1000000` | 1 MSPS | 32 |

`SET_CONFIG`在READY状态返回成功后应用新配置，但不写Flash；`SAVE_CONFIG`
才会把当前配置写入A/B参数区。应用配置时会重新清ARP、清FIFO并等待READY，
因此下一次SW1启动的整个会话只使用一个采样率。

## 采集流水

每片AD7606C采用以下时序：

1. 每个采样节拍发出一次CONVST；
2. 同步后的BUSY下降表示本次转换结果寄存器已更新，并启动V1～V8读取，通道索引从V1归零；
3. 下一次CONVST仍按采样节拍启动，可与上一帧读取并行；读取必须在下一次BUSY下降前完成；
4. 每帧读取时同时检查FRSTDATA：V1读字必须为高，后续V2～V8必须为低；标记错位时丢弃该帧并停止采集，ADC1/2/3分别报告错误码`0x31`/`0x32`/`0x33`；
5. 三片均完成读取后组合成一个384位采样组；
6. 完整采样组成功写入FIFO时，`sample_monitor`输出一个脉冲。

FRSTDATA板级输入分别约束到ADC1 `K15`、ADC2 `F14`、ADC3 `G6`。FRSTDATA不负责移动数据或猜测通道映射，而是确认每帧第一个并行读字确为V1，避免未对齐帧作为有效采样上传。

当前默认RD低电平为2个32 MHz周期、高电平为1个周期。1 MSPS 定向仿真按数据手册最大转换时间取 BUSY 高电平21个时钟，
采样间隔为32个时钟；连续12帧均按V1～V8顺序完成，且最后一个RD下降沿至少早于下一次BUSY下降7个时钟
（约219 ns）。数据手册要求在读期间，最后一个RD下降沿至少早于下一次BUSY下降25 ns。
如果BUSY下降时上一帧仍在读取，或BUSY超时，ADC错误锁存，系统停止新增采样和UDP数据，避免输出撕裂数据。

## 上位机示例

```powershell
# 运行时切到250 kSPS
.\pc_tools\fpga_param_cli.exe set-config --bind 192.168.0.3 --ip 192.168.0.2 `
  --local-ip 192.168.0.2 --mask 255.255.255.0 --target 192.168.0.3 `
  --port 56555 --rate 250000 --channels 0x00ffffff --groups 30

# 查询并持久化
.\pc_tools\fpga_param_cli.exe get-config --bind 192.168.0.3 --ip 192.168.0.2
.\pc_tools\fpga_param_cli.exe save --bind 192.168.0.3 --ip 192.168.0.2
```

监测工具的 `--sample-rate` 必须与配置一致，否则会报告头字段错误：

```powershell
.\pc_tools\adc_udp_monitor.exe --bind 192.168.0.3 --sample-rate 250000 --seconds 10
.\pc_tools\adc_udp_monitor.exe --bind 192.168.0.3 --sample-rate 500000 --seconds 10
.\pc_tools\adc_udp_monitor.exe --bind 192.168.0.3 --sample-rate 1000000 --seconds 10
```

24通道、30组/包时，UDP有效载荷仍为1452字节；理论包速率约为8333、
16667和33333包/s。实际验收应同时测量M4上的`sample_monitor`，确认它分别
接近250 kHz、500 kHz和1 MHz。

## STOP行为

SW2不会截断正在发送的以太网帧。它禁止新的CONVST和新UDP帧，等待当前读操作
及已启动的MAC帧到达安全边界，然后清空FIFO并回到READY。再次SW1时SeqNum从1
重新开始。
