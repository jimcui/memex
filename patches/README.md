# memex custom 分支 · 定制补丁集

**上游仓库**：memex-lab/memex（fork 至 jimcui/memex）
**分支**：custom
**基线**：本目录补丁基于  生成，custom 分支当前跟随 main

## 目录内容

| 文件 | 说明 | 基线 |
|---|---|---|
| Memex_自定义文件夹补丁.diff | 自定义数据文件夹（AndroidManifest + 文件系统服务） | cf5dff4 |
| Memex_v3_完整补丁.diff | v3 综合补丁 | cf5dff4 |
| Memex_v4_空助手消息修复.diff | 修复空助手消息（openai_client.dart） | dart_agent_core-2.1.6 |
| Memex_补丁_基线cf5dff4_v5.1_20261028.diff | **v5.1 完整补丁集**（42 文件，1666 行） | cf5dff4 |
| rebuild_memex.sh | 构建脚本（早期版） | — |
| rebuild_memex_v5.1_20261028.sh | 构建脚本（v5.1） | — |

## 使用方式



## 已知情况

- 补丁基于 ，custom 分支 HEAD 为 （2026-11-01 同步 main）。**直接 apply 可能冲突**，需按上面步骤先切基线
- v4 补丁的基线是 dart_agent_core-2.1.6 原版文件，路径带时间戳后缀，apply 前需手工修正
- 签名密钥**不在本仓库**（VaultMate-release.keystore / xplore_v5.1_20261028.ks 未提交），构建需自备
