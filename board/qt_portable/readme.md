# 最终上位机

qtcontrolhost_v6.exe是用户指定QtControlHost_v6_txt目录中的最终EXE，原始字节未修改。完整本地代码包包含原目录动态库和插件，Windows文件名大小写不影响加载。

GitHub源码仓库不分发Qt/MinGW/Windows第三方DLL。克隆仓库后运行build/build_qt.ps1和build/deploy_qt.ps1，或从Qt6.8.3安装目录对EXE执行windeployqt。请将动态库及plugins目录与EXE整体部署。详细使用方式见qt/readme.md。
