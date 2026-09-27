# songyuan OS4.0.0.10：原厂 GKI 模块信任修复

这是针对 **songyuan / OS4.0.0.10.XGNCNXM / Android16 GKI 6.12.69 / 4K** 的显式可选配置，不是通用机型修复，也不能证明移动数据故障已经解决。

## 已确认的构建来源

- 框架提交：`e56479fa6e6eaad096c755026dae24fa709cda2e`。
- [成功构建 #6](https://github.com/zxr1154/LLAnyKernel3/actions/runs/36247703552)。
- Artifact ID：`10908209851`。
- 问题 ZIP SHA-256：`f470c7e8247d27be44ecc8e6a007ce1272c0e943466c8604de7ed6ba029afe7f`，与 Actions artifact 的 digest 完全一致。
- ACK：`5db86224e3c427ca56cb943d55a31e39eb7e22f2`，来自当次日志的 `android16-6.12-2026-03` 分支；**不是**之前本地另一次构建的 `b18aa09ef8e7`。
- SukiSU：`cf87e3f4ddd3f6e5464d85acf56aaa6950e70841`。

专用工作流保留该次构建的真实选项：网络增强与 hmbird 支持开启；BBG、SUSFS、ZRAM 扩展、Re-Kernel、Droidspaces、KPM、CVE 可选补丁关闭。自定义版本名与时间也保持一致。这里没有暗中恢复此前截图里的其他选项。

修复提交保留当前 `dev` 已有的框架更新；上述框架提交记录的是故障包来源，不表示把整个仓库回退到该提交。固定的是 ACK、SukiSU 和专用工作流的构建选项，仍须实际编译与真机验证。

## 原因和修复边界

原厂 cfg80211 依赖 system_dlkm 的 rfkill。原厂 rfkill 签名可以用原厂 Image 的证书验证，但不能用问题 Image 内置的证书验证。问题 Image 仍启用 MODULE_SIG_PROTECT，并保留 rfkill 的受保护导出符号。

原厂 vendor_dlkm 的 401 个模块文件、system_dlkm 的 103 个模块文件，共 25,904 项已核对的内核符号 CRC 均匹配问题 Image，未发现相关内核导出缺失。CRC 相同并不代表完整 ABI 或运行时功能已经验证。

本修复通过 Kleaf 的 `kernel_build.system_trusted_key` 纳入原厂公开证书。当前 `common_kernel` 包装宏未暴露此参数，所以准备脚本仅补上默认值为 None 的可选参数与转发，再对 `kernel_aarch64` 目标设置证书 label；不更改 16K、x86 等目标的默认信任配置。

不关闭 MODULE_SIG、MODULE_SIG_PROTECT 或 MODVERSIONS；不替换模块签名私钥；不修改、重新签名或刷写 system_dlkm/vendor_dlkm。设备检查仅允许 songyuan，安装目标仍为当前槽位 boot。

## 证书来源

`certs/songyuan-os4.0.0.10-gki.pem` 只包含公开 X.509 证书，无私钥。

- 来自用户提供的匹配 OTA 原厂 Image。
- 原厂 Image SHA-256：`ac4f55090afb6347103c3710a3d76d55f19788dfbb01f9561d4cbf82ab10ac03`。
- 原厂 boot.img SHA-256：`9a02a1c3715d7e92a57be5a68df3121a026fe8528fcabe5abf82235f86acfe0a`。
- 证书 DER SHA-256：`70ab438b9b156f333e60643318ca552da661f478614d2b9efee21c1ed7c8e56f`。
- 证书序列号：`4DB7E9CB539FD77B7273247BB9CE4FF4723EF736`。

此配置显式增加对该公钥签署模块的信任，仅适用于上述原厂模块基线。更新系统后应重新核对，不应继续假定相同证书与 ABI。

## 截图功能组合（另一个显式配置）

原厂模块信任基线的[专用构建 #1](https://github.com/zxr1154/LLAnyKernel3/actions/runs/36326558986)已编译成功，但这不等于真机网络已验证。保留其工作流和配置不变；新增 `songyuan-6.12-selected-features.yml`，使用独立配置 `songyuan-os4.0.0.10-features`，按用户截图开启：

| 选项 | 截图功能组合 |
| --- | --- |
| ZRAM 压缩算法 | 开启（框架会将 ZRAM/ZSMALLOC 改为内建） |
| BBG 基带保护 | 开启 |
| 网络增强 IPSet + BBR | 开启 |
| KPM | patched（开启并修补最终 Image） |
| SUSFS | **关闭**；按用户后续明确确认，保持当前 SukiSU，不切换 builtin |
| 一加骁龙 8 Elite/Gen5 支持 | 开启 |
| Re-Kernel、CVE-2026-43499 可选补丁、自动跳过不兼容功能 | 关闭 |
| Droidspaces / NTSync | 保留原来的关闭状态；截图未完整显示这组控件 |

此组合仍固定相同的 ACK、SukiSU、版本名、构建时间和原厂公开证书，不关闭模块签名保护、MODVERSIONS 或机型检查。只允许 ZRAM 按所选功能改为内建，RFKILL 仍必须为模块；不替换 system_dlkm/vendor_dlkm。当前官方 SukiSU 提交的 `kernel/Kconfig` 提供 KPM，但没有 SUSFS 配置；因此遵循用户确认保留 SUSFS 关闭，最终检查也会拒绝意外启用它。

开启额外补丁会改变内核及模块布局，**不能继承基线的编译成功或兼容性结论**。BBG、ZRAM、KPM 等依赖仍遵循现有框架的仓库选择，未新增冻结所有外部依赖的承诺。它们可能引入编译、启动、网络或其他兼容性问题；需要新编译和真机验证。

准备阶段发现未解决的 `.rej` 会停止。最终 Image 必须同时包含证书、ZRAM 扩展后端、BBG/LSM、KPM、IPSet/BBR 配置，并保持 SUSFS 关闭；KPM 修补步骤必须成功生成不同的 Image 并记录完成状态，检查才会放行。配置检查和补丁步骤记录不是 KPM 或其他功能的运行时测试。

合入默认分支后，手动运行 **songyuan 6.12.69 - 截图功能组合**。产物名额外带 `-features`，与保留的基础修复包区分；JSON 报告包含配置名和预期选项。这次配置变更本身不触发编译、不修改正在运行的任务，也不刷机。

## 使用

1. 将本修复合入默认 `dev` 分支后，在 Actions 手动运行 **songyuan 6.12.69 - 原厂模块信任修复** 工作流；提交代码本身不会启动此内核编译。
2. 它固定已验证的 ACK 和 SukiSU，并拒绝参数漂移；其他原有工作流默认不启用此配置。
3. 构建后必须通过最终 Image 检查：内置原厂证书、可信证书配置、模块保护、MODVERSIONS、4K 页面和 RFKILL/ZRAM 模块形态均正确，否则禁止打包。
4. 成功后产物名带 `-songyuan-stocktrust`，另有 `songyuan-stock-module-trust-report`。报告标明 **尚未进行真机网络验证**。
5. 保留匹配系统的原厂 boot 备份和回退条件。不要把 CI 成功、证书嵌入成功或 CRC 检查通过当成“保证可刷、保证联网”。

原厂模块证书不受信任是 Wi-Fi 故障的强证据；移动数据仍需结合后续故障日志或真机验证确认，当前不能承诺一并修复。

## 本地测试（不编译或刷机）

```bash
python3 -m unittest discover -s tests -p 'test_songyuan_stock_modules.py' -v
```

工作流结构测试需要 PyYAML。可选环境变量 `SONGYUAN_KERNEL_ROOT` 指向已有 ACK/Kleaf 树，用于只读验证真实源码的修改位置；`SONGYUAN_BAD_ZIP` 指向已知故障包，用于确认最终检查会拒绝旧 Image。测试中的合成 Image 只用于验证解析和错误处理，不代表实际内核构建。

`prepare` 会对它更改的文件先备份到构建根目录 `.songyuan-stock-module-trust/`，重复执行保持幂等；遇到已有不同证书、错误 ACK、未知代码布局或其他机型模板会停止，不猜测覆盖。

机制参考：[AOSP GKI modules](https://source.android.com/docs/core/architecture/kernel/modules)、内核 `kernel/module/{signing.c,main.c,Kconfig}`、Kleaf `kernel_build.system_trusted_key`。
