# 第三方组件说明

本项目的 MIT 许可适用于我们提供的自有源代码、文档和脚本。Vivado、XPM 和 7 系列器件原语由 AMD 工具安装提供；工程未另行复制 XCI 或 BD 第三方 IP 源文件。

上位机动态依赖 Qt 6.8.3 的 Core、Gui、Widgets、Network 和 Svg 等组件。完整本地代码包保留原发布目录中的运行库和插件，文件内容未修改；GitHub 仓库提供项目源码和自有 EXE，运行库可通过 Qt 安装及 `windeployqt` 部署。

完整本地包附有 Qt 6.8.3 的 SBOM 与 MinGW 相关原始许可，便于识别依赖。Qt 源码和许可信息见 [Qt 6.8.3 源码归档](https://download.qt.io/archive/qt/6.8/6.8.3/) 和 [Qt 许可说明](https://www.qt.io/licensing/)。Qt、MinGW、D3Dcompiler_47 和 opengl32sw 各自遵循上游许可，项目 MIT 许可不改变其许可条件。
