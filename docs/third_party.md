# 第三方组件

本仓库MIT仅适用于项目自有源代码、文档和脚本。Vivado/XPM/7系列原语需使用AMD工具安装；本工程没有另行复制的XCI/BD第三方IP源文件。

Qt6.8.3 Core/Gui/Widgets/Network/Svg是动态依赖；本地完整包中的运行库按原发布目录复制，原始字节不改。GitHub源码仓库不分发这些第三方DLL；需要运行程序时，使用自行合法安装的Qt及windeployqt构建部署。Qt源代码与许可证见https://download.qt.io/archive/qt/6.8/6.8.3/ 和 https://www.qt.io/licensing/ 。MinGW运行库、D3Dcompiler_47与opengl32sw仍分别遵循其上游条款，不能套用项目MIT。

完整本地包附Qt6.8.3现有SBOM与MinGW原始许可用于识别依赖。它们的来源与许可记录不构成把第三方运行库改为MIT许可。
