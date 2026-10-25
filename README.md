# Taikong VPS Manager

面向 VPS 的模块化 Bash 管理工具。

## 当前版本

0.1.0

## 当前功能

- Debian/Ubuntu 系发行版识别
- RHEL 系发行版识别
- CPU 架构检测
- 包管理器检测
- systemd 检测
- 自动化基础测试

## 安全说明

当前版本只读取系统信息，不安装软件，不修改 SSH、
防火墙、主机名或其他系统配置。

## 使用方法

```bash
chmod +x install.sh manager.sh tests/run.sh
./install.sh
./manager.sh
