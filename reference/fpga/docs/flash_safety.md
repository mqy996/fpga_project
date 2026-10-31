# Flash分区与安全约束

- `0x000000..0x7FFFFF`：Bitstream，只允许Vivado/JTAG更新。
- `0x800000..0xBFFFFF`：参数A，首个4 KiB Sector投入使用。
- `0xC00000..0xFFFFFF`：参数B，首个4 KiB Sector投入使用。

用户RTL中不存在Chip Erase指令。Sector Erase和Page Program在发出命令前都经过地址白名单，当前白名单只有`0x800000`和`0xC00000`；Commit地址由白名单基地址加24产生。构建脚本在BIN达到`0x800000`时直接失败。JTAG脚本设置`PROGRAM.ADDRESS_RANGE=use_file`，并同样检查文件长度。

这三道边界彼此独立，但仍应按以下方式做实板回归：先SAVE并断电确认参数；再用保留参数脚本更新Bitstream；再次断电，确认Sequence和配置未变化。不要在Vivado Hardware Manager中选择“Entire Configuration Memory Device”或整片擦除。
