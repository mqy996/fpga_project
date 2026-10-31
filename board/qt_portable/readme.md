# 最终 TXT 版上位机

`qtcontrolhost_v6.exe` 是团队最终使用的 TXT 版上位机，文件内容与原发布目录中的 EXE 完全一致。

完整代码压缩包同时包含原发布目录中的 DLL 和插件。解压后请保留目录结构，直接运行该 EXE。GitHub 仓库提供自有 EXE 和源码；从仓库获取时，可执行 `build/build_qt.ps1` 和 `build/deploy_qt.ps1` 构建并部署运行库，也可使用 Qt 6.8.3 的 `windeployqt` 部署。功能和操作步骤见 `qt/readme.md`。
