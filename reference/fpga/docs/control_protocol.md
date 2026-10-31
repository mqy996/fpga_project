# UDP控制协议（版本1）

控制端口固定为UDP 56556，数据端口缺省为56555。所有多字节整数均按网络字节序发送。

## 公共头

每个请求和响应均以16字节公共头开始：`Cmd(4) + Status(4) + DataLength(4) + TransactionId(4)`。请求的Status必须为0；响应Cmd等于请求Cmd与`0x80000000`按位或。相同源MAC/IP/端口、Cmd和TransactionId的重试不会再次执行SAVE等副作用。

状态码：0 OK，1 INVALID_CMD，2 INVALID_LENGTH，3 INVALID_PARAM，4 INVALID_STATE，5 BUSY，6 UNSUPPORTED，7 FLASH_ERROR，8 VERIFY_ERROR，9 TIMEOUT。

## 命令

| Cmd | 名称 | 请求数据 | 成功响应数据 |
|---:|---|---|---|
| 1 | DISCOVER | 无 | 32字节设备摘要 |
| 2 | GET_INFO | 无 | 72字节设备、网络和Flash摘要 |
| 3 | SET_CONFIG | 28字节配置 | 40字节当前配置 |
| 4 | START | 无 | 在READY启动采集；RUN返回OK且不重置会话；其他状态返回INVALID_STATE。与SW1采用“或”关系。 |
| 5 | STOP | 无 | 在RUN停止；READY/STOPPING返回OK且不重复收尾；ERROR返回INVALID_STATE。与SW2采用“或”关系，STOP优先。 |
| 6 | GET_STATUS | 无 | 64字节运行状态 |
| 7 | GET_CONFIG | 无 | 40字节当前配置 |
| 8 | SAVE_CONFIG | 无 | 12字节Sequence/副本/Flash状态 |
| 9 | RESTORE_DEFAULT | 无 | 40字节默认配置；不自动保存 |
| 10 | GET_FLASH_INFO | 无 | 24字节JEDEC/副本/Sequence/错误 |

SET_CONFIG的28字节数据为：本机IP(4)、掩码(4)、目标IP(4)、数据端口(2)、保留(2，必须0)、采样率(4)、通道掩码(4)、每包组数(4)。首版采样率只接受500000。通道掩码仅使用低24位且不能全0。每包组数为1至30，并要求`12 + 2*popcount(mask)*groups <= 1472`。

SET_CONFIG成功响应先通过旧地址完整发出，MAC完成FCS和IFG后才原子切换配置。切换后清ARP、重学目标MAC并重新清FIFO。若改变了本机IP，后续命令必须发往新地址。

DISCOVER可发至`255.255.255.255:56556`或网卡所在子网的定向广播地址。FPGA直接使用请求帧的源MAC、IP和源端口响应，不依赖ARP缓存，因此可用于忘记设备IP后的恢复。

## Flash记录

参数A首Sector为`0x800000`，参数B首Sector为`0xC00000`。64字节记录由32字节头、28字节配置和4字节填充组成。Magic为`ADCF`，格式版本1，HeaderLength 32，PayloadLength 28，Commit为`0xC04D4D17`。CRC使用CRC-32/ISO-HDLC。PayloadCRC覆盖28字节配置；HeaderCRC依次覆盖头字节0..19和Reserved字节28..31，不覆盖HeaderCRC字段和Commit字段。Commit在完整记录写入并读回正确后单独最后写入。
